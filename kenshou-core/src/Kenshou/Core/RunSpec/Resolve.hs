module Kenshou.Core.RunSpec.Resolve (SpecError (..), resolveRunSpec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry, lookupScenario)
import Kenshou.Core.Dimension (resolveDimensions)
import Kenshou.Core.Env (EnvRequirements (..))
import Kenshou.Core.Id (mkSeed, newRunId)
import Kenshou.Core.Knob (resolveKnobs)
import Kenshou.Core.RunSpec
import Kenshou.Core.Scenario (Placement (..), Scenario (..), Tier (..))
import System.Info qualified as System
import System.Random (randomIO)

newtype SpecError = SpecError Text deriving stock (Eq, Show)

resolveRunSpec :: Registry -> RunSpec -> IO (Either (NonEmpty SpecError) (Scenario, EffectiveRunSpec))
resolveRunSpec registry spec = case lookupScenario registry spec.scenario of
  Nothing -> pure (Left (SpecError ("unknown scenario " <> Text.pack (show spec.scenario)) :| []))
  Just scenario -> do
    generatedRunId <- maybe newRunId pure spec.runId
    randomSeed <- randomIO
    let seedResult = maybe (mkSeed (randomSeed `mod` 9007199254740992)) Right spec.seed
        knobsResult = resolveKnobs scenario.knobs spec.knobs
        dimensionsResult = resolveDimensions scenario.dimensions spec.dimensions
    pure do
      checkedSeed <- firstOne seedResult
      checkedKnobs <- mapErrors knobsResult
      checkedDimensions <- mapErrors dimensionsResult
      if maybe True (== scenario.revision) spec.scenarioRevision then pure () else Left (SpecError "scenario revision does not match registry" :| [])
      validatePlacement scenario.placement spec.environment.placement
      let environment = applyEnvironmentDefaults scenario spec.environment
          effective = EffectiveRunSpec generatedRunId scenario.id scenario.revision checkedKnobs checkedDimensions checkedSeed (maybe scenario.phases id spec.phases) (maybe (tierTimeout scenario.tier) id spec.timeoutSeconds) environment spec.cohortExpectation spec.comparison spec.labels
      pure (scenario, effective)
  where
    firstOne :: Either Text value -> Either (NonEmpty SpecError) value
    firstOne = either (Left . (:| []) . SpecError) Right
    mapErrors :: (Show problem) => Either (NonEmpty problem) value -> Either (NonEmpty SpecError) value
    mapErrors = either (Left . fmap (SpecError . Text.pack . show)) Right

validatePlacement :: Placement -> SpecPlacement -> Either (NonEmpty SpecError) ()
validatePlacement PlaceCell RunLocal = Left (SpecError "scenario requires cell placement" :| [])
validatePlacement PlaceLocal RunOnCell = Left (SpecError "scenario requires local placement" :| [])
validatePlacement _ _ = Right ()

applyEnvironmentDefaults :: Scenario -> EnvironmentSpec -> EnvironmentSpec
applyEnvironmentDefaults scenario environment =
  environment
    { machineProfile = Just (maybe ("local/" <> Text.pack System.os <> "-" <> Text.pack System.arch) id environment.machineProfile),
      postgres = case (scenario.requires.postgres, environment.postgres) of (Just _, Nothing) -> Just (PostgresEphemeral []); (_, existing) -> existing
    }

tierTimeout :: Tier -> Int
tierTimeout TierSmoke = 120
tierTimeout TierStandard = 1200
tierTimeout TierExtended = 7200
tierTimeout TierSoak = 86400
