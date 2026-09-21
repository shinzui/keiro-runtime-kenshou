module Kenshou.Telemetry.SelfTest.Arms (armsScenario) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (Benchmark), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as Core
import Kenshou.Core.Scenario
import Kenshou.Measure.Clock (Nanos (..))
import Kenshou.Measure.Knobs
import Kenshou.Measure.Load
import Kenshou.Measure.Phase qualified as Measure
import Kenshou.Measure.Recorder (OpName (..))
import Kenshou.Measure.Session
import Kenshou.Telemetry
import Kenshou.Telemetry.SelfTest.Service

armsScenario :: Scenario
armsScenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "selftest/telemetry/benchmark/arms-on-synthetic-service"),
      revision = 1,
      summary = "Measures one synthetic service under every tracing and metrics arm.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = loadKnobs defaults <> measureKnobs Benchmark <> workKnobs <> telemetryKnobs,
      dimensions = allTelemetryArms noDimensions,
      phases = Core.PhasePlan 0.1 10 0.1,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runArms
    }
  where
    defaults = defaultLoadDefaults {model = "closed", workers = 4, thinkTimeUs = 0}

runArms :: RunContext -> IO ScenarioReport
runArms context = case (telemetrySpecFromContext context, loadModelFromKnobs context.knobs, measureConfigFromKnobs context phases) of
  (Left message, _, _) -> pure (failedWith ["invalid-telemetry-config"] message)
  (_, Left message, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, _, Left message) -> pure (failedWith ["invalid-measure-config"] message)
  (Right telemetrySpec, Right loadModel, Right measureConfig) ->
    withTelemetry telemetrySpec \telemetry -> do
      let spanCount = integer "work.spans-per-op"
          attributeCount = integer "work.attributes-per-span"
          cpuMicros = integer "work.cpu-micros"
          operation = Operation (OpName "synthetic") (\_ _ -> runSyntheticOperation telemetry.tracer spanCount attributeCount cpuMicros)
      (_, measurement) <- withMeasurement context measureConfig (\session -> runLoad session loadModel operation)
      pure (passed {outcome = measuredOutcome measurement passed.outcome})
  where
    duration = fromIntegral (knobInt context.knobs (name "load.duration-seconds")) * 1_000_000_000
    phases = Measure.PhasePlan (Nanos 100_000_000) (Measure.SteadyFor (Nanos duration)) (Nanos 100_000_000)
    integer key = fromIntegral (knobInt context.knobs (name key))

workKnobs :: [KnobSpec]
workKnobs =
  [ intKnob "work.cpu-micros" "Synthetic CPU work per operation" 1000 0 100000,
    intKnob "work.spans-per-op" "Spans emitted per operation" 2 1 16,
    intKnob "work.attributes-per-span" "Attributes attached to every span" 6 0 64,
    intKnob "load.duration-seconds" "Steady measurement duration" 10 1 3600
  ]

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob key summary def low high = KnobSpec (name key) summary KnobInt (VInt def) (IntRange low high) []

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName
