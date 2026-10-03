module Kenshou.Suite.Keiro.Outbox.Soak (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, withAsync)
import Control.Exception (finally)
import Control.Monad (forever, unless)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Keiro.Outbox (OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), countOutboxBacklog, defaultMaintenanceOptions, defaultPublishOptions, enqueueIntegrationEventTx, freshOutboxId, garbageCollectSent, listOutbox, outboxMaintenancePass, publishClaimedOutbox)
import Keiro.Outbox qualified as Outbox
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env qualified as Env
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Diagnose.Leak (LeakReport (..), judgeLeaksWithWindow, leakOutcome)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (Arrival (..), LoadModel (..), LoadReport (..), OpenConfig (..), Operation (..), OverloadConfig (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Measure.Session qualified as Measure
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..))
import Kenshou.Suite.Keiro.Messaging.Metrics (withMessagingTelemetry)
import Kenshou.Suite.Keiro.Messaging.RelationGrowth (RelationGrowth (..), bytesPerInsertedRow, deadTuplesBounded, readRelationGrowth, sizeBounded)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (majorGcIntervalMs, majorGcKnob, soakLeakSpec, withSoakMajorGc)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.SoakPublisher (PublisherReport (..), duplicatesWithinCrashBatches, withProcessPublishers)
import Kenshou.Suite.Keiro.Outbox.Workload (inlineEvent, sourceName)
import Kenshou.Telemetry (telemetryKnobs, telemetrySpecFromContext)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [tableGrowth False, tableGrowth True]

tableGrowth :: Bool -> Scenario
tableGrowth reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/outbox/soak/table-growth-reduced" else "keiro/outbox/soak/table-growth")),
      revision = 4,
      summary = "Publishes continuously with two workers, crash reclamation and optional sent-row garbage collection; checks durable broker coverage and outbox growth.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs =
        telemetryKnobs
          <> measureKnobs Soak
          <> [ intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440,
               intKnob "outbox.rate-per-second" 20 1 1000,
               intKnob "outbox.batch-size" 32 1 256,
               textKnob "outbox.gc" "on" ["off"],
               intKnob "outbox.gc-retention-seconds" 30 0 3600,
               intKnob "outbox.kill-interval-seconds" 60 0 3600,
               textKnob "outbox.publisher-execution" "in-process" ["processes"],
               majorGcKnob
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {Env.postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runTableGrowth
    }

runTableGrowth :: RunContext -> IO ScenarioReport
runTableGrowth context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 5 (fromIntegral minutes * 60) 5)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right baseConfig, Right telemetrySpec) -> withMessagingTelemetry context telemetrySpec \fixture _ _ -> do
    let runtimeTelemetry = fixture.telemetry
        connectionString = (requirePostgres context).connectionString
    Broker.withTableBroker connectionString \broker -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "growth"
          batch = fromIntegral (knobInt context.knobs (name "outbox.batch-size"))
          rateInt = fromIntegral (knobInt context.knobs (name "outbox.rate-per-second")) :: Int
          rate = fromIntegral rateInt :: Double
          gcEnabled = knobText context.knobs (name "outbox.gc") == "on"
          retention = fromIntegral (knobInt context.knobs (name "outbox.gc-retention-seconds"))
          killInterval = fromIntegral (knobInt context.knobs (name "outbox.kill-interval-seconds")) :: Int
          options = defaultPublishOptions {batchSize = batch, publishingTimeout = 10, tracer = runtimeTelemetry.keiroTracer}
          maintenance = Outbox.OutboxMaintenanceOptions defaultMaintenanceOptions.maxAttempts 10
          brokerModel = Broker.BrokerModel 0 0 4
          hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
          load = OpenLoop (OpenConfig (ConstantRate rate) 128 1 (OverloadConfig 1000000000 3 30000000000))
          config = (baseConfig :: MeasureConfig) {Measure.postgres = fmap (\pg -> pg {relations = ["keiro.keiro_outbox"]}) baseConfig.postgres}
      halted <- newIORef False
      publisherErrors <- newIORef (0 :: Int)
      maintenanceErrors <- newIORef (0 :: Int)
      kills <- newIORef (0 :: Int)
      let publisher :: Int -> IO ()
          publisher index = do
            stop <- readIORef halted
            unless stop do
              result <- runFixture (publishClaimedOutbox (Broker.publishScripted broker brokerModel (const Broker.Succeed) hooks ("publisher-" <> Text.pack (show index))) options runtimeTelemetry.keiroMetrics)
              case result of
                Left _ -> atomicModifyIORef' publisherErrors (\count -> (count + 1, ())) >> threadDelay 100000
                Right summary | summary.claimed == 0 -> threadDelay 20000
                Right _ -> pure ()
              publisher index
          maintain = forever do
            threadDelay 1000000
            result <- runFixture (outboxMaintenancePass maintenance runtimeTelemetry.keiroMetrics)
            case result of
              Left _ -> atomicModifyIORef' maintenanceErrors (\count -> (count + 1, ()))
              Right _ -> pure ()
            if gcEnabled
              then do
                now <- getCurrentTime
                collected <- runFixture (garbageCollectSent retention now)
                case collected of
                  Left _ -> atomicModifyIORef' maintenanceErrors (\count -> (count + 1, ()))
                  Right _ -> pure ()
              else pure ()
          enqueue _ sequenceNumber = do
            now <- getCurrentTime
            let messageId = Text.pack (show sequenceNumber)
                event = inlineEvent source messageId (Just ("key-" <> Text.pack (show (sequenceNumber `mod` 64)))) (fromIntegral sequenceNumber) now
            identifier <- runFixture freshOutboxId
            case identifier of
              Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
              Right outboxId -> do
                result <- runFixture (runTransaction (enqueueIntegrationEventTx outboxId event))
                pure case result of
                  Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                  Right () -> OpOk 1
          awaitDrain = do
            backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
            active <- runFixture (listOutbox source) >>= either (fail . show) pure
            if backlog == 0 && all ((== OutboxSent) . (.status)) active then pure True else threadDelay 1000000 >> awaitDrain
      let work stopRestarts = withSoakMajorGc context do
            result <- withMeasurement context config \session -> runLoad session load (Operation (OpName "outbox.enqueue") enqueue)
            stopRestarts
            drained <- timeout 120000000 awaitDrain
            pure (result, drained)
      (((loadReport, measurement), drained), processReport) <- withAsync maintain \_ ->
        if processMode
          then do
            (result, report) <- withProcessPublishers context killInterval work
            writeIORef publisherErrors report.errors
            writeIORef kills report.kills
            pure (result, Just report)
          else do
            publisherZero <- async (publisher 0)
            publisherOne <- async (publisher 1)
            firstPublisher <- newIORef publisherZero
            let restartFirst = do
                  threadDelay (killInterval * 1000000)
                  old <- readIORef firstPublisher
                  cancel old
                  replacement <- async (publisher 0)
                  writeIORef firstPublisher replacement
                  atomicModifyIORef' kills (\count -> (count + 1, ()))
                  restartFirst
            killer <- if killInterval == 0 then pure Nothing else Just <$> async restartFirst
            let stopRestarts = maybe (pure ()) cancel killer
                shutdown = do
                  writeIORef halted True
                  stopRestarts
                  readIORef firstPublisher >>= cancel
                  cancel publisherOne
            result <- work stopRestarts `finally` shutdown
            pure (result, Nothing)
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      brokerRows <- Broker.readBroker broker
      backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      publishFailures <- readIORef publisherErrors
      maintenanceFailures <- readIORef maintenanceErrors
      killCount <- readIORef kills
      growth <- readRelationGrowth context "keiro.keiro_outbox"
      let completed = fromIntegral loadReport.completed :: Int
          expected = Set.fromList [TextEncoding.encodeUtf8 (Text.pack (show index)) | index <- [0 .. completed - 1]]
          received = Set.fromList (map (.payload) brokerRows)
          duplicates = length brokerRows - Set.size received
          growthBounded = maybe False (sizeBounded (8 * 1024 * 1024)) growth
          deadTupleBounded = maybe False (deadTuplesBounded (fromIntegral (max 1000 (rateInt * max 60 (round retention) * 2)))) growth
          cells =
            [ ("enqueue-load-completed", completed > 0 && loadReport.failed == 0 && not loadReport.abortedEarly),
              ("no-loss", drained == Just True && backlog == 0 && received == expected),
              ("bounded-duplicates", duplicates <= max 1 (killCount * batch)),
              ("terminal-rows", all ((== OutboxSent) . (.status)) rows),
              ("maintenance-errors", publishFailures == 0 && maintenanceFailures == 0),
              ("gc-retention", if gcEnabled then length rows <= max 1000 (rateInt * max 60 (round retention) * 2) else length rows == completed),
              ("table-growth", not gcEnabled || minutes < 10 || growthBounded),
              ("dead-tuple-growth", not gcEnabled || minutes < 10 || deadTupleBounded)
            ]
              <> case processReport of
                Nothing -> []
                Just report -> [("publisher-processes-stopped", report.stopped), ("scheduled-process-kills", (killInterval == 0 || report.kills > 0) && length report.crashedBatches == report.kills), ("duplicates-confined-to-crashes", duplicatesWithinCrashBatches report.crashedBatches (map (TextEncoding.decodeUtf8 . (.payload)) brokerRows))]
          duration = fromIntegral minutes * 60 :: Double
          leakSpec = soakLeakSpec context duration
      putSummary context Measurements "outbox-publisher-processes" (object ["execution" .= (if processMode then "processes" else "in-process" :: Text), "childLeakVerdicts" .= maybe [] (map (show . (.verdict)) . (.childLeaks)) processReport])
      putSummary context Measurements "outbox-table-growth" (object ["completed" .= completed, "brokerRecords" .= length brokerRows, "uniqueBrokerMessages" .= Set.size received, "duplicates" .= duplicates, "rowsRetained" .= length rows, "backlog" .= backlog, "workerKills" .= killCount, "publisherErrors" .= publishFailures, "maintenanceErrors" .= maintenanceFailures, "gc" .= gcEnabled, "majorGcIntervalMs" .= majorGcIntervalMs context, "growth" .= fmap (\sample -> object ["earlyBytes" .= sample.earlyBytes, "lateBytes" .= sample.lateBytes, "earlyDeadTuples" .= sample.earlyDeadTuples, "lateDeadTuples" .= sample.lateDeadTuples, "earlyInserts" .= sample.earlyInserts, "lateInserts" .= sample.lateInserts, "bytesPerInsertedRow" .= bytesPerInsertedRow sample, "sizeBounded" .= growthBounded, "deadTuplesBounded" .= deadTupleBounded]) growth])
      base <- recordCells context cells
      leak <- judgeLeaksWithWindow context (Just (5, 5 + duration)) leakSpec
      pure (base {outcome = worstOutcome (base.outcome :| ([measuredOutcome measurement base.outcome, leakOutcome leak, if gcEnabled && minutes >= 10 && growth == Nothing then Inconclusive else Passed] <> maybe [] (map leakOutcome . (.childLeaks)) processReport))})
  where
    minutes = fromIntegral (knobInt context.knobs (name "soak.duration-minutes")) :: Int
    processMode = knobText context.knobs (name "outbox.publisher-execution") == "processes"

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

textKnob :: Text -> Text -> [Text] -> KnobSpec
textKnob key def alternatives = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
