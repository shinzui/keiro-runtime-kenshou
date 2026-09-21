module Kenshou.Core.RunSpec.Resolve (SpecError (..), resolveRunSpec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry, lookupScenario)
import Kenshou.Core.Dimension (resolveDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (mkSeed, newRunId)
import Kenshou.Core.Knob (resolveKnobs)
import Kenshou.Core.Phase (PhasePlan (..))
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
      validatePostgres scenario spec.environment.postgres
      validateExtraPostgres scenario spec.environment.extraPostgres
      let environment = applyEnvironmentDefaults scenario spec.environment
          phases = maybe scenario.phases id spec.phases
          effective = EffectiveRunSpec generatedRunId scenario.id scenario.revision checkedKnobs checkedDimensions checkedSeed phases (maybe (tierTimeout scenario.tier phases) id spec.timeoutSeconds) environment spec.cohortExpectation spec.comparison spec.labels
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

validatePostgres :: Scenario -> Maybe PostgresSpec -> Either (NonEmpty SpecError) ()
validatePostgres scenario postgresSpec = case (scenario.requires.postgres, postgresSpec) of
  (Nothing, Just _) -> Left (SpecError "PostgreSQL is not applicable to this scenario" :| [])
  (Just requirement, Just (PostgresExternal _)) | requirement.needsServerControl -> Left (SpecError "scenario requires control of an ephemeral PostgreSQL server" :| [])
  _ -> Right ()

validateExtraPostgres :: Scenario -> Map.Map Text PostgresSpec -> Either (NonEmpty SpecError) ()
validateExtraPostgres scenario supplied =
  case errors of
    [] -> Right ()
    first : rest -> Left (first :| rest)
  where
    required = Map.fromList scenario.requires.extraPostgres
    unknown = Map.keys (supplied `Map.difference` required)
    controlErrors =
      [ SpecError ("extra PostgreSQL " <> name <> " requires an ephemeral server")
      | (name, requirement) <- Map.toList required,
        requirement.needsServerControl,
        Just (PostgresExternal _) <- [Map.lookup name supplied]
      ]
    errors = fmap (SpecError . ("unknown extra PostgreSQL environment " <>)) unknown <> controlErrors

applyEnvironmentDefaults :: Scenario -> EnvironmentSpec -> EnvironmentSpec
applyEnvironmentDefaults scenario environment =
  environment
    { machineProfile = Just (maybe ("local/" <> Text.pack System.os <> "-" <> Text.pack System.arch) id environment.machineProfile),
      postgres = case (scenario.requires.postgres, environment.postgres) of (Just _, Nothing) -> Just (PostgresEphemeral []); (_, existing) -> existing,
      extraPostgres = Map.union environment.extraPostgres (Map.fromList [(name, PostgresEphemeral []) | (name, _) <- scenario.requires.extraPostgres])
    }

tierTimeout :: Tier -> PhasePlan -> Int
tierTimeout TierSmoke _ = 120
tierTimeout TierStandard _ = 1200
tierTimeout TierExtended _ = 7200
tierTimeout TierSoak phases = ceiling (phases.warmUpSeconds + phases.steadySeconds + phases.drainSeconds) + 1800
