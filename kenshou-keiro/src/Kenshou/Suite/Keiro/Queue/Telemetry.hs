module Kenshou.Suite.Keiro.Queue.Telemetry (scenarios) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, threadDelay, tryPutMVar)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (finally)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Effectful.Exception qualified as Eff
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Dlq (DlqEntry (..), readDlq)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), RetryDelay (..), RetryPolicy (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueTraced, ensureJobQueue, jobProcessorWithContext, runJobOnceWithContext, runJobWorkers, withOrdering)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Suite.Keiro.Queue.Metrics qualified as Metrics
import Kenshou.Telemetry (TelemetryHandles (..), TelemetrySpec (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Trace.Core (SpanStatus (..), defaultSpanArguments, inSpan')
import Pgmq.Types (MessageHeaders (..), queueNameToText)
import Shibuya.App (SupervisionStrategy (..), getAllMetricsIO, getAppMaster, stopApp, waitApp)
import Shibuya.Core.Metrics (ProcessorId (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [queueSignals, workerMetrics]

workerMetrics :: Scenario
workerMetrics =
  queueSignals
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/worker-metrics-contract"),
      summary = "Checks native and served worker counters for Done, Retry and Dead, plus the active-work gauge.",
      dimensions =
        (queueSignals.dimensions)
          { tracing = Supported (Support (TracingOff :| [TracingSdkInMemory]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsCollect)
          },
      run = runWorkerMetrics
    }

runWorkerMetrics :: RunContext -> IO ScenarioReport
runWorkerMetrics context = case telemetrySpecFromContext context of
  Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
  Right spec -> Metrics.withQueueTelemetry context spec \telemetry metrics ->
    withJobRuntime (requirePostgres context).connectionString telemetry.tracer \runtime -> do
      let job = Job "queue-metrics-contract" (queueRef (sourceName context "worker-metrics")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          tuning = defaultJobTuning {polling = PollEvery 0.01}
          processor = ProcessorId job.jobName
          activeExpected = Map.singleton processor (Metrics.WorkerCounts 1 0 0 1)
          -- Shibuya counts AckRetry as processed; this is not a terminal-Done counter.
          finalExpected = Map.singleton processor (Metrics.WorkerCounts 5 4 1 0)
          expectedCalls = Map.fromList [("held", 1), ("done", 1), ("dead", 1), ("retry", 2)]
          table = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          statement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          queueDepth = Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
          send payload = runJobEff runtime (enqueue job payload) >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
      entered <- newEmptyMVar
      release <- newEmptyMVar
      calls <- newIORef (Map.empty :: Map.Map Text Int)
      let handler _ payload = do
            occurrence <- liftIO $ atomicModifyIORef' calls \seen ->
              let next = Map.findWithDefault 0 payload seen + 1 in (Map.insert payload next seen, next)
            case payload of
              "held" -> liftIO (putMVar entered () >> readMVar release) >> pure Done
              "dead" -> pure (Dead "metrics contract")
              "retry" | occurrence == 1 -> pure (Retry (RetryDelay 1))
              _ -> pure Done
          awaitDrained 0 = pure False
          awaitDrained remaining = do
            seen <- readIORef calls
            depth <- queueDepth
            if seen == expectedCalls && depth == 0
              then pure True
              else threadDelay 50000 >> awaitDrained (remaining - 1)
      result <- runJobEff runtime do
        started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext tuning job handler]
        app <- either (liftIO . fail . show) pure started
        let master = getAppMaster app
            awaitMetrics 0 = getAllMetricsIO master
            awaitMetrics remaining = do
              snapshot <- getAllMetricsIO master
              if Metrics.metricsMatch finalExpected snapshot
                then pure snapshot
                else threadDelay 50000 >> awaitMetrics (remaining - 1)
        ( liftIO do
            Metrics.registerWorker telemetry metrics spec.scrapeMs "queue-metrics" master
            _ <- send "held"
            active <- timeout 10000000 (readMVar entered)
            activeSnapshot <- if telemetry.metricsLive then getAllMetricsIO master else pure Map.empty
            activeHttp <- if telemetry.servesEndpoints then Metrics.probeEndpoints metrics "active" activeExpected else pure True
            putMVar release ()
            mapM_ send ["done", "dead", "retry"]
            drained <- awaitDrained (200 :: Int)
            seen <- readIORef calls
            dlq <- runJobEff runtime (readDlq job 10) >>= either (fail . show) pure
            snapshot <- if telemetry.metricsLive then awaitMetrics (100 :: Int) else pure Map.empty
            _ <- Metrics.checkpoint metrics
            finalHttp <- if telemetry.servesEndpoints then Metrics.probeEndpoints metrics "complete" finalExpected else pure True
            let checks =
                  [ ("handler-schedule-realised", active == Just ()),
                    ("job-outcomes", drained && seen == expectedCalls && case dlq of [entry] -> entry.originalPayload == Right "dead"; _ -> False),
                    ("worker-active-gauge", not telemetry.metricsLive || Metrics.metricsMatch activeExpected activeSnapshot),
                    ("worker-completion-counters", not telemetry.metricsLive || Metrics.metricsMatch finalExpected snapshot),
                    ("worker-metrics-endpoints", activeHttp && finalHttp)
                  ]
            putSummary context Measurements "queue-worker-metrics-contract" (object ["metricsEnabled" .= telemetry.metricsLive, "endpointsEnabled" .= telemetry.servesEndpoints, "handlerCalls" .= seen, "expectedActive" .= activeExpected, "observedActive" .= activeSnapshot, "expectedComplete" .= finalExpected, "observedComplete" .= snapshot, "dlqRows" .= length dlq, "drained" .= drained])
            recordCells context checks
          )
          `Eff.finally` (liftIO (tryPutMVar release ()) >> stopApp app)
      either (fail . show) pure result

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
          preHandlerJob = Job "telemetry-pre-handler" (queueRef (sourceName context "telemetry-pre-handler")) (aesonJobCodec @Text) Unordered defaultRetryPolicy {maxRetries = 0}
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
      _ <- runJobEff runtime (ensureJobQueue preHandlerJob) >>= either (fail . show) pure
      workerCalls <- newIORef (0 :: Int)
      preHandlerCalls <- newIORef (0 :: Int)
      let workerHandler _ payload = do
            liftIO (atomicModifyIORef' workerCalls (\count -> (count + 1, ())))
            pure (if payload == "worker-dead" then Dead "worker telemetry dead" else Done)
          workerTuning = defaultJobTuning {polling = PollEvery 0.1}
          preHandlerHandler _ _ = do
            liftIO (atomicModifyIORef' preHandlerCalls (\count -> (count + 1, ())))
            pure Done
          runWorker = runJobEff runtime do
            started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext workerTuning workerJob workerHandler, jobProcessorWithContext workerTuning preHandlerJob preHandlerHandler]
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
      let awaitPreHandlerDlq 0 = fail "pre-handler job did not reach the DLQ"
          awaitPreHandlerDlq remaining = do
            rows <- runJobEff runtime (readDlq preHandlerJob 1) >>= either (fail . show) pure
            if length rows == 1 then pure rows else threadDelay 100000 >> awaitPreHandlerDlq (remaining - 1)
      (completedWorkerCalls, preHandlerDlq) <-
        ( do
            _ <- enqueueWithTrace workerJob "worker-done"
            _ <- enqueueWithTrace workerJob "worker-dead"
            _ <- enqueueWithTrace preHandlerJob "pre-handler-dead"
            calls <- awaitCalls (100 :: Int)
            awaitWorkerSpans (100 :: Int)
            rows <- awaitPreHandlerDlq (100 :: Int)
            pure (calls, rows)
        )
          `finally` cancel workerTask
      observedPreHandlerCalls <- readIORef preHandlerCalls
      _ <- telemetry.flushTelemetry
      spans <- maybe (pure []) readSpans telemetry.spans
      let processSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-job process"]
          workerSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-worker process"]
          preHandlerSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-pre-handler process"]
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
              ("traced-enqueue-parentage", if maybe True (const False) telemetry.tracer then null roots else length roots == 6 && parented),
              ("worker-deliveries", completedWorkerCalls == 2),
              ("pre-handler-dead-letter", observedPreHandlerCalls == 0 && length preHandlerDlq == 1),
              ("worker-process-spans", if maybe True (const False) telemetry.tracer then null workerSpans else length workerSpans == 2 && all (\spanValue -> show spanValue.kind == "Consumer" && hasText spanValue "messaging.system" "shibuya" && lookupAttribute spanValue.attributes "shibuya.inflight.count" /= Nothing && lookupAttribute spanValue.attributes "shibuya.inflight.max" /= Nothing) workerSpans && workerAcknowledged)
            ]
      putSummary context Measurements "queue-telemetry" (object ["handled" .= handled, "workerCalls" .= completedWorkerCalls, "preHandlerCalls" .= observedPreHandlerCalls, "preHandlerDlqRows" .= length preHandlerDlq, "preHandlerSpanCount" .= length preHandlerSpans, "processSpanCount" .= length processSpans, "workerSpanCount" .= length workerSpans, "sourceSpanCount" .= length roots])
      recordCells context cells
