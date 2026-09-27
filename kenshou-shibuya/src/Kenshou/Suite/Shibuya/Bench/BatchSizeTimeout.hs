{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Bench.BatchSizeTimeout (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TBQueue, atomically, newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (IOE, liftIO, runEff, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith, passed)
import Kenshou.Measure.Clock (Nanos (..), nowNs, sleepUntilNs)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (Arrival (..), LoadModel (..), LoadReport (..), OpenConfig (..), OverloadConfig (..))
import Kenshou.Measure.Load.Series (LoadSeries, closeLoadSeries, openLoadSeries, sampleLoadSeries)
import Kenshou.Measure.Phase qualified as MeasurePhase
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..), WorkerRecorder, newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (MeasureConfig (..), Measurement, appendLoadReport, measureConfigFromKnobs, measuredOutcome, measurementPhaseClock, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..), reserveFreePort)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (QueueProcessor (..), defaultAppConfig, getAppMaster, mkBatchProcessor, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchTrigger (..), ackAllOk, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Metrics.Server qualified as Metrics
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-batch/benchmark/batch-size-and-timeout"),
      revision = 1,
      summary = "Measures batch size and timeout effects on intended-send-to-finalize latency at fixed arrivals.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ KnobSpec (name "bench.arm") "Unbatched baseline or batch processor" KnobText (VText "batched") (OneOf (VText "unbatched" :| [VText "batched"])) [VText "unbatched", VText "batched"],
               KnobSpec (name "bench.rate") "Scheduled messages per second" KnobInt (VInt 200) (IntRange 200 1000) [VInt 200, VInt 1000],
               KnobSpec (name "shibuya.messages") "Scheduled messages" KnobInt (VInt 1000) (IntRange 1000 10000) [VInt 1000, VInt 10000],
               KnobSpec (name "shibuya.handler-delay-micros") "Handler delay per invocation" KnobInt (VInt 0) (IntRange 0 5000) [VInt 0, VInt 1000],
               KnobSpec (name "shibuya.batch.size") "Maximum messages per batch" KnobInt (VInt 10) (OneOf (VInt 1 :| [VInt 10, VInt 100, VInt 1000])) [VInt 1, VInt 10, VInt 100, VInt 1000],
               KnobSpec (name "shibuya.batch.timeout-ms") "Batch age limit in milliseconds" KnobInt (VInt 100) (OneOf (VInt 10 :| [VInt 100, VInt 1000])) [VInt 10, VInt 100, VInt 1000]
             ],
      dimensions = allTelemetryArms noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runBenchmark
    }

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

data Delivery = Delivery
  { number :: !Int,
    intended :: !Word64,
    published :: !Word64
  }

data LoadCounters = LoadCounters
  { offered :: !(IORef Word64),
    started :: !(IORef Word64),
    completed :: !(IORef Word64),
    failed :: !(IORef Word64),
    maxLag :: !(IORef Word64)
  }

newLoadCounters :: IO LoadCounters
newLoadCounters = LoadCounters <$> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0

sampleLoad :: LoadSeries -> Measurement -> LoadCounters -> IO ()
sampleLoad series measurement counters = sampleLoadSeries series measurement counters.offered counters.started counters.completed counters.failed counters.maxLag

runBenchmark :: RunContext -> IO ScenarioReport
runBenchmark context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-config"] problem)
  Right telemetrySpec -> do
    serverRef <- newIORef Nothing
    withTelemetry telemetrySpec (\telemetry -> runWithTelemetry context telemetry serverRef)
      `finally` (readIORef serverRef >>= mapM_ Metrics.stopMetricsServer)

