{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Bench.ConcurrencySweep (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TBQueue, atomically, newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
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
import Kenshou.Suite.Shibuya.Knobs (PartitionMode (..), parseConcurrency, parseOrdering, parsePartitions)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..), reserveFreePort)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (QueueProcessor (..), defaultAppConfig, getAppMaster, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Metrics.Server qualified as Metrics
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-ordering/benchmark/concurrency-sweep"),
      revision = 2,
      summary = "Measures intended-send-to-finalize latency under serial and configured concurrency at a fixed arrival rate.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ KnobSpec (name "bench.arm") "Serial baseline or configured runner" KnobText (VText "configured") (OneOf (VText "serial" :| [VText "configured"])) [VText "serial", VText "configured"],
               KnobSpec (name "bench.rate") "Scheduled messages per second" KnobInt (VInt 200) (IntRange 200 1000) [VInt 200, VInt 1000],
               KnobSpec (name "shibuya.messages") "Scheduled messages" KnobInt (VInt 1000) (IntRange 1000 10000) [VInt 1000, VInt 10000],
               KnobSpec (name "shibuya.handler-delay-micros") "Handler service delay" KnobInt (VInt 1000) (IntRange 0 5000) [VInt 1000, VInt 5000],
               KnobSpec (name "shibuya.concurrency") "serial, ahead:N, or async:N" KnobText (VText "async:4") AnyValue (map VText ["serial", "ahead:2", "ahead:5", "ahead:10", "ahead:20", "async:2", "async:5", "async:10", "async:20"]),
               KnobSpec (name "shibuya.ordering") "strict-in-order, partitioned-in-order, or unordered" KnobText (VText "unordered") AnyValue (map VText ["unordered", "partitioned-in-order"]),
               KnobSpec (name "shibuya.partitions") "none, uniform:N, hot-key:N, or high-cardinality" KnobText (VText "none") AnyValue (map VText ["none", "uniform:16", "hot-key:16", "high-cardinality"])
             ],
      dimensions = allTelemetryArms noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runSweep
    }

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

