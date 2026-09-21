{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Suite
  ( SuiteMode (..),
    SuiteExclusion (..),
    SuiteSelection (..),
    PolicyPatch (..),
    Suite (..),
    readSuite,
    decodeSuite,
    suitePolicy,
    applySuite,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (Seed, parseKind)
import Kenshou.Core.RunSpec (SpecPlacement (..))
import Kenshou.Core.Scenario (Tier (..))
import Kenshou.Plan.Catalog (ScenarioInfo)
import Kenshou.Plan.Change
import Kenshou.Plan.Policy
import Kenshou.Plan.Policy qualified as Policy
import Kenshou.Plan.Selector

data SuiteMode = SuiteAll | SuiteChanged deriving stock (Eq, Show)

data SuiteExclusion = SuiteExclusion {select :: Selector, why :: Text}
  deriving stock (Eq, Show)

data SuiteSelection = SuiteSelection
  { mode :: SuiteMode,
    always :: [Selector],
    exclude :: [SuiteExclusion]
  }
  deriving stock (Eq, Show)

data PolicyPatch = PolicyPatch
  { maxTier :: Maybe Tier,
    kinds :: Maybe [Text],
    placement :: Maybe SpecPlacement,
    dimensionPolicy :: Maybe DimensionPolicy,
    knobPolicy :: Maybe KnobPolicy,
    trials :: Maybe Int,
    budgetMinutes :: Maybe Int
  }
  deriving stock (Eq, Show)

data Suite = Suite
  { name :: Text,
    description :: Text,
    selection :: SuiteSelection,
    policy :: PolicyPatch,
    directlyChanged :: Maybe PolicyPatch
  }
  deriving stock (Eq, Show)

readSuite :: FilePath -> IO (Either Text Suite)
readSuite path = decodeSuite <$> ByteString.readFile path

decodeSuite :: ByteString -> Either Text Suite
decodeSuite = first Text.pack . eitherDecodeStrict'

suitePolicy :: Seed -> Suite -> Either Text PlanPolicy
suitePolicy seed suite = applyPatch suite.policy (defaultPlanPolicy seed)

applySuite :: Suite -> [ScenarioInfo] -> [Selected] -> [Selected]
applySuite suite catalog changed = applyDirectlyChanged (applySelectors [] exclusions (base <> alwaysSelected))
  where
    base = case suite.selection.mode of SuiteAll -> selectAll catalog; SuiteChanged -> changed
    alwaysSelected = selectBySelectors Everything ("suite " <> suite.name <> " always") suite.selection.always catalog
    exclusions = fmap (.select) suite.selection.exclude
    applyDirectlyChanged = case suite.directlyChanged of
      Nothing -> id
      Just patch -> fmap (raiseDirect patch)
    raiseDirect patch selected
      | minimum (fmap (.distance) (NonEmpty.toList selected.reasons)) == 0 =
          selected
            { minPolicy = fmap (renderDimensionPolicy . max (maybe DefaultOnly parseMinimum selected.minPolicy)) patch.dimensionPolicy <|> selected.minPolicy,
              minKnobPolicy = fmap (renderKnobPolicy . max (maybe KnobDefaults parseMinimumKnob selected.minKnobPolicy)) patch.knobPolicy <|> selected.minKnobPolicy
            }
      | otherwise = selected
    parseMinimum value = maybe DefaultOnly (\parsed -> parsed) (parseDimensionPolicy value)
    parseMinimumKnob value = maybe KnobDefaults (\parsed -> parsed) (parseKnobPolicy value)

applyPatch :: PolicyPatch -> PlanPolicy -> Either Text PlanPolicy
applyPatch patch base = do
  kinds <- maybe (Right base.kinds) (fmap Set.fromList . traverse parseKind) patch.kinds
  pure
    base
      { Policy.maxTier = maybe base.maxTier (\value -> value) patch.maxTier,
        Policy.kinds = kinds,
        Policy.placement = maybe base.placement (\value -> value) patch.placement,
        Policy.dimensionPolicy = maybe base.dimensionPolicy (\value -> value) patch.dimensionPolicy,
        Policy.knobPolicy = maybe base.knobPolicy (\value -> value) patch.knobPolicy,
        Policy.trials = maybe base.trials (\value -> value) patch.trials,
        Policy.budgetMinutes = patch.budgetMinutes <|> base.budgetMinutes
      }

instance FromJSON Suite where
  parseJSON = withObject "Suite" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.suite/v1" :: Text) then fail "unsupported suite schema" else pure ()
    Suite <$> value .: "name" <*> value .: "description" <*> value .: "selection" <*> value .: "policy" <*> value .:? "directlyChanged"

instance FromJSON SuiteSelection where
  parseJSON = withObject "SuiteSelection" \value -> SuiteSelection <$> (value .: "mode" >>= parseMode) <*> (value .:? "always" .!= [] >>= traverse parseSelectorValue) <*> value .:? "exclude" .!= []
    where
      parseMode ("all" :: Text) = pure SuiteAll
      parseMode "changed" = pure SuiteChanged
      parseMode other = fail ("unknown suite mode " <> Text.unpack other)

instance FromJSON SuiteExclusion where
  parseJSON = withObject "SuiteExclusion" \value -> SuiteExclusion <$> (value .: "select" >>= parseSelectorValue) <*> value .: "why"

instance FromJSON PolicyPatch where
  parseJSON = withObject "PolicyPatch" \value ->
    PolicyPatch
      <$> (value .:? "maxTier" >>= traverse parseTier)
      <*> value .:? "kinds"
      <*> (value .:? "placement" >>= traverse parsePlacement)
      <*> (value .:? "dimensionPolicy" >>= traverse parseDimension)
      <*> (value .:? "knobPolicy" >>= traverse parseKnob)
      <*> value .:? "trials"
      <*> value .:? "budgetMinutes"
    where
      parseTier "smoke" = pure TierSmoke
      parseTier "standard" = pure TierStandard
      parseTier "extended" = pure TierExtended
      parseTier "soak" = pure TierSoak
      parseTier other = fail ("unknown tier " <> Text.unpack other)
      parsePlacement "local" = pure RunLocal
      parsePlacement "cell" = pure RunOnCell
      parsePlacement other = fail ("unknown placement " <> Text.unpack other)
      parseDimension raw = maybe (fail ("unknown dimension policy " <> Text.unpack raw)) pure (parseDimensionPolicy raw)
      parseKnob raw = maybe (fail ("unknown knob policy " <> Text.unpack raw)) pure (parseKnobPolicy raw)

parseSelectorValue :: Text -> Parser Selector
parseSelectorValue = either (fail . Text.unpack) pure . parseSelector
