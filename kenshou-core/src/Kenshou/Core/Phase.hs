module Kenshou.Core.Phase
  ( PhaseName (..),
    PhasePlan (..),
    zeroPhases,
    renderPhaseName,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)

data PhaseName = WarmUp | Steady | Drain
  deriving stock (Eq, Ord, Show)

data PhasePlan = PhasePlan
  { warmUpSeconds :: Double,
    steadySeconds :: Double,
    drainSeconds :: Double
  }
  deriving stock (Eq, Show)

zeroPhases :: PhasePlan
zeroPhases = PhasePlan 0 0 0

renderPhaseName :: PhaseName -> Text
renderPhaseName WarmUp = "warm-up"
renderPhaseName Steady = "steady"
renderPhaseName Drain = "drain"

instance ToJSON PhasePlan where
  toJSON value = object ["warmUpSeconds" .= value.warmUpSeconds, "steadySeconds" .= value.steadySeconds, "drainSeconds" .= value.drainSeconds]

instance FromJSON PhasePlan where
  parseJSON = withObject "PhasePlan" \value -> PhasePlan <$> value .: "warmUpSeconds" <*> value .: "steadySeconds" <*> value .: "drainSeconds"
