module Kenshou.Measure.Selftest.RegressionInjected (regressionInjectedScenario) where

import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (Benchmark), parseScenarioId)
import Kenshou.Core.Id qualified as Id
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as Core
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs
import Kenshou.Measure.Load
import Kenshou.Measure.Recorder
import Kenshou.Measure.Session
import System.Random.SplitMix (mkSMGen, nextWord64)

regressionInjectedScenario :: Scenario
regressionInjectedScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/measure/benchmark/regression-injected"),
      revision = 1,
      summary = "Produces controlled slowdown and noise for comparator verification.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = loadKnobs (defaultLoadDefaults {model = "closed", workers = 4}) <> measureKnobs Benchmark <> serviceKnobs,
      dimensions = telemetryOff,
      phases = Core.PhasePlan 2 10 1,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runRegressionInjected
    }

runRegressionInjected :: RunContext -> IO ScenarioReport
runRegressionInjected context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left message, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, Left message) -> pure (failedWith ["invalid-measure-config"] message)
  (Right model, Right config) -> do
    let base = knobInt context.knobs (name "service.base-latency-us")
        extra = knobInt context.knobs (name "service.extra-latency-us")
        noise = knobText context.knobs (name "service.noise")
        factor = if noise == "high" then noiseFactor (Id.unSeed context.seed) else 1
        delay = max 1 (floor (fromIntegral (base + extra) * factor))
        operation = Operation (OpName "work") (\_ _ -> threadDelay delay >> pure (OpOk 1))
    (_, report) <- withMeasurement context config (\measurement -> runLoad measurement model operation)
    let count = case report.recorder.operations of operationReport : _ -> sum [successes | (successes, _, _) <- Map.elems operationReport.phaseCounts]; [] -> 0
    pure (if count >= 1_000 then passed else failedWith ["insufficient-samples"] ("steady samples=" <> Text.pack (show count)))

noiseFactor :: Word64 -> Double
noiseFactor seed =
  let (word, _) = nextWord64 (mkSMGen seed)
      unit = fromIntegral word / fromIntegral (maxBound :: Word64)
   in exp (log 0.6 + unit * (log 1.6 - log 0.6))

serviceKnobs :: [KnobSpec]
serviceKnobs =
  [ intKnob "service.base-latency-us" "Base operation latency" 2_000 1 60_000_000,
    intKnob "service.extra-latency-us" "Injected operation latency" 0 0 60_000_000,
    textKnob "service.noise" "Run-level latency noise" "none" ["none", "high"],
    textKnob "service.label" "Behaviour-neutral comparison label" "a" ["a", "b"]
  ]

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt def) (IntRange low high) []

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob knobName summary def (first : rest) = KnobSpec (name knobName) summary KnobText (VText def) (OneOf (VText first :| fmap VText rest)) []
textKnob knobName _ _ [] = error ("no values for " <> Text.unpack knobName)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