data Delivery = Delivery
  { number :: !Int,
    intended :: !Word64,
    published :: !Word64,
    partitionKey :: !(Maybe Text)
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

runSweep :: RunContext -> IO ScenarioReport
runSweep context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-config"] problem)
  Right telemetrySpec -> do
    serverRef <- newIORef Nothing
    withTelemetry telemetrySpec (\telemetry -> runSweepWithTelemetry context telemetry serverRef)
      `finally` (readIORef serverRef >>= mapM_ Metrics.stopMetricsServer)

runSweepWithTelemetry :: RunContext -> TelemetryHandles -> IORef (Maybe Metrics.MetricsServer) -> IO ScenarioReport
runSweepWithTelemetry context telemetry serverRef =
  case (parseConcurrency (knobText context.knobs (name "shibuya.concurrency")), parseOrdering (knobText context.knobs (name "shibuya.ordering")), parsePartitions (knobText context.knobs (name "shibuya.partitions")), measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
    (Left problem, _, _, _) -> pure (failedWith ["invalid-concurrency"] problem)
    (_, Left problem, _, _) -> pure (failedWith ["invalid-ordering"] problem)
    (_, _, Left problem, _) -> pure (failedWith ["invalid-partitions"] problem)
    (_, _, _, Left problem) -> pure (failedWith ["invalid-measure-config"] problem)
    (Right selectedConcurrency, Right ordering, Right partitions, Right config) -> do
      let messages = fromIntegral (knobInt context.knobs (name "shibuya.messages")) :: Int
          rate = fromIntegral (knobInt context.knobs (name "bench.rate")) :: Double
          delay = fromIntegral (knobInt context.knobs (name "shibuya.handler-delay-micros")) :: Int
          arm = knobText context.knobs (name "bench.arm")
          concurrency = if arm == "serial" then Serial else selectedConcurrency
          measuredConfig = config {defaultPhases = MeasurePhase.PhasePlan (Nanos 0) (MeasurePhase.SteadyCount (fromIntegral messages)) (Nanos 0)}
      outcome <- try @SomeException $ timeout 180000000 $ withMeasurement context measuredConfig \measurement -> do
        operation <- registerOp (measurementRecorder measurement) (OpName "publish-to-finalize")
        recorder <- newWorkerRecorder operation 0
        recorderLock <- newMVar ()
        completed <- newIORef (0 :: Int)
        counters <- newLoadCounters
        series <- openLoadSeries measurement
        queue <- newTBQueueIO (fromIntegral (messages + 1))
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Steady
        sampleLoad series measurement counters
        let flow = do
              let handler _ = liftIO (threadDelay delay) >> pure AckOk
                  processor = (mkProcessor (benchAdapter queue recorder recorderLock completed counters) handler) {ordering, concurrency}
              started <- runApp defaultAppConfig [(ProcessorId "concurrency-sweep", processor)]
              application <- either (error . show) pure started
              if telemetry.servesEndpoints
                then liftIO $ do
                  port <- reserveFreePort
                  server <- Metrics.startMetricsServer Metrics.defaultConfig {Metrics.port = port} (getAppMaster application)
                  writeIORef serverRef (Just server)
                  registerMetricsEndpoints telemetry port
                else pure ()
              liftIO $ produce queue messages rate partitions (sampleLoad series measurement counters) counters
              waitApp application
              stopApp application
        case telemetry.tracer of
          Just tracer -> runEff (runTracing tracer flow)
          Nothing -> runEff (runTracingNoop flow)
        count <- readIORef completed
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Drain
        sampleLoad series measurement counters
        closeLoadSeries series
        offeredCount <- readIORef counters.offered
        startedCount <- readIORef counters.started
        completedCount <- readIORef counters.completed
        failedCount <- readIORef counters.failed
        maxLagNs <- readIORef counters.maxLag
        appendLoadReport measurement $ LoadReport (OpenLoop (OpenConfig (ConstantRate rate) 1 1 (OverloadConfig 1000000000 3 30000000000))) offeredCount startedCount completedCount failedCount maxLagNs Nothing False
        pure count
      case outcome of
        Left err -> pure (failedWith ["concurrency-sweep-exception"] (Text.pack (displayException err)))
        Right Nothing -> pure (failedWith ["concurrency-sweep-timeout"] "fixed-count concurrency sweep exceeded 180 seconds")
        Right (Just (count, report)) -> do
          let failures = ["message-count-mismatch" | count /= messages]
              base = if null failures then passed else failedWith failures ("finalized " <> Text.pack (show count) <> " of " <> Text.pack (show messages))
              reasons = ["local-placement" | context.environmentSpec.placement /= RunOnCell] :: [Text]
          putSummary context Measurements "concurrency-sweep" $
            object
              [ "arm" .= arm,
                "concurrency" .= show concurrency,
                "ordering" .= show ordering,
                "partitions" .= knobText context.knobs (name "shibuya.partitions"),
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

produce :: TBQueue (Maybe Delivery) -> Int -> Double -> PartitionMode -> IO () -> LoadCounters -> IO ()
produce queue messages rate partitions sample counters = do
  first <- nowNs
  let gap = max 1 (round (1000000000 / rate)) :: Word64
  forM_ [1 .. messages] \number -> do
    let intended = first + fromIntegral (number - 1) * gap
    atomicModifyIORef' counters.offered (\value -> (value + 1, ()))
    sleepUntilNs intended
    published <- nowNs
    atomicModifyIORef' counters.started (\value -> (value + 1, ()))
    atomicModifyIORef' counters.maxLag (\value -> (max value (published - min published intended), ()))
    atomically $ writeTBQueue queue $ Just (Delivery number intended published (partitionFor partitions number))
    if number `mod` 100 == 0 then sample else pure ()
  atomically $ writeTBQueue queue Nothing

partitionFor :: PartitionMode -> Int -> Maybe Text
partitionFor NoPartitions _ = Nothing
partitionFor (UniformPartitions count) number = Just ("key-" <> Text.pack (show (number `mod` count)))
partitionFor (HotKey count) number = Just $ if number `mod` 5 /= 0 then "hot" else "key-" <> Text.pack (show (number `mod` count))
partitionFor HighCardinality number = Just ("key-" <> Text.pack (show number))

benchAdapter :: (IOE :> es, Tracing :> es) => TBQueue (Maybe Delivery) -> WorkerRecorder -> MVar () -> IORef Int -> LoadCounters -> Adapter es Delivery
benchAdapter queue recorder recorderLock successful counters =
  Adapter
    { adapterName = "kenshou:concurrency-sweep",
      source = Stream.unfoldrM step (),
      shutdown = pure ()
    }
  where
    step () = do
      item <- liftIO $ atomically $ readTBQueue queue
      case item of
        Nothing -> pure Nothing
        Just delivery -> do
          let envelope = (mkEnvelope (MessageId (Text.pack (show delivery.number))) delivery) {partition = delivery.partitionKey}
              ack = AckHandle $ \decision -> liftIO $ do
                ended <- nowNs
                withMVar recorderLock $ \_ -> do
                  recordOp recorder delivery.intended delivery.published ended (if decision == AckOk then OpOk 1 else OpFailed (ErrorCause "unexpected-acknowledgement"))
                  atomicModifyIORef' counters.completed (\count -> (count + 1, ()))
                  if decision == AckOk
                    then atomicModifyIORef' successful (\count -> (count + 1, ()))
                    else atomicModifyIORef' counters.failed (\count -> (count + 1, ()))
          pure $ Just (mkIngested envelope ack, ())
