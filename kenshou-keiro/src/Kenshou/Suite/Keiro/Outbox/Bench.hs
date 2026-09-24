module Kenshou.Suite.Keiro.Outbox.Bench (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (finally)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import GHC.Clock (getMonotonicTimeNSec)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox (IntegrationEventDraft (..), IntegrationProducer (IntegrationProducer), OrderingPolicy (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), ProducerEnqueueOutcome (..), countOutboxBacklog, defaultPublishOptions, enqueueIntegrationEventTx, enqueueProducerEventTx, freshOutboxId, listOutbox, mkIntegrationProducer, publishClaimedOutbox)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobDouble, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (Arrival (..), ClosedConfig (..), LoadModel (..), LoadReport (..), OpenConfig (..), Operation (..), OverloadConfig (..), runLoad)
import Kenshou.Measure.Phase (PhasePlan (..), SteadyBound (..))
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..), newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..), keiroTelemetry, withFixtureTelemetryEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, inlineEvent, sourceName)
import Kenshou.Telemetry (telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [drainThroughput, enqueueToPublish, producerIdentityReplay]

producerIdentityReplay :: Scenario
producerIdentityReplay =
  drainThroughput
    { id = either (error . show) id (parseScenarioId "keiro/outbox/benchmark/producer-identity-replay"),
      summary = "Measures fresh replay-safe producer enqueue against an identical replay.",
      knobs = telemetryKnobs <> measureKnobs Benchmark <> [intKnob "outbox.pairs" 2000 1 1000000],
      run = runProducerIdentityReplay
    }

runProducerIdentityReplay :: RunContext -> IO ScenarioReport
runProducerIdentityReplay context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 0 1 1)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "producer-replay-bench"
          pairs = fromIntegral (knobInt context.knobs (name "outbox.pairs"))
          measuredConfig = config {defaultPhases = (config.defaultPhases) {steady = SteadyCount pairs}}
          producer :: IntegrationProducer ()
          producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "bench" source "kenshou" (\_ _ -> Nothing)))
      ((loadReport, inserted, duplicates), report) <- withMeasurement context measuredConfig \measurement -> do
        freshOp <- registerOp (measurementRecorder measurement) (OpName "outbox.producer-fresh")
        replayOp <- registerOp (measurementRecorder measurement) (OpName "outbox.producer-replay")
        freshRecorder <- newWorkerRecorder freshOp 0
        replayRecorder <- newWorkerRecorder replayOp 0
        inserted <- newIORef (0 :: Int)
        duplicates <- newIORef (0 :: Int)
        let enqueuePair _ sequenceNumber = do
              now <- getCurrentTime
              let index = fromIntegral sequenceNumber + 1 :: Int
                  recorded =
                    RecordedEvent
                      { eventId = EventId (UUID.fromWords 0 0 0 (fromIntegral index)),
                        eventType = EventType "Bench",
                        streamVersion = StreamVersion (fromIntegral index),
                        globalPosition = GlobalPosition (fromIntegral index),
                        originalStreamId = StreamId 1,
                        originalVersion = StreamVersion (fromIntegral index),
                        payload = object [],
                        metadata = Nothing,
                        causationId = Nothing,
                        correlationId = Nothing,
                        createdAt = now
                      }
                  draft =
                    IntegrationEventDraft
                      { destination = "kenshou.outbox.v1",
                        key = Just "bench",
                        eventType = "Bench",
                        schemaVersion = 1,
                        contentType = ApplicationJson,
                        schemaReference = Nothing,
                        sourceEventId = Nothing,
                        sourceGlobalPosition = Nothing,
                        payloadBytes = ByteString.pack [1, 2, 3],
                        occurredAt = now,
                        causationId = Nothing,
                        correlationId = Nothing,
                        traceContext = Nothing,
                        attributes = Nothing
                      }
                  enqueue = runFixture (runTransaction (enqueueProducerEventTx producer recorded 0 draft))
              freshStart <- getMonotonicTimeNSec
              first <- enqueue
              freshEnd <- getMonotonicTimeNSec
              recordOp freshRecorder freshStart freshStart freshEnd (case first of Right ProducerInserted {} -> OpOk 1; _ -> OpFailed (ErrorCause "fresh-enqueue"))
              replayStart <- getMonotonicTimeNSec
              second <- enqueue
              replayEnd <- getMonotonicTimeNSec
              recordOp replayRecorder replayStart replayStart replayEnd (case second of Right ProducerDuplicateIdentical {} -> OpOk 1; _ -> OpFailed (ErrorCause "identical-replay"))
              case (first, second) of
                (Right (ProducerInserted firstIdentity), Right (ProducerDuplicateIdentical secondIdentity)) | firstIdentity == secondIdentity -> do
                  atomicModifyIORef' inserted (\count -> (count + 1, ()))
                  atomicModifyIORef' duplicates (\count -> (count + 1, ()))
                  pure (OpOk 1)
                _ -> pure (OpFailed (ErrorCause "producer-outcome"))
        generated <- runLoad measurement (ClosedLoop (ClosedConfig 1 0 0)) (Operation (OpName "outbox.producer-pair") enqueuePair)
        freshCount <- readIORef inserted
        replayCount <- readIORef duplicates
        pure (generated, freshCount, replayCount)
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      let completed = fromIntegral loadReport.completed :: Int
          cells =
            [ ("producer-pairs-completed", completed > 0 && loadReport.failed == 0 && inserted == completed && duplicates == completed),
              ("identical-replay-no-extra-rows", length rows == completed && all ((== OutboxPending) . (.status)) rows)
            ]
      putSummary context Measurements "outbox-producer-identity-replay" (object ["pairs" .= completed, "freshInserted" .= inserted, "identicalReplays" .= duplicates, "outboxRows" .= length rows])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})

