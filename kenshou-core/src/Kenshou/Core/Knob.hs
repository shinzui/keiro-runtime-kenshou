module Kenshou.Core.Knob
  ( KnobName,
    KnobType (..),
    KnobValue (..),
    Allowed (..),
    KnobSpec (..),
    ResolvedKnobs,
    mkKnobName,
    renderKnobName,
    emptyKnobs,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), withText)
import Data.Char (isAsciiLower, isDigit)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

newtype KnobName = KnobName Text
  deriving stock (Eq, Ord, Show)

data KnobType = KnobBool | KnobInt | KnobDouble | KnobText
  deriving stock (Eq, Ord, Show)

data KnobValue = VBool Bool | VInt Int64 | VDouble Double | VText Text
  deriving stock (Eq, Show)

data Allowed = AnyValue | OneOf (NonEmpty KnobValue) | IntRange Int64 Int64 | DoubleRange Double Double
  deriving stock (Eq, Show)

data KnobSpec = KnobSpec
  { name :: KnobName,
    summary :: Text,
    knobType :: KnobType,
    def :: KnobValue,
    allowed :: Allowed,
    variants :: [KnobValue]
  }
  deriving stock (Eq, Show)

newtype ResolvedKnobs = ResolvedKnobs (Map KnobName KnobValue)
  deriving stock (Eq, Show)

mkKnobName :: Text -> Either Text KnobName
mkKnobName value
  | length pieces < 2 = Left "knob name must contain a dot"
  | all validSegment pieces = Right (KnobName value)
  | otherwise = Left ("invalid knob name \"" <> value <> "\"")
  where
    pieces = Text.splitOn "." value
    validSegment piece =
      not (Text.null piece)
        && isAsciiLower (Text.head piece)
        && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') piece

renderKnobName :: KnobName -> Text
renderKnobName (KnobName value) = value

emptyKnobs :: ResolvedKnobs
emptyKnobs = ResolvedKnobs Map.empty

instance ToJSON KnobName where toJSON = toJSON . renderKnobName

instance FromJSON KnobName where parseJSON = withText "KnobName" (either (fail . Text.unpack) pure . mkKnobName)

instance ToJSON KnobValue where
  toJSON (VBool value) = Bool value
  toJSON (VInt value) = toJSON value
  toJSON (VDouble value) = toJSON value
  toJSON (VText value) = String value
