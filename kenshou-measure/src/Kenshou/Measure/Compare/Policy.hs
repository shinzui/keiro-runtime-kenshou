module Kenshou.Measure.Compare.Policy
  ( Direction (..),
    MetricRule (..),
    Policy (..),
    decodePolicy,
    matchesRule,
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

data Direction = HigherIsBetter | LowerIsBetter deriving stock (Eq, Show)

data MetricRule = MetricRule {match :: Text, direction :: Direction, relativeLimit :: Double, absoluteFloor :: Double}
  deriving stock (Eq, Show)

data Policy = Policy
  { name :: Text,
    minimumPairs :: Int,
    confidenceLevel :: Double,
    bootstrapIterations :: Int,
    resamplingSeed :: Word64,
    requireInterleaving :: Bool,
    requireGrade :: Text,
    maxCiRelativeWidth :: Double,
    maxCheckpointAsymmetry :: Double,
    metricRules :: [MetricRule]
  }
  deriving stock (Eq, Show)

instance FromJSON Direction where
  parseJSON = withText "Direction" \value -> case value of
    "higher-is-better" -> pure HigherIsBetter
    "lower-is-better" -> pure LowerIsBetter
    _ -> fail "direction must be higher-is-better or lower-is-better"

instance ToJSON Direction where
  toJSON HigherIsBetter = String "higher-is-better"
  toJSON LowerIsBetter = String "lower-is-better"

instance FromJSON MetricRule where
  parseJSON = withObject "MetricRule" \value -> MetricRule <$> value .: "match" <*> value .: "direction" <*> value .: "relativeLimit" <*> value .: "absoluteFloor"

instance ToJSON MetricRule where
  toJSON rule = object ["match" .= rule.match, "direction" .= rule.direction, "relativeLimit" .= rule.relativeLimit, "absoluteFloor" .= rule.absoluteFloor]

instance FromJSON Policy where
  parseJSON = withObject "Policy" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.comparison-policy/v1" :: Text) then fail "unsupported comparison policy" else pure ()
    decodedPolicy <- Policy <$> value .: "name" <*> value .: "minimumPairs" <*> value .: "confidenceLevel" <*> value .: "bootstrapIterations" <*> value .: "resamplingSeed" <*> value .: "requireInterleaving" <*> value .: "requireGrade" <*> value .: "maxCiRelativeWidth" <*> value .: "maxCheckpointAsymmetry" <*> value .: "metrics"
    if decodedPolicy.minimumPairs < 3 then fail "minimumPairs must be at least 3" else pure ()
    if decodedPolicy.bootstrapIterations < 1_000 then fail "bootstrapIterations must be at least 1000" else pure decodedPolicy

instance ToJSON Policy where
  toJSON policy =
    object
      [ "schema" .= ("kenshou.comparison-policy/v1" :: Text),
        "name" .= policy.name,
        "minimumPairs" .= policy.minimumPairs,
        "confidenceLevel" .= policy.confidenceLevel,
        "bootstrapIterations" .= policy.bootstrapIterations,
        "resamplingSeed" .= policy.resamplingSeed,
        "requireInterleaving" .= policy.requireInterleaving,
        "requireGrade" .= policy.requireGrade,
        "maxCiRelativeWidth" .= policy.maxCiRelativeWidth,
        "maxCheckpointAsymmetry" .= policy.maxCheckpointAsymmetry,
        "metrics" .= policy.metricRules
      ]

decodePolicy :: ByteString -> Either Text Policy
decodePolicy = either (Left . Text.pack) Right . eitherDecodeStrict'

matchesRule :: Text -> Text -> Bool
matchesRule patternValue metricName = case Text.breakOn "*" patternValue of
  (_, suffixWithStar) | Text.null suffixWithStar -> patternValue == metricName
  (prefix, suffixWithStar) -> prefix `Text.isPrefixOf` metricName && Text.drop 1 suffixWithStar `Text.isSuffixOf` metricName