runWithTelemetry :: RunContext -> TelemetryHandles -> IORef (Maybe Metrics.MetricsServer) -> IO ScenarioReport
runWithTelemetry context telemetry serverRef =
  case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
    Left problem -> pure (failedWith ["invalid-measure-config"] problem)
    Right config -> do
      let messages = fromIntegral (knobInt context.knobs (name "shibuya.messages")) :: Int
          rate = fromIntegral (knobInt context.knobs (name "bench.rate")) :: Double
          delay = fromIntegral (knobInt context.knobs (name "shibuya.handler-delay-micros")) :: Int
          arm = knobText context.knobs (name "bench.arm")
          size = fromIntegral (knobInt context.knobs (name "shibuya.batch.size")) :: Int
          timeoutMs = fromIntegral (knobInt context.knobs (name "shibuya.batch.timeout-ms")) :: Int
          timeoutSeconds = fromIntegral timeoutMs / 1000
          measuredConfig = config {defaultPhases = MeasurePhase.PhasePlan (Nanos 0) (MeasurePhase.SteadyCount (fromIntegral messages)) (Nanos 0)}
      outcome <- try @SomeException $ timeout 180000000 $ withMeasurement context measuredConfig \measurement -> do
        operation <- registerOp (measurementRecorder measurement) (OpName "publish-to-finalize")
        recorder <- newWorkerRecorder operation 0
        recorderLock <- newMVar ()
        completed <- newIORef (0 :: Int)
        batches <- newIORef ([] :: [(BatchTrigger, Int)])
        counters <- newLoadCounters
        series <- openLoadSeries measurement
        queue <- newTBQueueIO (fromIntegral (messages + 1))
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Steady
        sampleLoad series measurement counters
        let flow = do
              let adapter = benchAdapter queue recorder recorderLock completed counters
                  handler _ = liftIO (threadDelay delay) >> pure AckOk
                  batchHandler info batchMessages = do
                    liftIO $ do
                      threadDelay delay
                      atomicModifyIORef' batches (\facts -> ((info.trigger, length (toList batchMessages)) : facts, ()))
                    pure ackAllOk
                  batchConfig = defaultBatchConfig {batchSize = size, batchTimeout = timeoutSeconds, tickInterval = Just (min 0.01 timeoutSeconds)}
                  processor =
                    if arm == "unbatched"
                      then (mkProcessor adapter handler) {concurrency = Serial}
                      else (mkBatchProcessor adapter batchHandler batchConfig) {concurrency = Serial}
              started <- runApp defaultAppConfig [(ProcessorId "batch-size-timeout", processor)]
              application <- either (error . show) pure started
              if telemetry.servesEndpoints
                then liftIO $ do
                  port <- reserveFreePort
                  server <- Metrics.startMetricsServer Metrics.defaultConfig {Metrics.port = port} (getAppMaster application)
                  writeIORef serverRef (Just server)
                  registerMetricsEndpoints telemetry port
                else pure ()
              liftIO $ produce queue messages rate (sampleLoad series measurement counters) counters
              waitApp application
              stopApp application
        case telemetry.tracer of
          Just tracer -> runEff (runTracing tracer flow)
          Nothing -> runEff (runTracingNoop flow)
        count <- readIORef completed
        batchFacts <- readIORef batches
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Drain
        sampleLoad series measurement counters
        closeLoadSeries series
        offeredCount <- readIORef counters.offered
        startedCount <- readIORef counters.started
        completedCount <- readIORef counters.completed
        failedCount <- readIORef counters.failed
        maxLagNs <- readIORef counters.maxLag
        appendLoadReport measurement $ LoadReport (OpenLoop (OpenConfig (ConstantRate rate) 1 1 (OverloadConfig 1000000000 3 30000000000))) offeredCount startedCount completedCount failedCount maxLagNs Nothing False
        pure (count, batchFacts)
      case outcome of
        Left err -> pure (failedWith ["batch-benchmark-exception"] (Text.pack (displayException err)))
        Right Nothing -> pure (failedWith ["batch-benchmark-timeout"] "fixed-count batch benchmark exceeded 180 seconds")
        Right (Just ((count, batchFacts), report)) -> do
          let batchedCount = sum (map snd batchFacts)
              failures =
                ["message-count-mismatch" | count /= messages]
                  <> ["batch-message-count-mismatch" | arm == "batched" && batchedCount /= messages]
                  <> ["unexpected-batch-records" | arm == "unbatched" && not (null batchFacts)]
                  <> ["batch-exceeded-configured-size" | any ((> size) . snd) batchFacts]
              base = if null failures then passed else failedWith failures ("finalized " <> Text.pack (show count) <> " of " <> Text.pack (show messages))
              reasons = ["local-placement" | context.environmentSpec.placement /= RunOnCell] :: [Text]
          putSummary context Measurements "batch-size-timeout" $
            object
              [ "arm" .= arm,
                "batchSize" .= size,
                "batchTimeoutMs" .= timeoutMs,
                "batches" .= length batchFacts,
                "sizeTriggers" .= length (filter ((== TriggerSize) . fst) batchFacts),
                "timeoutTriggers" .= length (filter ((== TriggerTimeout) . fst) batchFacts),
                "flushTriggers" .= length (filter ((== TriggerFlush) . fst) batchFacts),
                "batchedMessages" .= batchedCount,
                "ratePerSecond" .= rate,
                "messages" .= messages,
                "finalized" .= count,
                "handlerDelayMicros" .= delay,
                "schedule" .= ("constant-rate-intended-send" :: Text)
              ]
          putSummary context Measurements "methodology" $
            object
              [ "authoritative" .= null reasons,
                "reasons" .= reasons,
                "steadyBound" .= ("scheduled-message-count" :: Text)
              ]
          pure (base {outcome = measuredOutcome report base.outcome})

