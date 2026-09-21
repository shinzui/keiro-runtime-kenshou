module Kenshou.Core.Scenario
  ( Tier (..),
    Placement (..),
    KnownDefect (..),
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

import Data.Text (Text)
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension (DimensionSupport)
import Kenshou.Core.Env (EnvRequirements)
import Kenshou.Core.Id (ScenarioId)
import Kenshou.Core.Knob (KnobSpec)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan)

data Tier = TierSmoke | TierStandard | TierExtended | TierSoak deriving stock (Eq, Ord, Show)

data Placement = PlaceLocal | PlaceCell | PlaceEither deriving stock (Eq, Ord, Show)

data KnownDefect = KnownDefect
  { reference :: Text,
    summary :: Text,
    expectedFailures :: [Text]
  }
  deriving stock (Eq, Show)

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
