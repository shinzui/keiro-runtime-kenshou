{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Catalog
  ( ScenarioInfo (..),
    CatalogDocument (..),
    fromScenario,
    fromBundles,
    readCatalogFile,
    decodeCatalog,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (LayerBundle, allScenarios, mkRegistry)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (ScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Scenario

data ScenarioInfo = ScenarioInfo
  { id :: ScenarioId,
    revision :: Int,
    summary :: Text,
    tier :: Tier,
    placement :: Placement,
    knobs :: [KnobSpec],
    dimensions :: DimensionSupport,
    knownDefect :: Maybe KnownDefect
  }
  deriving stock (Eq, Show)

newtype CatalogDocument = CatalogDocument {scenarios :: [ScenarioInfo]}
  deriving stock (Eq, Show)

fromScenario :: Scenario -> ScenarioInfo
fromScenario scenario =
  ScenarioInfo
    { id = scenario.id,
      revision = scenario.revision,
      summary = scenario.summary,
      tier = scenario.tier,
      placement = scenario.placement,
      knobs = scenario.knobs,
      dimensions = scenario.dimensions,
      knownDefect = scenario.knownDefect
    }

fromBundles :: [LayerBundle] -> [ScenarioInfo]
fromBundles bundles = case mkRegistry bundles of
  Left _ -> []
  Right registry -> fmap fromScenario (allScenarios registry)

readCatalogFile :: FilePath -> IO (Either Text [ScenarioInfo])
readCatalogFile path = decodeCatalog <$> ByteString.readFile path

decodeCatalog :: ByteString -> Either Text [ScenarioInfo]
decodeCatalog bytes = first Text.pack do
  document <- eitherDecodeStrict' bytes :: Either String CatalogDocument
  pure document.scenarios

instance FromJSON CatalogDocument where
  parseJSON = withObject "CatalogDocument" \value -> do
    schema <- value .:? "schema" .!= ("kenshou.scenario-list/v1" :: Text)
    if schema /= "kenshou.scenario-list/v1" then fail "unsupported catalog schema" else pure ()
    CatalogDocument <$> value .: "scenarios"

instance ToJSON CatalogDocument where
  toJSON document = object ["schema" .= ("kenshou.scenario-list/v1" :: Text), "scenarios" .= document.scenarios, "roles" .= ([] :: [Value])]

instance FromJSON ScenarioInfo where
  parseJSON = withObject "ScenarioInfo" \value ->
    ScenarioInfo
      <$> value .: "id"
      <*> value .:? "revision" .!= 1
      <*> value .:? "summary" .!= ""
      <*> (value .:? "tier" .!= "smoke" >>= parseTier)
      <*> (value .:? "placement" .!= "either" >>= parsePlacement)
      <*> value .:? "knobs" .!= []
      <*> value .:? "dimensions" .!= noDimensions
      <*> pure Nothing

instance ToJSON ScenarioInfo where
  toJSON scenario =
    object
      [ "id" .= scenario.id,
        "revision" .= scenario.revision,
        "summary" .= scenario.summary,
        "tier" .= renderTier scenario.tier,
        "placement" .= renderPlacement scenario.placement,
        "knobs" .= scenario.knobs,
        "dimensions" .= scenario.dimensions,
        "knownDefect" .= fmap (.reference) scenario.knownDefect
      ]

parseTier :: Text -> Parser Tier
parseTier = \case
  "smoke" -> pure TierSmoke
  "standard" -> pure TierStandard
  "extended" -> pure TierExtended
  "soak" -> pure TierSoak
  value -> fail ("unknown tier " <> Text.unpack value)

parsePlacement :: Text -> Parser Placement
parsePlacement = \case
  "local" -> pure PlaceLocal
  "cell" -> pure PlaceCell
  "either" -> pure PlaceEither
  value -> fail ("unknown placement " <> Text.unpack value)

instance ToJSON KnobSpec where
  toJSON spec =
    object
      [ "name" .= spec.name,
        "summary" .= spec.summary,
        "type" .= knobTypeText spec.knobType,
        "default" .= spec.def,
        "allowed" .= allowedValue spec.allowed,
        "variants" .= spec.variants
      ]

instance FromJSON KnobSpec where
  parseJSON = withObject "KnobSpec" \value -> do
    name <- value .: "name"
    summary <- value .:? "summary" .!= ""
    knobType <- value .: "type" >>= parseKnobType
    def <- value .: "default"
    allowed <- value .:? "allowed" >>= maybe (pure AnyValue) parseAllowed
    variants <- value .:? "variants" .!= []
    pure KnobSpec {name, summary, knobType, def, allowed, variants}

knobTypeText :: KnobType -> Text
knobTypeText KnobBool = "bool"
knobTypeText KnobInt = "int"
knobTypeText KnobDouble = "double"
knobTypeText KnobText = "text"

parseKnobType :: Text -> Parser KnobType
parseKnobType = \case
  "bool" -> pure KnobBool
  "int" -> pure KnobInt
  "double" -> pure KnobDouble
  "text" -> pure KnobText
  value -> fail ("unknown knob type " <> Text.unpack value)

allowedValue :: Allowed -> Value
allowedValue AnyValue = object ["kind" .= ("any" :: Text)]
allowedValue (OneOf values) = object ["kind" .= ("one-of" :: Text), "values" .= values]
allowedValue (IntRange low high) = object ["kind" .= ("int-range" :: Text), "min" .= low, "max" .= high]
allowedValue (DoubleRange low high) = object ["kind" .= ("double-range" :: Text), "min" .= low, "max" .= high]

parseAllowed :: Value -> Parser Allowed
parseAllowed = withObject "Allowed" \value ->
  value .: "kind" >>= \case
    ("any" :: Text) -> pure AnyValue
    "one-of" -> do
      values <- value .: "values"
      case values of [] -> fail "one-of must not be empty"; first : rest -> pure (OneOf (first :| rest))
    "int-range" -> IntRange <$> value .: "min" <*> value .: "max"
    "double-range" -> DoubleRange <$> value .: "min" <*> value .: "max"
    other -> fail ("unknown allowed kind " <> Text.unpack other)

instance ToJSON DimensionSupport where
  toJSON support =
    object
      [ "telemetry.tracing" .= supported renderTracing support.tracing,
        "telemetry.metrics" .= supported renderMetrics support.metrics,
        "pg.durability" .= supported renderDurability support.pgDurability,
        "pg.version" .= supported renderVersion support.pgVersion
      ]
    where
      supported _ NotApplicable = Null
      supported render (Supported value) = object ["values" .= fmap render value.values, "default" .= render value.def]

instance FromJSON DimensionSupport where
  parseJSON = withObject "DimensionSupport" \value ->
    DimensionSupport
      <$> parseSupported value "telemetry.tracing" parseTracing
      <*> parseSupported value "telemetry.metrics" parseMetrics
      <*> parseSupported value "pg.durability" parseDurability
      <*> parseSupported value "pg.version" parseVersion
    where
      parseSupported objectValue name parse = case KeyMap.lookup (Key.fromText name) objectValue of
        Nothing -> pure NotApplicable
        Just Null -> pure NotApplicable
        Just raw ->
          withObject
            "Support"
            ( \supportValue -> do
                rawValues <- supportValue .: "values"
                rawDefault <- supportValue .: "default"
                values <- traverse (maybe (fail ("unknown value in " <> Text.unpack name)) pure . parse) rawValues
                def <- maybe (fail ("unknown default in " <> Text.unpack name)) pure (parse rawDefault)
                case values of [] -> fail "dimension support must not be empty"; first : rest -> pure (Supported (Support (first :| rest) def))
            )
            raw
