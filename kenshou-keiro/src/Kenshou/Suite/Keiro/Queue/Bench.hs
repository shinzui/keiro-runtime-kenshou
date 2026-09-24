module Kenshou.Suite.Keiro.Queue.Bench (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (finally)
import Control.Monad (forM, unless)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueBatch, enqueueToGroup, enqueueTraced, ensureJobQueue, runJobOnceWithContext, withOrdering)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
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
import Kenshou.Measure.Session (MeasureConfig (..), measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Pgmq.Types (MessageHeaders (..), queueNameToText)

scenarios :: [Scenario]
scenarios = [jobThroughput, enqueueBenchmark]

enqueueBenchmark :: Scenario
enqueueBenchmark =
  jobThroughput
    { id = either (error . show) id (parseScenarioId "keiro/queue/benchmark/enqueue"),
      summary = "Compares single, ten-row, hundred-row, and traced queue enqueue calls.",
      knobs = telemetryKnobs <> measureKnobs Benchmark <> [intKnob "queue.iterations" 1200 1 100000],
      run = runEnqueueBenchmark
    }

runEnqueueBenchmark :: RunContext -> IO ScenarioReport
runEnqueueBenchmark context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 0 1 1)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry ->
    withJobRuntime (requirePostgres context).connectionString telemetry.tracer \runtime -> do
      let job = Job "enqueue-bench" (queueRef (sourceName context "enqueue-bench")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          iterations = fromIntegral (knobInt context.knobs (name "queue.iterations"))
          measuredConfig = config {defaultPhases = (config.defaultPhases) {steady = SteadyCount iterations}}
          table = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          countStatement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          queueCount = Pool.use runtime.runtimePool (Session.statement () countStatement) >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
      ((generated, acceptedRows), report) <- withMeasurement context measuredConfig \measurement -> do
        singleOp <- registerOp (measurementRecorder measurement) (OpName "queue.enqueue-single")
        tenOp <- registerOp (measurementRecorder measurement) (OpName "queue.enqueue-batch-10")
        hundredOp <- registerOp (measurementRecorder measurement) (OpName "queue.enqueue-batch-100")
        tracedOp <- registerOp (measurementRecorder measurement) (OpName "queue.enqueue-traced")
        singleRecorder <- newWorkerRecorder singleOp 0
        tenRecorder <- newWorkerRecorder tenOp 0
        hundredRecorder <- newWorkerRecorder hundredOp 0
        tracedRecorder <- newWorkerRecorder tracedOp 0
        accepted <- newIORef (0 :: Int)
        let timed recorder expected action = do
              started <- getMonotonicTimeNSec
              result <- action
              ended <- getMonotonicTimeNSec
              let actual = case result of
                    Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                    Right count | count == expected -> OpOk count
                    Right _ -> OpFailed (ErrorCause "wrong-batch-size")
              recordOp recorder started started ended actual
              case actual of
                OpOk count -> atomicModifyIORef' accepted (\total -> (total + count, ()))
                OpFailed _ -> pure ()
              pure (case actual of OpOk _ -> True; _ -> False)
            cycleOnce _ sequenceNumber = do
              let prefix = Text.pack (show sequenceNumber)
                  payload suffix = prefix <> "-" <> suffix
                  batchPayloads amount suffix = [payload (suffix <> "-" <> Text.pack (show index)) | index <- [1 .. amount :: Int]]
              singleOk <- timed singleRecorder 1 (fmap (fmap (const 1)) (runJobEff runtime (enqueue job (payload "single"))))
              tenOk <- timed tenRecorder 10 (fmap (fmap length) (runJobEff runtime (enqueueBatch job (batchPayloads 10 "ten"))))
              hundredOk <- timed hundredRecorder 100 (fmap (fmap length) (runJobEff runtime (enqueueBatch job (batchPayloads 100 "hundred"))))
              tracedOk <- case telemetry.tracerProvider of
                Nothing -> pure True
                Just provider -> timed tracedRecorder 1 (fmap (fmap (const 1)) (runJobEff runtime (enqueueTraced provider job (MessageHeaders (object [])) (payload "traced"))))
              pure (if singleOk && tenOk && hundredOk && tracedOk then OpOk (111 + if isJust telemetry.tracerProvider then 1 else 0) else OpFailed (ErrorCause "enqueue-cycle"))
        generated <- runLoad measurement (ClosedLoop (ClosedConfig 1 0 0)) (Operation (OpName "queue.enqueue-cycle") cycleOnce)
        acceptedRows <- readIORef accepted
        pure (generated, acceptedRows)
      depth <- queueCount
      let completed = fromIntegral generated.completed :: Int
          perCycle = if isJust telemetry.tracerProvider then 112 else 111
          cells =
            [ ("enqueue-operations-completed", completed > 0 && generated.failed == 0),
              ("no-loss", acceptedRows == completed * perCycle && depth == fromIntegral acceptedRows)
            ]
      putSummary context Measurements "queue-enqueue" (object ["cycles" .= completed, "tracedEnabled" .= isJust telemetry.tracerProvider, "acceptedRows" .= acceptedRows, "queueDepth" .= depth])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})

jobThroughput :: Scenario
jobThroughput =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/queue/benchmark/job-throughput"),
      revision = 1,
      summary = "Measures open-loop job enqueue and enqueue-to-handler-start latency with concurrent drainers.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ doubleKnob "queue.rate" 500 1 100000,
               intKnob "queue.duration-seconds" 120 1 3600,
               intKnob "queue.batch-size" 10 1 1000,
               intKnob "queue.workers" 4 1 32,
               intKnob "queue.groups" 50 1 100000,
               intKnob "queue.visibility-timeout-seconds" 30 1 3600,
               textKnob "queue.ordering" "unordered" ["fifo-heads"]
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 1 120 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runJobThroughput
    }

runJobThroughput :: RunContext -> IO ScenarioReport
runJobThroughput context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 1 duration 5)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry ->
    withJobRuntime (requirePostgres context).connectionString telemetry.tracer \runtime -> do
      let ordered = knobText context.knobs (name "queue.ordering") == "fifo-heads"
          policy = if ordered then FifoHeads else Unordered
          job = Job "throughput-job" (queueRef (sourceName context "throughput")) (aesonJobCodec @Text) policy defaultRetryPolicy
          batch = fromIntegral (knobInt context.knobs (name "queue.batch-size")) :: Int
          workers = fromIntegral (knobInt context.knobs (name "queue.workers")) :: Int
          groups = fromIntegral (knobInt context.knobs (name "queue.groups")) :: Int
          rate = knobDouble context.knobs (name "queue.rate")
          tuning = (if ordered then withOrdering FifoHeads else id) defaultJobTuning {visibilityTimeout = fromIntegral (knobInt context.knobs (name "queue.visibility-timeout-seconds"))}
          load = OpenLoop (OpenConfig (ConstantRate rate) 128 1 (OverloadConfig 1000000000 3 30000000000))
          table = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          countStatement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          queueCount = Pool.use runtime.runtimePool (Session.statement () countStatement) >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
      enqueuedAt <- newIORef Map.empty
      handled <- newIORef Set.empty
      stop <- newIORef False
      workerErrors <- newIORef (0 :: Int)
      let enqueueOne _ sequenceNumber = do
            started <- getMonotonicTimeNSec
            let payload = Text.pack (show sequenceNumber)
                group = "group-" <> Text.pack (show (fromIntegral sequenceNumber `mod` groups :: Int))
            atomicModifyIORef' enqueuedAt (\seen -> (Map.insert payload started seen, ()))
            sent <- runJobEff runtime (if ordered then enqueueToGroup job group payload else enqueue job payload)
            pure case sent of
              Right _ -> OpOk 1
              Left err -> OpFailed (ErrorCause (Text.pack (show err)))
          awaitHandled :: Int -> Int -> IO Bool
          awaitHandled 0 _ = pure False
          awaitHandled remaining expected = do
            seen <- readIORef handled
            depth <- queueCount
            if Set.size seen == expected && depth == 0 then pure True else threadDelay 10000 >> awaitHandled (remaining - 1) expected
      ((generated, drained), report) <- withMeasurement context config \measurement -> do
        handlerOp <- registerOp (measurementRecorder measurement) (OpName "queue.enqueue-to-handler-start")
        workerTasks <- forM [0 .. workers - 1] \workerId -> do
          recorder <- newWorkerRecorder handlerOp workerId
          let handler _ payload = do
                started <- liftIO getMonotonicTimeNSec
                stamps <- liftIO (readIORef enqueuedAt)
                case Map.lookup payload stamps of
                  Nothing -> liftIO (atomicModifyIORef' workerErrors (\count -> (count + 1, ())))
                  Just enqueued -> liftIO (recordOp recorder enqueued enqueued started (OpOk 1))
                liftIO (atomicModifyIORef' handled (\seen -> (Set.insert payload seen, ())))
                pure Done
              loop = do
                halted <- readIORef stop
                unless halted do
                  result <- runJobEff runtime (runJobOnceWithContext tuning batch job handler)
                  case result of
                    Left _ -> atomicModifyIORef' workerErrors (\count -> (count + 1, ())) >> threadDelay 10000
                    Right 0 -> threadDelay 1000
                    Right _ -> pure ()
                  loop
          async loop
        ( do
            generated <- runLoad measurement load (Operation (OpName "queue.enqueue") enqueueOne)
            drained <- awaitHandled 3000 (fromIntegral generated.completed)
            pure (generated, drained)
          )
          `finally` (writeIORef stop True >> mapM_ cancel workerTasks)
      seen <- readIORef handled
      depth <- queueCount
      errors <- readIORef workerErrors
      let completed = fromIntegral generated.completed :: Int
          cells =
            [ ("enqueue-load-completed", completed > 0 && generated.failed == 0 && not generated.abortedEarly && errors == 0),
              ("no-loss", drained && depth == (0 :: Int64) && Set.size seen == completed)
            ]
      putSummary context Measurements "queue-job-throughput" (object ["rate" .= rate, "batchSize" .= batch, "workers" .= workers, "ordering" .= (if ordered then "fifo-heads" else "unordered" :: Text), "enqueued" .= completed, "handled" .= Set.size seen, "queueDepth" .= depth])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})
  where
    duration = fromIntegral (knobInt context.knobs (name "queue.duration-seconds"))

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

doubleKnob :: Text -> Double -> Double -> Double -> KnobSpec
doubleKnob key def low high = KnobSpec (name key) key KnobDouble (VDouble def) (DoubleRange low high) []

textKnob :: Text -> Text -> [Text] -> KnobSpec
textKnob key def alternatives = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
