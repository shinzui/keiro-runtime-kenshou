module Kenshou.Measure.Session
  ( MeasureEnv (..),
    measureEnvFromRunContext,
    phasePlanFromCore,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Word (Word64)
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Dimension (Dimensions (..), renderDurability)
import Kenshou.Core.Env.Postgres (PostgresEnv)
import Kenshou.Core.Id (Kind, ScenarioId (..), unSeed)
import Kenshou.Core.Knob (ResolvedKnobs)
import Kenshou.Core.Log qualified as Log
import Kenshou.Core.Phase qualified as Core
import Kenshou.Measure.Clock
import Kenshou.Measure.Phase
import System.FilePath (makeRelative)

data MeasureEnv = MeasureEnv
  { runDir :: FilePath,
    seed :: Word64,
    origin :: Origin,
    processLabel :: Maybe Text,
    scenarioKind :: Kind,
    pgDurability :: Maybe Text,
    specPhases :: Maybe PhasePlan,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    postgres :: Maybe PostgresEnv,
    onPhase :: Phase -> Origin -> IO (),
    registerSection :: Text -> Value -> IO (),
    declareArtifact :: FilePath -> Text -> IO (),
    logLine :: Text -> IO ()
  }

measureEnvFromRunContext :: Core.RunContext -> IO MeasureEnv
measureEnvFromRunContext context = do
  origin <- captureOrigin
  let ScenarioId _ _ scenarioKind _ = context.scenario
      Dimensions _ _ durability _ = context.dimensions
  pure
    MeasureEnv
      { runDir = context.outDir,
        seed = unSeed context.seed,
        origin,
        processLabel = Nothing,
        scenarioKind,
        pgDurability = renderDurability <$> durability,
        specPhases = Just (phasePlanFromCore context.phases),
        knobs = context.knobs,
        dimensions = context.dimensions,
        postgres = context.env.postgres,
        onPhase = \phase _ -> Log.logAt context.logger Log.Debug ("measurement phase " <> renderPhase phase) [],
        registerSection = Core.putSummary context Core.Measurements,
        declareArtifact = \path mediaType -> Core.declareMediaType context (makeRelative context.outDir path) mediaType,
        logLine = \message -> Log.logAt context.logger Log.Info message []
      }

phasePlanFromCore :: Core.PhasePlan -> PhasePlan
phasePlanFromCore plan =
  PhasePlan
    { warmUp = seconds plan.warmUpSeconds,
      steady = SteadyFor (seconds plan.steadySeconds),
      drain = seconds plan.drainSeconds
    }
  where
    seconds value = Nanos (floor (value * 1_000_000_000))
