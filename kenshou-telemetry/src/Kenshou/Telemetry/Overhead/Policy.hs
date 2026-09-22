module Kenshou.Telemetry.Overhead.Policy
  ( OverheadPolicy (..),
    decodeOverheadPolicy,
    policyForTransition,
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kenshou.Measure.Compare.Policy (MetricRule (..), Policy (..))

data OverheadPolicy = OverheadPolicy
  { maxDegradedSpanFraction :: Double,
    defaultPolicy :: Policy,
    controlPolicy :: Policy,
    transitions :: Map Text Policy
  }
  deriving stock (Eq, Show)

instance FromJSON OverheadPolicy where
  parseJSON = withObject "OverheadPolicy" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.overhead-policy/v1" :: Text)
      then fail "unsupported overhead policy"
      else OverheadPolicy <$> value .: "maxDegradedSpanFraction" <*> value .: "default" <*> value .: "control" <*> value .:? "transitions" .!= Map.empty

instance ToJSON OverheadPolicy where
  toJSON value =
    object
      [ "schema" .= ("kenshou.overhead-policy/v1" :: Text),
        "maxDegradedSpanFraction" .= value.maxDegradedSpanFraction,
        "default" .= value.defaultPolicy,
        "control" .= value.controlPolicy,
        "transitions" .= value.transitions
      ]

decodeOverheadPolicy :: ByteString -> Either String OverheadPolicy
decodeOverheadPolicy = eitherDecodeStrict'

policyForTransition :: OverheadPolicy -> Maybe (Text, Text, Text) -> Policy
policyForTransition policy transition = case transition of
  Nothing -> policy.defaultPolicy
  Just (factor, fromValue, toValue) -> case Map.lookup (factor <> ":" <> fromValue <> "->" <> toValue) policy.transitions of
    Nothing -> policy.defaultPolicy
    Just selected ->
      let selectedMatches = fmap (.match) selected.metricRules
       in selected {metricRules = selected.metricRules <> filter ((`notElem` selectedMatches) . (.match)) policy.defaultPolicy.metricRules}
