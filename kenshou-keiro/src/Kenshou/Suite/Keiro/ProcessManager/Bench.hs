module Kenshou.Suite.Keiro.ProcessManager.Bench (scenarios) where

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
import Keiro.ProcessManager (defaultWorkerOptions, runProcessManagerWorkerWith)
import Keiro.ProcessManager qualified as ProcessManager
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
import Kenshou.Suite.Keiro.Fixture.Bridge (AckRecord (..), kirokuBridge, listAdapter, sagaAdapterConfig)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Transfer
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
scenarios = [dispatchLatency]

dispatchLatency :: Scenario
dispatchLatency =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/benchmark/dispatch-latency"),
      revision = 1,
      summary = "Measures transfer dispatch and duplicate delivery through the list worker, then checks target effects.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 2})
          <> measureKnobs Benchmark
          <> [ intKnob "pm.redelivery-percent" 25 0 100,
               KnobSpec (knobName "pm.source") "Process-manager input adapter" KnobText (VText "list") (OneOf (VText "list" :| [VText "kiroku-adapter"])) [],
               intKnob "pm.duration-seconds" 120 1 3600
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
      run = runDispatchLatency
    }

runDispatchLatency :: RunContext -> IO ScenarioReport
runDispatchLatency context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "pm.duration-seconds"))) 5))) of
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
            manager = transferManager accountEvents (const [])
            redeliveryPercent = fromIntegral (knobInt context.knobs (knobName "pm.redelivery-percent")) :: Int
            sourceKind = knobText context.knobs (knobName "pm.source")
            accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
        keiroMetrics <- traverse newKeiroMetrics telemetry.meter
        let commandOptions = defaultRunCommandOptions {tracer = telemetry.tracer, metrics = keiroMetrics}
            workerOptions = defaultWorkerOptions {ProcessManager.metrics = keiroMetrics}
            submit account command = runFixture (runCommand commandOptions accountEvents (accountStream account) command)
        nextId <- newIORef (0 :: Int)
        observations <- newIORef ([] :: [(Bool, Double, Double)])
        durableTimings <- newIORef (Map.empty :: Map.Map EventId [(Bool, Double)])
        retried <- newIORef Set.empty
        let selected recorded = case decodeTransferSignal recorded of
              Just (_, SignalDebited debit) ->
                let TransferId identifier = debit.transferId
                 in maybe False (\index -> index `mod` 100 < redeliveryPercent) (Text.stripPrefix "pm-bench-transfer-" identifier >>= readMaybe . Text.unpack)
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
              let suffix = Text.pack (show sequenceNumber)
                  source = AccountId ("pm-bench-source-" <> suffix)
                  destination = AccountId ("pm-bench-destination-" <> suffix)
                  transfer = TransferId ("pm-bench-transfer-" <> suffix)
              setup <-
                sequence
                  [ submit source (OpenAccount (OpenAccountData source 10)),
                    submit destination (OpenAccount (OpenAccountData destination 0)),
                    submit source (DebitTransfer (DebitTransferData source transfer destination 2 4102444800))
                  ]
              events <- runFixture (readStreamForward (accountStreamName source) (StreamVersion 1) 2)
              case events of
                Right batch | all accepted setup -> case [recorded | recorded <- Vector.toList batch, Just (_, SignalDebited d) <- [decodeTransferSignal recorded], d.transferId == transfer] of
                  [recorded] -> do
                    let duplicate = sequenceNumber `mod` 100 < redeliveryPercent
                        deliveries = if duplicate then [(recorded, Nothing), (recorded, Just 1)] else [(recorded, Nothing)]
                    if sourceKind == "list"
                      then do
                        acks <- newIORef []
                        let adapter = listAdapter "pm-benchmark" acks deliveries
                        started <- getMonotonicTimeNSec
                        outcome <- runFixture (runProcessManagerWorkerWith workerOptions commandOptions manager adapter decodeTransferSignal)
                        ended <- getMonotonicTimeNSec
                        completed <- getCurrentTime
                        acknowledgement <- readIORef acks
                        let acked = length acknowledgement == length deliveries && all (\ack -> ack.decision == AckOk) acknowledgement
                            handledMs = fromIntegral (ended - started) / 1000000
                            sourceToTargetMs = realToFrac (diffUTCTime completed recorded.createdAt) * 1000
                        atomicModifyIORef' observations (\samples -> ((duplicate, handledMs, sourceToTargetMs) : samples, ()))
                        pure $ if acked && either (const False) (const True) outcome then OpOk 1 else OpFailed (ErrorCause "dispatch or acknowledgement failed")
                      else do
                        delivered <- timeout 30000000 (awaitDurable recorded.eventId (length deliveries))
                        completed <- getCurrentTime
                        case delivered of
                          Nothing -> pure (OpFailed (ErrorCause "durable dispatch timed out"))
                          Just timings -> do
                            let acked = length timings == length deliveries && length [() | (True, _) <- timings] == 1
                                handledMs = sum [milliseconds | (_, milliseconds) <- timings]
                                sourceToTargetMs = realToFrac (diffUTCTime completed recorded.createdAt) * 1000
                            atomicModifyIORef' observations (\samples -> ((duplicate, handledMs, sourceToTargetMs) : samples, ()))
                            pure $ if acked then OpOk 1 else OpFailed (ErrorCause "durable acknowledgement failed")
                  _ -> pure (OpFailed (ErrorCause "missing debit event"))
                _ -> pure (OpFailed (ErrorCause "transfer setup failed"))
        let measure = withMeasurement context config (\measurement -> runLoad measurement load (Operation (OpName "pm-dispatch") operation))
            durableWorker = runFixture do
              adapter <- kirokuBridge fixture.store (sagaAdapterConfig (SubscriptionName "pm-benchmark-durable") Nothing)
              runProcessManagerWorkerWith workerOptions commandOptions manager (observeDurable adapter) decodeTransferSignal
        (_, report) <- if sourceKind == "list" then measure else withAsync durableWorker (const measure)
        acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-pm-bench-oracle")
        connection <- either (fail . show) pure acquired
        accountRows <- Oracle.readCategoryLog connection "account"
        sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
        Connection.release connection
        samples <- readIORef observations
        issued <- readIORef nextId
        let completed = sum [batch.completed | batch <- report.loads]
            failures = sum [batch.failed | batch <- report.loads]
            duplicates = length [() | (True, _, _) <- samples]
            fresh = length samples - duplicates
            mean values = if null values then (0 :: Double) else sum values / fromIntegral (length values)
            accountValid = case Oracle.modelFromLog accountRows of
              Right model -> Model.totalMoney model == issued * 10 && length accountRows == issued * 5
              Left _ -> False
            sagaValid = length sagaRows == issued && Oracle.logWellFormed sagaRows
        putSummary context Measurements "pm-dispatch" (object ["source" .= sourceKind, "issued" .= issued, "completed" .= completed, "failed" .= failures, "freshOnly" .= fresh, "withRedelivery" .= duplicates, "meanFreshHandlingMs" .= mean [ms | (False, ms, _) <- samples], "meanRedeliveryHandlingMs" .= mean [ms | (True, ms, _) <- samples], "meanSourceToCompletionMs" .= mean [ms | (_, _, ms) <- samples]])
        base <- recordCells context [("dispatch-completed", completed > 0 && failures == 0), ("target-effects-once", accountValid && Oracle.logWellFormed accountRows), ("saga-events-once", sagaValid)]
        pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName
