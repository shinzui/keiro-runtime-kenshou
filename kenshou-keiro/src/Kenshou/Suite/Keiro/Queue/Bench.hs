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
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueToGroup, ensureJobQueue, runJobOnceWithContext, withOrdering)
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
import Kenshou.Measure.Load (Arrival (..), LoadModel (..), LoadReport (..), OpenConfig (..), Operation (..), OverloadConfig (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..), newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Pgmq.Types (queueNameToText)

scenarios :: [Scenario]
scenarios = [jobThroughput]

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
