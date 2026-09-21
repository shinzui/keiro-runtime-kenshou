module Kenshou.Core.Knob
  ( KnobName,
    KnobType (..),
    KnobValue (..),
    Allowed (..),
    KnobSpec (..),
    RawKnob (..),
    ResolvedKnobs,
    KnobError (..),
    mkKnobName,
    renderKnobName,
    emptyKnobs,
    parseAssignment,
    resolveKnobs,
    resolvedKnobsMap,
    knobBool,
    knobInt,
    knobDouble,
    knobText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), withText)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAsciiLower, isDigit)
import Data.Int (Int64)
import Data.List (group, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific qualified as Scientific
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

data RawKnob = RawText Text | RawJson Value deriving stock (Eq, Show)

newtype KnobError = KnobError Text deriving stock (Eq, Show)

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

parseAssignment :: Text -> Either KnobError (KnobName, RawKnob)
parseAssignment input = case Text.breakOn "=" input of
  (name, assignment)
    | Text.null assignment -> Left (KnobError "expected NAME=VALUE")
    | otherwise -> case mkKnobName name of
        Left err -> Left (KnobError err)
        Right parsed -> Right (parsed, RawText (Text.drop 1 assignment))

resolveKnobs :: [KnobSpec] -> [(KnobName, RawKnob)] -> Either (NonEmpty KnobError) ResolvedKnobs
resolveKnobs specs supplied = case errors of
  [] -> Right (ResolvedKnobs values)
  first : rest -> Left (first :| rest)
  where
    declarations = Map.fromList [(spec.name, spec) | spec <- specs]
    duplicateNames = [head names | names <- group (sort (fmap fst supplied)), length names > 1]
    unknown = [name | (name, _) <- supplied, Map.notMember name declarations]
    parsed = [(name, resolveOne spec raw) | (name, raw) <- supplied, Just spec <- [Map.lookup name declarations]]
    parseErrors = [KnobError (renderKnobName name <> ": " <> message) | (name, Left message) <- parsed]
    overrides = Map.fromList [(name, value) | (name, Right value) <- parsed]
    values = Map.fromList [(spec.name, Map.findWithDefault spec.def spec.name overrides) | spec <- specs]
    errors =
      [KnobError (renderKnobName name <> ": assigned more than once") | name <- duplicateNames]
        <> [KnobError (renderKnobName name <> ": unknown knob") | name <- unknown]
        <> parseErrors

resolveOne :: KnobSpec -> RawKnob -> Either Text KnobValue
resolveOne spec raw = do
  parsed <- parseByType spec.knobType raw
  if allowedValue spec.allowed parsed then Right parsed else Left "value is outside the allowed set"

parseByType :: KnobType -> RawKnob -> Either Text KnobValue
parseByType KnobBool (RawText "true") = Right (VBool True)
parseByType KnobBool (RawText "false") = Right (VBool False)
parseByType KnobBool (RawJson (Bool value)) = Right (VBool value)
parseByType KnobInt (RawText value) = maybe (Left "expected an integer") (Right . VInt) (readMaybeText value)
parseByType KnobInt (RawJson (Number value)) = maybe (Left "expected an integer") (Right . VInt) (Scientific.toBoundedInteger value)
parseByType KnobDouble (RawText value) = maybe (Left "expected a number") (Right . VDouble) (readMaybeText value)
parseByType KnobDouble (RawJson (Number value)) = Right (VDouble (Scientific.toRealFloat value))
parseByType KnobText (RawText value) = Right (VText value)
parseByType KnobText (RawJson (String value)) = Right (VText value)
parseByType _ _ = Left "value has the wrong JSON type"

readMaybeText :: (Read value) => Text -> Maybe value
readMaybeText value = case reads (Text.unpack value) of [(parsed, "")] -> Just parsed; _ -> Nothing

allowedValue :: Allowed -> KnobValue -> Bool
allowedValue AnyValue _ = True
allowedValue (OneOf values) value = value `elem` values
allowedValue (IntRange low high) (VInt value) = value >= low && value <= high
allowedValue (DoubleRange low high) (VDouble value) = value >= low && value <= high
allowedValue _ _ = False

resolvedKnobsMap :: ResolvedKnobs -> Map KnobName KnobValue
resolvedKnobsMap (ResolvedKnobs values) = values

knobBool :: ResolvedKnobs -> KnobName -> Bool
knobBool knobs name = case Map.lookup name (resolvedKnobsMap knobs) of Just (VBool value) -> value; _ -> error "knobBool: missing or wrong type"

knobInt :: ResolvedKnobs -> KnobName -> Int64
knobInt knobs name = case Map.lookup name (resolvedKnobsMap knobs) of Just (VInt value) -> value; _ -> error "knobInt: missing or wrong type"

knobDouble :: ResolvedKnobs -> KnobName -> Double
knobDouble knobs name = case Map.lookup name (resolvedKnobsMap knobs) of Just (VDouble value) -> value; _ -> error "knobDouble: missing or wrong type"

knobText :: ResolvedKnobs -> KnobName -> Text
knobText knobs name = case Map.lookup name (resolvedKnobsMap knobs) of Just (VText value) -> value; _ -> error "knobText: missing or wrong type"

instance ToJSON KnobName where toJSON = toJSON . renderKnobName

instance FromJSON KnobName where parseJSON = withText "KnobName" (either (fail . Text.unpack) pure . mkKnobName)

instance ToJSON KnobValue where
  toJSON (VBool value) = Bool value
  toJSON (VInt value) = toJSON value
  toJSON (VDouble value) = toJSON value
  toJSON (VText value) = String value

instance ToJSON ResolvedKnobs where
  toJSON (ResolvedKnobs values) = Object (KeyMap.fromList [(Key.fromText (renderKnobName name), toJSON value) | (name, value) <- Map.toAscList values])
