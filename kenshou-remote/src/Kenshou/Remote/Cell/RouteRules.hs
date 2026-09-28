module Kenshou.Remote.Cell.RouteRules
  ( CellCapabilities (..),
    RuleCondition (..),
    RoutingRule (..),
    matchingRules,
    capabilityKnown,
    descriptorDigest,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), encode, object, withObject, (.:), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (RunId)
import Kenshou.Core.Knob (RawKnob (..), mkKnobName)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Plan.Selector (Selector, matches, parseSelector)
import Kenshou.Remote.Cell.Docs (CellDescriptor)

data CellCapabilities = CellCapabilities
  { cell :: !Text,
    descriptorSha256 :: !Text,
    probedBy :: !RunId,
    probedAt :: !UTCTime,
    capabilities :: !(Map Text Value)
  }
  deriving stock (Eq, Show)

data RuleCondition = KnobEquals Text Text | ScenarioMatches Selector
  deriving stock (Eq, Show)

data RoutingRule = RoutingRule
  { condition :: !RuleCondition,
    requires :: !Text,
    why :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON CellCapabilities where
  parseJSON = withObject "cell capabilities" \fields -> do
    schema <- fields .: "schema"
    if schema == ("kenshou.cell-capabilities/v1" :: Text) then pure () else fail "unsupported cell capabilities schema"
    document <- CellCapabilities <$> fields .: "cell" <*> fields .: "descriptorSha256" <*> fields .: "probedBy" <*> fields .: "probedAt" <*> fields .: "capabilities"
    if Text.null document.cell || Text.length document.descriptorSha256 /= 64 || not (Text.all (`elem` (['0' .. '9'] <> ['a' .. 'f'])) document.descriptorSha256)
      then fail "invalid cell capabilities identity"
      else pure document

instance ToJSON CellCapabilities where
  toJSON cache =
    object
      [ "schema" .= ("kenshou.cell-capabilities/v1" :: Text),
        "cell" .= cache.cell,
        "descriptorSha256" .= cache.descriptorSha256,
        "probedBy" .= cache.probedBy,
        "probedAt" .= cache.probedAt,
        "capabilities" .= cache.capabilities
      ]

instance FromJSON RoutingRule where
  parseJSON = withObject "cell routing rule" \fields -> do
    condition <- fields .: "when" >>= parseCondition
    capability <- fields .: "requires"
    explanation <- fields .: "why"
    if Text.null capability || Text.null explanation then fail "cell routing rule requires a capability and explanation" else pure ()
    pure (RoutingRule condition capability explanation)
    where
      parseCondition = withObject "cell routing condition" \fields ->
        case (KeyMap.lookup "knob" fields, KeyMap.lookup "scenario" fields) of
          (Just (String knob), Nothing) -> do
            _ <- either (fail . Text.unpack) pure (mkKnobName knob)
            KnobEquals knob <$> fields .: "equals"
          (Nothing, Just (String patternText)) -> ScenarioMatches <$> either (fail . Text.unpack) pure (parseSelector patternText)
          _ -> fail "cell routing condition must select one knob or scenario"

matchingRules :: [RoutingRule] -> RunSpec -> [RoutingRule]
matchingRules rules spec = filter (matchesRule spec) rules
  where
    matchesRule run rule = case rule.condition of
      ScenarioMatches selector -> matches selector run.scenario
      KnobEquals name expected -> case mkKnobName name of
        Left _ -> False
        Right key -> case lookup key run.knobs of
          Just (RawText actual) -> actual == expected
          Just (RawJson (String actual)) -> actual == expected
          _ -> False

capabilityKnown :: CellCapabilities -> Text -> Maybe Bool
capabilityKnown cache name = case Map.lookup name cache.capabilities of
  Just (Bool available) -> Just available
  _ -> Nothing

-- The cache uses the canonical codec form, so object member order in the
-- downloaded descriptor cannot invalidate an otherwise identical cell shape.
descriptorDigest :: CellDescriptor -> Text
descriptorDigest = Text.drop 7 . sha256Hex . LazyByteString.toStrict . encode
