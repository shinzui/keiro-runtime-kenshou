module Kenshou.Suite.Shibuya.Bench.FrameworkTax (scenario) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (IOE, liftIO, runEff, (:>))
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith, passed)
import Kenshou.Measure.Clock (Nanos (..), nowNs)
import Kenshou.Measure.Health (HealthConfig (..))
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Phase qualified as MeasurePhase
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpReport (..), OpResult (..), RecorderReport (..), WorkerRecorder, newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/benchmark/framework-tax"),
      revision = 2,
      summary = "Measures a bare Streamly drain and Shibuya serial processing over the same forced message list.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        measureKnobs Benchmark
          <> [ KnobSpec (name "bench.arm") "Baseline or framework processing" KnobText (VText "streamly") (OneOf (VText "streamly" :| [VText "shibuya"])) [VText "streamly", VText "shibuya"],
               KnobSpec (name "shibuya.messages") "Messages in the measured pass" KnobInt (VInt 100000) (IntRange 1000 1000000) [VInt 100000, VInt 1000000]
             ],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runFrameworkTax
    }
  where
    name = either (error . Text.unpack) id . mkKnobName

runFrameworkTax :: RunContext -> IO ScenarioReport
runFrameworkTax context =
  case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
    Left reason -> pure (failedWith ["invalid-measure-config"] reason)
    Right config -> do
      let messages = fromIntegral (knobInt context.knobs (name "shibuya.messages")) :: Int
          arm = knobText context.knobs (name "bench.arm")
          payload = ByteString.replicate 64 'x'
      -- Force both the list spine and payload before the stream can run in STM.
      input <- evaluate $ force [(number, payload) | number <- [1 .. messages]]
      -- One complete pass defines the steady window; runLoad also writes the
      -- boundary rows required by the measurement summary.
      let steadyPasses = max 1 (100000 `div` messages)
          fixedCountConfig = config {defaultPhases = MeasurePhase.PhasePlan (Nanos 0) (MeasurePhase.SteadyCount (fromIntegral steadyPasses)) (Nanos 0), healthConfig = config.healthConfig {minSteadySamples = 1, cpuSoft = 2, cpuHard = 2}}
      ((load, lastPass), report) <- withMeasurement context fixedCountConfig $ \measurement -> do
        operation <- registerOp (measurementRecorder measurement) (OpName "message")
        worker <- newWorkerRecorder operation 0
        passResult <- newIORef Nothing
        load <-
          runLoad
            measurement
            (ClosedLoop (ClosedConfig 1 0 0))
            ( Operation
                (OpName "framework-pass")
                ( \_ _ -> do
                    counter <- newIORef (0 :: Int)
                    rtsEnabled <- getRTSStatsEnabled
                    beforeRts <- if rtsEnabled then Just <$> getRTSStats else pure Nothing
                    started <- nowNs
                    case arm of
                      "streamly" -> runStreamly worker counter input
                      "shibuya" -> runShibuya worker counter input
                      _ -> fail ("unknown framework benchmark arm: " <> Text.unpack arm)
                    ended <- nowNs
                    afterRts <- if rtsEnabled then Just <$> getRTSStats else pure Nothing
                    completed <- readIORef counter
                    let allocated = (-) <$> (allocated_bytes <$> afterRts) <*> (allocated_bytes <$> beforeRts)
                    atomicModifyIORef' passResult (const (Just (completed, ended - started, allocated), ()))
                    pure $ if completed == messages then OpOk messages else OpFailed (ErrorCause "message-count-mismatch")
                )
            )
        lastPass <- readIORef passResult
        pure (load, lastPass)
      let steadyMessages = sum [fromIntegral successes :: Int | operation <- report.recorder.operations, operation.name == OpName "message", Just (successes, _, _) <- [Map.lookup MeasurePhase.Steady operation.phaseCounts]]
          failures = ["no-complete-pass" | load.completed == 0] <> ["message-count-mismatch" | load.failed > 0] <> ["missing-pass-measurement" | lastPass == Nothing] <> ["insufficient-message-samples" | steadyMessages < messages]
          base = if null failures then passed else failedWith failures ("completed passes=" <> Text.pack (show load.completed) <> "; failed passes=" <> Text.pack (show load.failed))
          perMessage = case lastPass of
            Just (_, elapsed, _) -> Just (fromIntegral elapsed / fromIntegral messages :: Double)
            Nothing -> Nothing
          allocatedPerMessage = case lastPass of
            Just (_, _, Just allocated) | allocated > 0 -> Just (fromIntegral allocated / fromIntegral messages :: Double)
            _ -> Nothing
      putSummary context Measurements "framework-tax" $
        object
          [ "arm" .= arm,
            "messages" .= messages,
            "completedPasses" .= load.completed,
            "failedPasses" .= load.failed,
            "steadyPassesTarget" .= steadyPasses,
            "steadyMessageSamples" .= steadyMessages,
            "lastPassNanosecondsPerMessage" .= perMessage,
            "lastPassAllocatedBytesPerMessage" .= allocatedPerMessage,
            "cpuBoundDriverThresholdDisabled" .= True,
            "inputForcedBeforeMeasurement" .= True
          ]
      let reasons = ["local-placement" | context.environmentSpec.placement /= RunOnCell] :: [Text.Text]
      putSummary context Measurements "methodology" $
        object
          [ "authoritative" .= null reasons,
            "reasons" .= reasons,
            "steadyBound" .= ("completed-passes" :: Text.Text),
            "cpuBoundDriverThresholdDisabled" .= True
          ]
      pure (base {outcome = measuredOutcome report base.outcome})
  where
    name = either (error . Text.unpack) id . mkKnobName

type BenchMessage = (Int, ByteString)

-- Both arms consume the same forced input and do one counter update and
-- per-message sample. The Shibuya arm includes dispatch and finalization.
runStreamly :: WorkerRecorder -> IORef Int -> [BenchMessage] -> IO ()
runStreamly worker counter input =
  Stream.fold Fold.drain $ Stream.mapM process $ Stream.fromList input
  where
    process _ = do
      started <- nowNs
      atomicModifyIORef' counter (\count -> let next = count + 1 in (next, ()))
      ended <- nowNs
      recordOp worker started started ended (OpOk 1)

runShibuya :: WorkerRecorder -> IORef Int -> [BenchMessage] -> IO ()
runShibuya worker counter input = runEff $ runTracingNoop $ do
  let handler _ = do
        liftIO $ atomicModifyIORef' counter (\count -> let next = count + 1 in (next, ()))
        pure AckOk
      processor = mkProcessor (benchAdapter worker input) handler
  result <- runApp defaultAppConfig [(ProcessorId "framework-tax", processor)]
  case result of
    Left err -> error (show err)
    Right handle -> waitApp handle >> stopApp handle

benchAdapter :: (IOE :> es) => WorkerRecorder -> [BenchMessage] -> Adapter es BenchMessage
benchAdapter worker input =
  Adapter
    { adapterName = "kenshou:framework-tax",
      source = Stream.mapM wrap (Stream.fromList input),
      shutdown = pure ()
    }
  where
    wrap message@(number, _) = do
      started <- liftIO nowNs
      let envelope = mkEnvelope (MessageId (Text.pack (show number))) message
          ack = AckHandle $ \_ -> liftIO $ do
            ended <- nowNs
            recordOp worker started started ended (OpOk 1)
      pure $ mkIngested envelope ack