enqueueToPublish :: Scenario
enqueueToPublish =
  drainThroughput
    { id = either (error . show) id (parseScenarioId "keiro/outbox/benchmark/enqueue-to-publish"),
      summary = "Measures open-loop enqueue latency and enqueue-to-publisher callback latency.",
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ doubleKnob "outbox.rate" 500 1 100000,
               intKnob "outbox.duration-seconds" 120 1 3600,
               intKnob "outbox.batch-size" 32 1 10000,
               intKnob "outbox.publishers" 4 1 32,
               intKnob "outbox.key-cardinality" 200 0 1000000,
               textKnob "outbox.ordering-policy" "per-key-head-of-line" ["per-source-stream", "stop-the-line", "best-effort"],
               intKnob "broker.invocation-micros" 1000 0 10000000,
               intKnob "broker.per-record-micros" 10 0 10000000,
               intKnob "broker.partitions" 4 1 10000
             ],
      run = runEnqueueToPublish
    }

runEnqueueToPublish :: RunContext -> IO ScenarioReport
runEnqueueToPublish context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 1 duration 5)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "enqueue-bench"
          batch = fromIntegral (knobInt context.knobs (name "outbox.batch-size")) :: Int
          publishers = fromIntegral (knobInt context.knobs (name "outbox.publishers")) :: Int
          keys = fromIntegral (knobInt context.knobs (name "outbox.key-cardinality")) :: Int
          rate = knobDouble context.knobs (name "outbox.rate")
          ordering = case knobText context.knobs (name "outbox.ordering-policy") of
            "per-source-stream" -> PerSourceStream
            "stop-the-line" -> StopTheLine
            "best-effort" -> BestEffort
            _ -> PerKeyHeadOfLine
          options = defaultPublishOptions {batchSize = batch, orderingPolicy = ordering, tracer = runtimeTelemetry.keiroTracer}
          brokerModel = Broker.BrokerModel (fromIntegral (knobInt context.knobs (name "broker.invocation-micros"))) (fromIntegral (knobInt context.knobs (name "broker.per-record-micros"))) (fromIntegral (knobInt context.knobs (name "broker.partitions")))
          load = OpenLoop (OpenConfig (ConstantRate rate) 128 1 (OverloadConfig 1000000000 3 30000000000))
      broker <- Broker.newBroker
      stop <- newIORef False
      inFlight <- newIORef (0 :: Int)
      publisherErrors <- newIORef (0 :: Int)
      let enqueueOne _ sequenceNumber = do
            now <- getCurrentTime
            let index = fromIntegral sequenceNumber :: Int
                messageId = Text.pack (show index)
                key = if keys == 0 then Nothing else Just ("key-" <> Text.pack (show (index `mod` keys)))
                event = inlineEvent source messageId key index now
            outboxId <- runFixture freshOutboxId
            case outboxId of
              Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
              Right identifier -> do
                inserted <- runFixture (runTransaction (enqueueIntegrationEventTx identifier event))
                pure case inserted of
                  Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                  Right () -> OpOk 1
          awaitBacklog :: Int -> IO Bool
          awaitBacklog 0 = pure False
          awaitBacklog remaining = do
            backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
            active <- readIORef inFlight
            if backlog == 0 && active == 0 then pure True else threadDelay 10000 >> awaitBacklog (remaining - 1)
      ((loadReport, drained), report) <- withMeasurement context config \measurement -> do
        callbackOp <- registerOp (measurementRecorder measurement) (OpName "outbox.enqueue-to-publish")
        workers <- forM [0 .. publishers - 1] \workerNumber -> do
          callbackRecorder <- newWorkerRecorder callbackOp workerNumber
          let beforeAppend rows = forM_ rows \row -> do
                now <- getCurrentTime
                ended <- getMonotonicTimeNSec
                let elapsedNs = max 0 (floor (realToFrac (diffUTCTime now row.event.occurredAt) * 1000000000 :: Double) :: Integer)
                    started = ended - min ended (fromIntegral elapsedNs)
                recordOp callbackRecorder started started ended (OpOk 1)
              hooks = Broker.PublishHook beforeAppend (const (pure ()))
              callback = Broker.publishScripted broker brokerModel (const Broker.Succeed) hooks ("publisher-" <> Text.pack (show workerNumber))
              publishLoop = do
                halted <- readIORef stop
                unless halted do
                  atomicModifyIORef' inFlight (\count -> (count + 1, ()))
                  result <-
                    runFixture (publishClaimedOutbox callback options runtimeTelemetry.keiroMetrics)
                      `finally` atomicModifyIORef' inFlight (\count -> (count - 1, ()))
                  case result of
                    Left _ -> atomicModifyIORef' publisherErrors (\count -> (count + 1, ())) >> threadDelay 10000
                    Right summary | summary.claimed == 0 -> threadDelay 1000
                    Right _ -> pure ()
                  publishLoop
          async publishLoop
        ( do
            generated <- runLoad measurement load (Operation (OpName "outbox.enqueue") enqueueOne)
            drained <- awaitBacklog 3000
            pure (generated, drained)
          )
          `finally` (writeIORef stop True >> mapM_ cancel workers)
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      brokerRows <- Broker.readBroker broker
      errors <- readIORef publisherErrors
      backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      let complete = fromIntegral loadReport.completed :: Int
          cells =
            [ ("enqueue-load-completed", complete > 0 && loadReport.failed == 0 && not loadReport.abortedEarly && errors == 0),
              ("no-loss", drained && backlog == 0 && length rows == complete && all ((== OutboxSent) . (.status)) rows && length brokerRows == complete)
            ]
      putSummary context Measurements "outbox-enqueue-to-publish" (object ["rate" .= rate, "batchSize" .= batch, "publishers" .= publishers, "completed" .= complete, "brokerRecords" .= length brokerRows, "backlog" .= backlog])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})
  where
    duration = fromIntegral (knobInt context.knobs (name "outbox.duration-seconds"))

