module Kenshou.Suite.Keiro.Queue.Telemetry (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (finally)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueTraced, ensureJobQueue, jobProcessorWithContext, runJobOnceWithContext, runJobWorkers, withOrdering)
import Keiro.PGMQ.Runtime (queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Trace.Core (SpanStatus (..), defaultSpanArguments, inSpan')
import Pgmq.Types (MessageHeaders (..))
import Shibuya.App (SupervisionStrategy (..), waitApp)

scenarios :: [Scenario]
scenarios = [queueSignals]

queueSignals :: Scenario
queueSignals =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/telemetry-contract"),
      revision = 1,
      summary = "Checks queue process spans, traced enqueue parentage, and acknowledgement status.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingSdkInMemory]) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsCollect),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runQueueSignals
    }

runQueueSignals :: RunContext -> IO ScenarioReport
runQueueSignals context = case telemetrySpecFromContext context of
  Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
  Right spec -> withTelemetry spec \telemetry ->
    withJobRuntime (requirePostgres context).connectionString telemetry.tracer \runtime -> do
      let job = Job "telemetry-job" (queueRef (sourceName context "telemetry-job")) (aesonJobCodec @Text) FifoHeads defaultRetryPolicy
          workerJob = Job "telemetry-worker" (queueRef (sourceName context "telemetry-worker")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          tuning = withOrdering FifoHeads defaultJobTuning
          headers = MessageHeaders (object ["x-pgmq-group" .= ("telemetry-group" :: Text)])
          enqueueOne target payload = runJobEff runtime (enqueue target payload) >>= either (fail . show) pure
          enqueueWithTrace target payload = case telemetry.tracerProvider of
            Nothing -> enqueueOne target payload
            Just provider -> case telemetry.tracer of
              Nothing -> enqueueOne target payload
              Just activeTracer -> inSpan' activeTracer ("queue-source-" <> payload) defaultSpanArguments \_ ->
                runJobEff runtime (enqueueTraced provider target headers payload) >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
      _ <- enqueueWithTrace job "done"
      _ <- enqueueWithTrace job "dead"
      let handler _ payload = pure (if payload == "dead" then Dead "telemetry dead" else Done)
      handled <- runJobEff runtime (runJobOnceWithContext tuning 2 job handler) >>= either (fail . show) pure
      _ <- enqueueWithTrace job "throw"
      thrown <- runJobEff runtime (runJobOnceWithContext tuning {visibilityTimeout = 1} 1 job (\_ _ -> liftIO (fail "telemetry handler threw"))) >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue workerJob) >>= either (fail . show) pure
      workerCalls <- newIORef (0 :: Int)
      let workerHandler _ payload = do
            liftIO (atomicModifyIORef' workerCalls (\count -> (count + 1, ())))
            pure (if payload == "worker-dead" then Dead "worker telemetry dead" else Done)
          workerTuning = defaultJobTuning {polling = PollEvery 0.1}
          runWorker = runJobEff runtime do
            started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext workerTuning workerJob workerHandler]
            case started of
              Left err -> liftIO (fail (show err))
              Right app -> waitApp app
          awaitCalls 0 = readIORef workerCalls
          awaitCalls remaining = do
            count <- readIORef workerCalls
            if count >= 2 then pure count else threadDelay 100000 >> awaitCalls (remaining - 1)
          awaitWorkerSpans 0 = pure ()
          awaitWorkerSpans remaining = case telemetry.spans of
            Nothing -> threadDelay 100000
            Just probe -> do
              finished <- readSpans probe
              if length [() | spanValue <- finished, spanValue.name == "telemetry-worker process"] >= 2
                then pure ()
                else threadDelay 100000 >> awaitWorkerSpans (remaining - 1)
      workerTask <- async runWorker
      completedWorkerCalls <- (enqueueWithTrace workerJob "worker-done" >> enqueueWithTrace workerJob "worker-dead" >> awaitCalls (100 :: Int) <* awaitWorkerSpans (100 :: Int)) `finally` cancel workerTask
      _ <- telemetry.flushTelemetry
      spans <- maybe (pure []) readSpans telemetry.spans
      let processSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-job process"]
          workerSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-worker process"]
          roots = [spanValue | spanValue <- spans, "queue-source-" `Text.isPrefixOf` spanValue.name]
          hasText spanValue key value = lookupAttribute spanValue.attributes key == Just (AttributeValue (TextAttribute value))
          validCommon spanValue = show spanValue.kind == "Consumer" && hasText spanValue "messaging.system" "shibuya" && hasText spanValue "messaging.destination.name" "telemetry-job" && hasText spanValue "messaging.operation.type" "process" && hasText spanValue "shibuya.partition" "telemetry-group" && lookupAttribute spanValue.attributes "shibuya.inflight.count" == Nothing
          acknowledged = case processSpans of
            [first, second, third] -> hasText first "shibuya.ack.decision" "ack_ok" && first.status == Ok && hasText second "shibuya.ack.decision" "ack_dead_letter" && (case second.status of Error _ -> True; _ -> False) && lookupAttribute third.attributes "shibuya.ack.decision" == Nothing && (case third.status of Error _ -> True; _ -> False)
            _ -> False
          parented = all (\spanValue -> any (\root -> spanValue.traceId == root.traceId && spanValue.parentSpanId == Just root.spanId) roots) (processSpans <> workerSpans)
          workerAcknowledged = length [() | spanValue <- workerSpans, hasText spanValue "shibuya.ack.decision" "ack_ok" && spanValue.status == Ok] == 1 && length [() | spanValue <- workerSpans, hasText spanValue "shibuya.ack.decision" "ack_dead_letter" && case spanValue.status of { Error _ -> True; _ -> False }] == 1
          cells =
            [ ("drain-deliveries", handled == 2 && thrown == 0),
              ("drain-process-spans", if maybe True (const False) telemetry.tracer then null processSpans else length processSpans == 3 && all validCommon processSpans && acknowledged),
              ("traced-enqueue-parentage", if maybe True (const False) telemetry.tracer then null roots else length roots == 5 && parented),
              ("worker-deliveries", completedWorkerCalls == 2),
              ("worker-process-spans", if maybe True (const False) telemetry.tracer then null workerSpans else length workerSpans == 2 && all (\spanValue -> show spanValue.kind == "Consumer" && hasText spanValue "messaging.system" "shibuya" && lookupAttribute spanValue.attributes "shibuya.inflight.count" /= Nothing && lookupAttribute spanValue.attributes "shibuya.inflight.max" /= Nothing) workerSpans && workerAcknowledged)
            ]
      putSummary context Measurements "queue-telemetry" (object ["handled" .= handled, "workerCalls" .= completedWorkerCalls, "processSpanCount" .= length processSpans, "workerSpanCount" .= length workerSpans, "sourceSpanCount" .= length roots])
      recordCells context cells
