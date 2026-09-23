module Kenshou.Suite.Kiroku.Soak.Common
  ( SoakProfile (..),
    SoakDefinition (..),
    soakPair,
    effectivePhases,
    soakLeakSpec,
    applyLeakVerdict,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario
import Kenshou.Diagnose.Leak (LeakSpec (..), LeakVerdict (..), defaultLeakSpec)
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, measureKnobs)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Telemetry.Spec (telemetryKnobs)

data SoakProfile = FullSoak | ReducedSoak deriving stock (Eq, Ord, Show)

data SoakDefinition = SoakDefinition
  { component :: !Text,
    name :: !Text,
    summary :: !Text,
    runSoak :: !(SoakProfile -> RunContext -> IO ScenarioReport)
  }

soakPair :: SoakDefinition -> [Scenario]
soakPair definition = [build FullSoak, build ReducedSoak]
  where
    build profile =
      Scenario
        { id = either (error . show) id (parseScenarioId ("kiroku/" <> definition.component <> "/soak/" <> definition.name <> suffix profile)),
          revision = 1,
          summary = definition.summary,
          tier = if profile == FullSoak then TierSoak else TierExtended,
          placement = if profile == FullSoak then PlaceCell else PlaceEither,
          knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {model = "open-constant", ratePerSecond = 200, executors = 32}) <> soakMeasureKnobs <> sharedKnobs profile <> [knob | definition.component == "subscription", knob <- telemetryKnobs],
          dimensions =
            DimensionSupport
              { tracing = Supported (Support (TracingOff :| [TracingSdkOtlp | definition.component == "subscription"]) TracingOff),
                metrics = Supported (Support (MetricsOff :| []) MetricsOff),
                pgDurability = Supported (Support (PgDurable :| []) PgDurable),
                pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
              },
          phases = defaultPhases profile,
          requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
          knownDefect = Nothing,
          run = definition.runSoak profile
        }
    suffix FullSoak = ""
    suffix ReducedSoak = "-reduced"

sharedKnobs :: SoakProfile -> [KnobSpec]
sharedKnobs profile =
  [ intKnob "soak.duration-minutes" (minutes profile) 1 480,
    intKnob "soak.kill-interval-minutes" 10 0 120,
    intKnob "soak.verify-interval-minutes" 30 1 120
  ]
  where
    name = either (error . show) id . mkKnobName
    intKnob :: Text -> Int -> Int -> Int -> KnobSpec
    intKnob key value low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral value)) (IntRange (fromIntegral low) (fromIntegral high)) []

minutes :: SoakProfile -> Int
minutes FullSoak = 240
minutes ReducedSoak = 30

soakMeasureKnobs :: [KnobSpec]
soakMeasureKnobs = fmap sampled (measureKnobs Soak)
  where
    rawName = either (error . show) id (mkKnobName "measure.raw-samples")
    sampled :: KnobSpec -> KnobSpec
    sampled spec | spec.name == rawName = KnobSpec spec.name spec.summary spec.knobType (VText "sampled") spec.allowed spec.variants
    sampled spec = spec

defaultPhases :: SoakProfile -> PhasePlan
defaultPhases profile = PhasePlan 60 (fromIntegral (minutes profile * 60)) 15

effectivePhases :: SoakProfile -> RunContext -> PhasePlan
effectivePhases profile context =
  let requested = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "soak.duration-minutes")) * 60)
      defaultSteady = fromIntegral (minutes profile * 60)
   in if context.phases.steadySeconds == defaultSteady then context.phases {steadySeconds = requested} else context.phases

soakLeakSpec :: SoakProfile -> LeakSpec
soakLeakSpec FullSoak = defaultLeakSpec
soakLeakSpec ReducedSoak = defaultLeakSpec {warmupCutSeconds = 60, minDurationSeconds = 900}

applyLeakVerdict :: LeakVerdict -> ScenarioReport -> ScenarioReport
applyLeakVerdict leak report = case leak of
  LeakSuspected -> report {outcome = Failed, reason = Just "resource leak suspected", failures = "leak-suspected" : report.failures}
  InsufficientData | report.outcome == Passed -> report {outcome = Inconclusive, reason = Just "leak verdict has insufficient data"}
  _ -> report