drainThroughput :: Scenario
drainThroughput =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/benchmark/drain-throughput"),
      revision = 1,
      summary = "Measures closed-loop publish passes over a preloaded durable outbox.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ intKnob "outbox.rows" 50000 1 1000000,
               intKnob "outbox.batch-size" 32 1 10000,
               intKnob "outbox.publishers" 4 1 32,
               intKnob "outbox.key-cardinality" 50 0 1000000,
               textKnob "outbox.ordering-policy" "per-key-head-of-line" ["per-source-stream", "stop-the-line", "best-effort"],
               intKnob "broker.invocation-micros" 1000 0 10000000,
               intKnob "broker.per-record-micros" 10 0 10000000,
               intKnob "broker.partitions" 4 1 10000
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 0 1 1,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runDrainThroughput
    }

runDrainThroughput :: RunContext -> IO ScenarioReport
runDrainThroughput context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 0 1 1)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "drain-bench"
          rowCount = fromIntegral (knobInt context.knobs (name "outbox.rows")) :: Int
          batch = fromIntegral (knobInt context.knobs (name "outbox.batch-size")) :: Int
          publishers = fromIntegral (knobInt context.knobs (name "outbox.publishers")) :: Int
          keys = fromIntegral (knobInt context.knobs (name "outbox.key-cardinality")) :: Int
          routingKey index = if keys == 0 then Nothing else Just ("key-" <> Text.pack (show (index `mod` keys)))
          entries = [(Text.pack (show index), routingKey index, index) | index <- [1 .. rowCount]]
          ordering = case knobText context.knobs (name "outbox.ordering-policy") of
            "per-source-stream" -> PerSourceStream
            "stop-the-line" -> StopTheLine
            "best-effort" -> BestEffort
            _ -> PerKeyHeadOfLine
          options = defaultPublishOptions {batchSize = batch, orderingPolicy = ordering, tracer = runtimeTelemetry.keiroTracer}
          brokerModel = Broker.BrokerModel (fromIntegral (knobInt context.knobs (name "broker.invocation-micros"))) (fromIntegral (knobInt context.knobs (name "broker.per-record-micros"))) (fromIntegral (knobInt context.knobs (name "broker.partitions")))
          hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
      enqueueInline fixture source entries
      broker <- Broker.newBroker
      published <- newIORef (0 :: Int)
      let callback = Broker.publishScripted broker brokerModel (const Broker.Succeed) hooks "drain-bench"
          publishOnce = do
            result <- runFixture (publishClaimedOutbox callback options runtimeTelemetry.keiroMetrics)
            case result of
              Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
              Right summary -> do
                atomicModifyIORef' published (\count -> (count + summary.published, ()))
                pure (OpOk summary.published)
          targetOps = fromIntegral (rowCount `div` batch + publishers * 8)
          measuredConfig = config {defaultPhases = (config.defaultPhases) {steady = SteadyCount targetOps}}
          load = ClosedLoop (ClosedConfig publishers 0 0)
      started <- getMonotonicTimeNSec
      (_, report) <- withMeasurement context measuredConfig (\measurement -> runLoad measurement load (Operation (OpName "outbox-drain") (\_ _ -> publishOnce)))
      ended <- getMonotonicTimeNSec
      measuredPublished <- readIORef published
      let finish 0 = pure ()
          finish remaining = do
            backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
            if backlog == 0
              then pure ()
              else do
                _ <- publishOnce
                finish (remaining - 1)
      finish (rowCount + 1)
      backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      brokerRows <- Broker.readBroker broker
      let failures = sum [batchReport.failed | batchReport <- report.loads]
          seconds = fromIntegral (ended - started) / 1000000000 :: Double
          cells =
            [ ("measured-publishing", measuredPublished > 0 && failures == 0),
              ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && length brokerRows == rowCount && backlog == 0)
            ]
      putSummary context Measurements "outbox-drain-throughput" (object ["rows" .= rowCount, "batchSize" .= batch, "publishers" .= publishers, "measuredPublished" .= measuredPublished, "measuredSeconds" .= seconds, "rowsPerSecond" .= (fromIntegral measuredPublished / max 0.000001 seconds)])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

doubleKnob :: Text -> Double -> Double -> Double -> KnobSpec
doubleKnob key def low high = KnobSpec (name key) key KnobDouble (VDouble def) (DoubleRange low high) []

textKnob :: Text -> Text -> [Text] -> KnobSpec
textKnob key def alternatives = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
