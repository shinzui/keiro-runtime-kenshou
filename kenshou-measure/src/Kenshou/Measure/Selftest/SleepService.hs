module Kenshou.Measure.Selftest.SleepService (sleepServiceScenario) where

import Control.Concurrent (threadDelay)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (Benchmark), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as Core
import Kenshou.Core.Scenario
import Kenshou.Measure.Clock
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Knobs
import Kenshou.Measure.Load
import Kenshou.Measure.Recorder
import Kenshou.Measure.Session

sleepServiceScenario :: Scenario
sleepServiceScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/measure/benchmark/sleep-service"),
      revision = 1,
      summary = "Demonstrates intended-start latency and coordinated-omission correction.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = loadKnobs defaults <> measureKnobs Benchmark <> serviceKnobs,
      dimensions = telemetryOff,
      phases = Core.PhasePlan 5 30 5,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runSleepService
    }
  where
    defaults = defaultLoadDefaults {model = "open-constant", workers = 1, ratePerSecond = 100, executors = 1, maxLagMs = 5_000}

runSleepService :: RunContext -> IO ScenarioReport
runSleepService context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left message, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, Left message) -> pure (failedWith ["invalid-measure-config"] message)
  (Right model, Right config) -> do
    serviceStart <- nowNs
    let baseLatencyUs = knobInt context.knobs (name "service.base-latency-us")
        stallMs = knobInt context.knobs (name "service.stall-ms")
        stallEveryMs = knobInt context.knobs (name "service.stall-every-ms")
        operation = Operation (OpName "request") (\_ _ -> serviceCall serviceStart (fromIntegral baseLatencyUs) (fromIntegral stallMs) (fromIntegral stallEveryMs))
    (_, report) <- withMeasurement context config (\measurement -> runLoad measurement model operation)
    pure (assess model (fromIntegral baseLatencyUs * 1_000) report)

serviceCall :: Word64 -> Word64 -> Word64 -> Word64 -> IO OpResult
serviceCall serviceStart baseLatencyUs stallMs stallEveryMs = do
  current <- nowNs
  let intervalNs = stallEveryMs * 1_000_000
      stallNs = stallMs * 1_000_000
      elapsed = current - min current serviceStart
      offset = elapsed `mod` intervalNs
  if offset < stallNs then sleepUntilNs (current + stallNs - offset) else pure ()
  threadDelay (fromIntegral baseLatencyUs)
  pure (OpOk 1)

assess :: LoadModel -> Word64 -> MeasurementReport -> ScenarioReport
assess model baseLatencyNs report = case find ((== OpName "request") . (.name)) report.recorder.operations of
  Nothing -> failedWith ["missing-request-report"] "request operation was not recorded"
  Just operation ->
    let latencyP99 = Histogram.valueAtQuantile operation.latency 0.99
        serviceP99 = Histogram.valueAtQuantile operation.service 0.99
        maximumLatency = Histogram.maxValue operation.latency
        failures = case model of
          OpenLoop _ -> ["intended-p99" | latencyP99 < 800_000_000 || latencyP99 > 1_000_000_000] <> ["service-p99" | serviceP99 >= 5 * baseLatencyNs]
          ClosedLoop _ -> ["closed-p99" | latencyP99 >= 5 * baseLatencyNs] <> ["closed-max" | maximumLatency <= 900_000_000]
     in if null failures then passed else failedWith failures ("unexpected latency distribution: p99=" <> showText latencyP99 <> " service-p99=" <> showText serviceP99 <> " max=" <> showText maximumLatency)

serviceKnobs :: [KnobSpec]
serviceKnobs =
  [ intKnob "service.base-latency-us" "Base service latency" 1_000 1 60_000_000,
    intKnob "service.stall-ms" "Periodic stall duration" 1_000 1 60_000,
    intKnob "service.stall-every-ms" "Period between stall starts" 10_000 2 600_000
  ]

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

showText :: (Show value) => value -> Text
showText = Text.pack . show