registerMetricsEndpoints :: TelemetryHandles -> Int -> IO ()
registerMetricsEndpoints telemetry port = do
  let http path = "http://127.0.0.1:" <> Text.pack (show port) <> path
      ws path = "ws://127.0.0.1:" <> Text.pack (show port) <> path
  telemetry.registerEndpoint (Endpoint "shibuya-prometheus" PrometheusText (http "/metrics/prometheus") Nothing)
  telemetry.registerEndpoint (Endpoint "shibuya-json" JsonDocument (http "/metrics") Nothing)
  telemetry.registerEndpoint (Endpoint "shibuya-health" HealthProbe (http "/health/live") Nothing)
  telemetry.registerEndpoint (Endpoint "shibuya-ws" WebSocketPush (ws "/ws") Nothing)

produce :: TBQueue (Maybe Delivery) -> Int -> Double -> IO () -> LoadCounters -> IO ()
produce queue messages rate sample counters = do
  first <- nowNs
  let gap = max 1 (round (1000000000 / rate)) :: Word64
  forM_ [1 .. messages] \number -> do
    let intended = first + fromIntegral (number - 1) * gap
    atomicModifyIORef' counters.offered (\value -> (value + 1, ()))
    sleepUntilNs intended
    published <- nowNs
    atomicModifyIORef' counters.started (\value -> (value + 1, ()))
    atomicModifyIORef' counters.maxLag (\value -> (max value (published - min published intended), ()))
    atomically $ writeTBQueue queue $ Just (Delivery number intended published)
    if number `mod` 100 == 0 then sample else pure ()
  atomically $ writeTBQueue queue Nothing

benchAdapter :: (IOE :> es, Tracing :> es) => TBQueue (Maybe Delivery) -> WorkerRecorder -> MVar () -> IORef Int -> LoadCounters -> Adapter es Delivery
benchAdapter queue recorder recorderLock successful counters =
  Adapter
    { adapterName = "kenshou:batch-size-timeout",
      source = Stream.unfoldrM step (),
      shutdown = pure ()
    }
  where
    step () = do
      item <- liftIO $ atomically $ readTBQueue queue
      case item of
        Nothing -> pure Nothing
        Just delivery -> do
          let envelope = mkEnvelope (MessageId (Text.pack (show delivery.number))) delivery
              ack = AckHandle $ \decision -> liftIO $ do
                ended <- nowNs
                withMVar recorderLock $ \_ -> do
                  recordOp recorder delivery.intended delivery.published ended (if decision == AckOk then OpOk 1 else OpFailed (ErrorCause "unexpected-acknowledgement"))
                  atomicModifyIORef' counters.completed (\count -> (count + 1, ()))
                  if decision == AckOk
                    then atomicModifyIORef' successful (\count -> (count + 1, ()))
                    else atomicModifyIORef' counters.failed (\count -> (count + 1, ()))
          pure $ Just (mkIngested envelope ack, ())
