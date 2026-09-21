module Kenshou.Measure.Metrics
  ( Metric (..),
  )
where

import Data.Aeson
import Data.Text (Text)

data Metric = Metric {value :: Double, unit :: Text}
  deriving stock (Eq, Show)

instance ToJSON Metric where
  toJSON metric = object ["value" .= metric.value, "unit" .= metric.unit]

instance FromJSON Metric where
  parseJSON = withObject "Metric" \value -> Metric <$> value .: "value" <*> value .: "unit"
