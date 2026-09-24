module Kenshou.Suite.Keiro.Router.Bench (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (liftIO)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (defaultWorkerOptions)
import Keiro.ProcessManager qualified as ProcessManager
import Keiro.Router (runRouterWorkerWith)
import Keiro.Stream qualified as Stream
import Keiro.Telemetry (newKeiroMetrics)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge (AckRecord (..), bonusAdapterConfig, kirokuBridge, listAdapter)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (EventId, RecordedEvent (..), StreamVersion (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Streamly
import System.Timeout (timeout)
import Text.Read (readMaybe)

scenarios :: [Scenario]
scenarios = [fanoutDispatch]

fanoutDispatch :: Scenario
fanoutDispatch =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/router/benchmark/fanout-dispatch"),
      revision = 1,
      summary = "Measures bonus fanout and redelivery through the list worker, then checks every target credit.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 1})
          <> measureKnobs Benchmark
          <> [ intKnob "router.fanout" 10 1 1000,
               intKnob "router.redelivery-percent" 25 0 100,
               KnobSpec (knobName "router.source") "Router input adapter" KnobText (VText "list") (OneOf (VText "list" :| [VText "kiroku-adapter"])) [],
               intKnob "router.duration-seconds" 120 1 3600
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 120 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runFanoutDispatch
    }

runFanoutDispatch :: RunContext -> IO ScenarioReport
runFanoutDispatch context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "router.duration-seconds"))) 5))) of
    (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
    (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
    (Right load, Right config) -> case telemetrySpecFromContext context of
      Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
      Right spec -> withTelemetry spec (runMeasured load config)
  where
    runMeasured load config telemetry =
      withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
        let KeiroRunner runFixture = fixture.runner
            accountEvents = accountEventStream SnapNever
            fanout = fromIntegral (knobInt context.knobs (knobName "router.fanout")) :: Int
            redeliveryPercent = fromIntegral (knobInt context.knobs (knobName "router.redelivery-percent")) :: Int
            sourceKind = knobText context.knobs (knobName "router.source")
            recipients = [AccountId ("router-bench-" <> Text.pack (show index)) | index <- [0 .. fanout - 1]]
        _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
        keiroMetrics <- traverse newKeiroMetrics telemetry.meter
        let commandOptions = defaultRunCommandOptions {tracer = telemetry.tracer, metrics = keiroMetrics}
            workerOptions = defaultWorkerOptions {ProcessManager.metrics = keiroMetrics}
            router = bonusRouterWith bonusRouterName accountEvents (\_ -> pure recipients)
        opened <- traverse (\account -> runFixture (runCommand commandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))) recipients
        nextId <- newIORef (0 :: Int)
        observations <- newIORef ([] :: [(Bool, Double, Double)])
        durableTimings <- newIORef (Map.empty :: Map.Map EventId [(Bool, Double)])
        retried <- newIORef Set.empty
        let selected recorded = case decodeBonusDeclared recorded of
              Just (_, declared) ->
                let BonusId identifier = declared.bonusId
                 in maybe False (\index -> index `mod` 100 < redeliveryPercent) (Text.stripPrefix "router-bench-bonus-" identifier >>= readMaybe . Text.unpack)
              _ -> False
            observeDurable Adapter {adapterName = name, source = input, shutdown = stop} =
              Adapter {adapterName = name, source = Streamly.mapM wrap input, shutdown = stop}
              where
                wrap ingested = do
                  started <- liftIO getMonotonicTimeNSec
                  let recorded = ingested.envelope.payload
                      AckHandle finalize = ingested.ack
                  pure
                    ingested
                      { ack =
                          AckHandle
                            ( \decision -> do
                                ended <- liftIO getMonotonicTimeNSec
                                first <- liftIO $ atomicModifyIORef' retried \seen ->
                                  if Set.member recorded.eventId seen then (seen, False) else (Set.insert recorded.eventId seen, True)
                                let retry = selected recorded && first && decision == AckOk
                                    actual = if retry then AckRetry (RetryDelay 0) else decision
                                    handlingMs = fromIntegral (ended - started) / 1000000
                                liftIO $ atomicModifyIORef' durableTimings (\timings -> (Map.insertWith (<>) recorded.eventId [(actual == AckOk, handlingMs)] timings, ()))
                                finalize actual
                            )
                      }
            awaitDurable identifier expected = do
              timings <- readIORef durableTimings
              case Map.lookup identifier timings of
                Just deliveries | length deliveries >= expected -> do
                  atomicModifyIORef' durableTimings (\entries -> (Map.delete identifier entries, ()))
                  pure deliveries
                _ -> threadDelay 10000 >> awaitDurable identifier expected
        let operation _ _ = do
              sequenceNumber <- atomicModifyIORef' nextId (\n -> (n + 1, n))
              let bonus = BonusId ("router-bench-bonus-" <> Text.pack (show sequenceNumber))
              declared <- runFixture (runCommand commandOptions bonusEventStream (bonusStream bonus) (DeclareBonus (DeclareBonusData bonus "all" 3)))
              events <- runFixture (readStreamForward (Stream.streamName (bonusStream bonus)) (StreamVersion 0) 1)
              case events of
                Right batch | (case declared of Right (Right result) -> result.eventsAppended == 1; _ -> False) -> case Vector.toList batch of
                  [recorded] -> do
                    let duplicate = sequenceNumber `mod` 100 < redeliveryPercent
                        deliveries = if duplicate then [(recorded, Nothing), (recorded, Just 1)] else [(recorded, Nothing)]
                    if sourceKind == "list"
                      then do
                        acks <- newIORef []
                        let adapter = listAdapter "router-benchmark" acks deliveries
                        started <- getMonotonicTimeNSec
                        outcome <- runFixture (runRouterWorkerWith workerOptions commandOptions router adapter decodeBonusDeclared)
                        ended <- getMonotonicTimeNSec
                        completed <- getCurrentTime
                        acknowledgement <- readIORef acks
                        let acked = length acknowledgement == length deliveries && all (\ack -> ack.decision == AckOk) acknowledgement
                            handledMs = fromIntegral (ended - started) / 1000000
                            sourceToCompletionMs = realToFrac (diffUTCTime completed recorded.createdAt) * 1000
                        atomicModifyIORef' observations (\samples -> ((duplicate, handledMs, sourceToCompletionMs) : samples, ()))
                        pure $ if acked && either (const False) (const True) outcome then OpOk 1 else OpFailed (ErrorCause "fanout or acknowledgement failed")
                      else do
                        delivered <- timeout 30000000 (awaitDurable recorded.eventId (length deliveries))
                        completed <- getCurrentTime
                        case delivered of
                          Nothing -> pure (OpFailed (ErrorCause "durable fanout timed out"))
                          Just timings -> do
                            let acked = length timings == length deliveries && length [() | (True, _) <- timings] == 1
                                handledMs = sum [milliseconds | (_, milliseconds) <- timings]
                                sourceToCompletionMs = realToFrac (diffUTCTime completed recorded.createdAt) * 1000
                            atomicModifyIORef' observations (\samples -> ((duplicate, handledMs, sourceToCompletionMs) : samples, ()))
                            pure $ if acked then OpOk 1 else OpFailed (ErrorCause "durable fanout acknowledgement failed")
                  _ -> pure (OpFailed (ErrorCause "missing bonus event"))
                _ -> pure (OpFailed (ErrorCause "bonus declaration failed"))
        let measure = withMeasurement context config (\measurement -> runLoad measurement load (Operation (OpName "router-fanout") operation))
            durableWorker = runFixture do
              adapter <- kirokuBridge fixture.store (bonusAdapterConfig (SubscriptionName "router-benchmark-durable"))
              runRouterWorkerWith workerOptions commandOptions router (observeDurable adapter) decodeBonusDeclared
        (_, report) <- if sourceKind == "list" then measure else withAsync durableWorker (const measure)
        acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-router-bench-oracle")
        connection <- either (fail . show) pure acquired
        accountRows <- Oracle.readCategoryLog connection "account"
        bonusRows <- Oracle.readCategoryLog connection "bonus"
        Connection.release connection
        samples <- readIORef observations
        issued <- readIORef nextId
        let completed = sum [batch.completed | batch <- report.loads]
            failures = sum [batch.failed | batch <- report.loads]
            duplicates = length [() | (True, _, _) <- samples]
            mean values = if null values then (0 :: Double) else sum values / fromIntegral (length values)
            accountValid = case Oracle.modelFromLog accountRows of
              Right model -> Model.totalMoney model == issued * fanout * 3 && length accountRows == fanout + issued * fanout
              Left _ -> False
            bonusValid = length bonusRows == issued && Oracle.logWellFormed bonusRows
        putSummary context Measurements "router-fanout" (object ["source" .= sourceKind, "fanout" .= fanout, "issued" .= issued, "completed" .= completed, "failed" .= failures, "redelivered" .= duplicates, "meanFreshHandlingMs" .= mean [ms | (False, ms, _) <- samples], "meanRedeliveryHandlingMs" .= mean [ms | (True, ms, _) <- samples], "meanSourceToCompletionMs" .= mean [ms | (_, _, ms) <- samples]])
        base <- recordCells context [("recipients-opened", all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) opened), ("dispatch-completed", completed > 0 && failures == 0), ("target-effects-once", accountValid && Oracle.logWellFormed accountRows), ("bonus-source-once", bonusValid)]
        pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName
