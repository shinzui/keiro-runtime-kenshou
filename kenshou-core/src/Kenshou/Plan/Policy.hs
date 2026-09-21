module Kenshou.Plan.Policy
  ( DimensionPolicy (..),
    KnobPolicy (..),
    PlanPolicy (..),
    defaultPlanPolicy,
    mergePolicy,
    renderDimensionPolicy,
    parseDimensionPolicy,
    renderKnobPolicy,
    parseKnobPolicy,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Kenshou.Core.Id (Kind (..), Seed, renderKind)
import Kenshou.Core.RunSpec (SpecPlacement (..))
import Kenshou.Core.Scenario (Tier (..), renderTier)

data DimensionPolicy = DefaultOnly | TelemetryCorners | Pairwise | Full
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data KnobPolicy = KnobDefaults | KnobDeclaredVariants
  deriving stock (Eq, Ord, Show)

data PlanPolicy = PlanPolicy
  { maxTier :: Tier,
    kinds :: Set Kind,
    placement :: SpecPlacement,
    dimensionPolicy :: DimensionPolicy,
    knobPolicy :: KnobPolicy,
    trials :: Int,
    budgetMinutes :: Maybe Int,
    tierMinutes :: Map Tier Int,
    seed :: Seed,
    pinnedKnobs :: [(Text, Text)],
    pinnedDimensions :: [(Text, Text)]
  }
  deriving stock (Eq, Show)

defaultPlanPolicy :: Seed -> PlanPolicy
defaultPlanPolicy seed =
  PlanPolicy
    { maxTier = TierStandard,
      kinds = Set.fromList [Correctness, Concurrency, Benchmark, Soak],
      placement = RunLocal,
      dimensionPolicy = DefaultOnly,
      knobPolicy = KnobDefaults,
      trials = 3,
      budgetMinutes = Nothing,
      tierMinutes = Map.fromList [(TierSmoke, 1), (TierStandard, 10), (TierExtended, 60), (TierSoak, 240)],
      seed,
      pinnedKnobs = [],
      pinnedDimensions = []
    }

-- | Policies are concrete after parsing. A later policy therefore wins, while
-- pins are accumulated so suite defaults can be refined on the command line.
mergePolicy :: PlanPolicy -> PlanPolicy -> PlanPolicy
mergePolicy _base override = override

renderDimensionPolicy :: DimensionPolicy -> Text
renderDimensionPolicy DefaultOnly = "default-only"
renderDimensionPolicy TelemetryCorners = "telemetry-corners"
renderDimensionPolicy Pairwise = "pairwise"
renderDimensionPolicy Full = "full"

parseDimensionPolicy :: Text -> Maybe DimensionPolicy
parseDimensionPolicy value = lookup value [(renderDimensionPolicy policy, policy) | policy <- [minBound .. maxBound]]

renderKnobPolicy :: KnobPolicy -> Text
renderKnobPolicy KnobDefaults = "defaults"
renderKnobPolicy KnobDeclaredVariants = "declared-variants"

parseKnobPolicy :: Text -> Maybe KnobPolicy
parseKnobPolicy "defaults" = Just KnobDefaults
parseKnobPolicy "declared-variants" = Just KnobDeclaredVariants
parseKnobPolicy _ = Nothing

instance ToJSON PlanPolicy where
  toJSON policy =
    object
      [ "maxTier" .= renderTier policy.maxTier,
        "kinds" .= fmap renderKind (Set.toAscList policy.kinds),
        "placement" .= policy.placement,
        "dimensionPolicy" .= renderDimensionPolicy policy.dimensionPolicy,
        "knobPolicy" .= renderKnobPolicy policy.knobPolicy,
        "trials" .= policy.trials,
        "trialOrdering" .= ("alternating/v1" :: Text),
        "budgetMinutes" .= policy.budgetMinutes,
        "tierMinutes" .= object [Key.fromText (renderTier tier) .= minutes | (tier, minutes) <- Map.toAscList policy.tierMinutes],
        "seed" .= policy.seed,
        "set" .= policy.pinnedKnobs,
        "dimensions" .= policy.pinnedDimensions
      ]
