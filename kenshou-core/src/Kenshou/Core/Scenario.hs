module Kenshou.Core.Scenario
  ( Tier (..),
    Placement (..),
    KnownDefect (..),
    CohortScope (..),
    PackageCondition (..),
    cohortScopeApplies,
    ScenarioReport (..),
    Scenario (..),
    renderTier,
    renderPlacement,
    passed,
    failedWith,
    inconclusiveBecause,
    infrastructureFailureBecause,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (parseVersion)
import Kenshou.Core.Cohort (CohortIdentity (..), PackageSource (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension (DimensionSupport)
import Kenshou.Core.Env (EnvRequirements)
import Kenshou.Core.Id (ScenarioId)
import Kenshou.Core.Knob (KnobSpec)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan)
import Text.ParserCombinators.ReadP (readP_to_S)

data Tier = TierSmoke | TierStandard | TierExtended | TierSoak deriving stock (Eq, Ord, Show)

data Placement = PlaceLocal | PlaceCell | PlaceEither deriving stock (Eq, Ord, Show)

data KnownDefect = KnownDefect
  { reference :: Text,
    summary :: Text,
    expectedFailures :: [Text],
    appliesTo :: CohortScope
  }
  deriving stock (Eq, Show)

data CohortScope = AllCohorts | OnlyWhen (NonEmpty PackageCondition) deriving stock (Eq, Show)

data PackageCondition
  = ResolvedFromHackage Text
  | ResolvedFromGit Text
  | VersionBelow Text Text
  | RevisionIs Text Text
  deriving stock (Eq, Show)

cohortScopeApplies :: CohortIdentity -> CohortScope -> Bool
cohortScopeApplies _ AllCohorts = True
cohortScopeApplies cohort (OnlyWhen conditions) = all (conditionApplies packages) conditions
  where
    packages = concatMap (.resolvedComponentPackages) cohort.identityComponents

conditionApplies :: [ResolvedPackage] -> PackageCondition -> Bool
conditionApplies packages condition = any matches packages
  where
    matches package = case condition of
      ResolvedFromHackage name -> package.resolvedPackageName == name && case package.resolvedPackageSource of FromHackage _ -> True; _ -> False
      ResolvedFromGit name -> package.resolvedPackageName == name && case package.resolvedPackageSource of FromGit _ _ _ -> True; _ -> False
      VersionBelow name boundary -> package.resolvedPackageName == name && maybe False (uncurry (<)) ((,) <$> parse package.resolvedPackageVersion <*> parse boundary)
      RevisionIs name revision -> package.resolvedPackageName == name && case package.resolvedPackageSource of FromGit _ actual _ -> actual == revision; _ -> False
    parse value = case [version | (version, "") <- readP_to_S parseVersion (Text.unpack value)] of [] -> Nothing; versions -> Just (last versions)

data ScenarioReport = ScenarioReport
  { outcome :: Outcome,
    reason :: Maybe Text,
    failures :: [Text]
  }
  deriving stock (Eq, Show)

data Scenario = Scenario
  { id :: ScenarioId,
    revision :: Int,
    summary :: Text,
    tier :: Tier,
    placement :: Placement,
    knobs :: [KnobSpec],
    dimensions :: DimensionSupport,
    phases :: PhasePlan,
    requires :: EnvRequirements,
    knownDefect :: Maybe KnownDefect,
    run :: RunContext -> IO ScenarioReport
  }

renderTier :: Tier -> Text
renderTier TierSmoke = "smoke"
renderTier TierStandard = "standard"
renderTier TierExtended = "extended"
renderTier TierSoak = "soak"

renderPlacement :: Placement -> Text
renderPlacement PlaceLocal = "local"
renderPlacement PlaceCell = "cell"
renderPlacement PlaceEither = "either"

passed :: ScenarioReport
passed = ScenarioReport Passed Nothing []

failedWith :: [Text] -> Text -> ScenarioReport
failedWith labels message = ScenarioReport Failed (Just message) labels

inconclusiveBecause :: Text -> ScenarioReport
inconclusiveBecause message = ScenarioReport Inconclusive (Just message) []

infrastructureFailureBecause :: Text -> ScenarioReport
infrastructureFailureBecause message = ScenarioReport InfrastructureFailure (Just message) []
