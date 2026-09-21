module Kenshou.Core.Dimension
  ( TracingArm (..),
    MetricsArm (..),
    PgDurability (..),
    PgVersion (..),
    DimensionName (..),
    Support (..),
    Supported (..),
    DimensionSupport (..),
    Dimensions (..),
    noDimensions,
    emptyDimensions,
    allTelemetryArms,
    postgresDimensions,
    resolveDimensions,
    renderDimensions,
    renderDimensionName,
    renderTracing,
    parseTracing,
    renderMetrics,
    parseMetrics,
    renderDurability,
    parseDurability,
    renderVersion,
    parseVersion,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.List (group, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

data TracingArm = TracingOff | TracingNoop | TracingSdkInMemory | TracingSdkOtlp deriving stock (Eq, Ord, Show)

data MetricsArm = MetricsOff | MetricsCollect | MetricsServe | MetricsServeScraped deriving stock (Eq, Ord, Show)

data PgDurability = PgFsyncOff | PgDurable deriving stock (Eq, Ord, Show)

data PgVersion = Pg17 | Pg18 deriving stock (Eq, Ord, Show)

data DimensionName = DimTracing | DimMetrics | DimPgDurability | DimPgVersion deriving stock (Eq, Ord, Show)

data Support a = Support {values :: NonEmpty a, def :: a} deriving stock (Eq, Show)

data Supported a = NotApplicable | Supported (Support a) deriving stock (Eq, Show)

data DimensionSupport = DimensionSupport
  { tracing :: Supported TracingArm,
    metrics :: Supported MetricsArm,
    pgDurability :: Supported PgDurability,
    pgVersion :: Supported PgVersion
  }
  deriving stock (Eq, Show)

data Dimensions = Dimensions
  { tracing :: Maybe TracingArm,
    metrics :: Maybe MetricsArm,
    pgDurability :: Maybe PgDurability,
    pgVersion :: Maybe PgVersion
  }
  deriving stock (Eq, Show)

noDimensions :: DimensionSupport
noDimensions = DimensionSupport NotApplicable NotApplicable NotApplicable NotApplicable

emptyDimensions :: Dimensions
emptyDimensions = Dimensions Nothing Nothing Nothing Nothing

allTelemetryArms :: DimensionSupport -> DimensionSupport
allTelemetryArms support = support {tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff), metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff)}

postgresDimensions :: NonEmpty PgDurability -> NonEmpty PgVersion -> DimensionSupport -> DimensionSupport
postgresDimensions durabilities versions support = support {pgDurability = Supported (Support durabilities (NonEmpty.head durabilities)), pgVersion = Supported (Support versions (NonEmpty.head versions))}

resolveDimensions :: DimensionSupport -> [(Text, Text)] -> Either (NonEmpty Text) Dimensions
resolveDimensions support assignments = case errors of
  [] -> Right (Dimensions tracing metrics durability version)
  first : rest -> Left (first :| rest)
  where
    names = fmap fst assignments
    duplicateErrors = [name <> ": assigned more than once" | values@(name : _) <- group (sort names), length values > 1]
    unknownErrors = [name <> ": unknown dimension" | name <- names, name `notElem` fmap renderDimensionName [DimTracing, DimMetrics, DimPgDurability, DimPgVersion]]
    lookupValue name = lookup (renderDimensionName name) assignments
    (tracing, tracingErrors) = resolveOne DimTracing renderTracing parseTracing support.tracing (lookupValue DimTracing)
    (metrics, metricsErrors) = resolveOne DimMetrics renderMetrics parseMetrics support.metrics (lookupValue DimMetrics)
    (durability, durabilityErrors) = resolveOne DimPgDurability renderDurability parseDurability support.pgDurability (lookupValue DimPgDurability)
    (version, versionErrors) = resolveOne DimPgVersion renderVersion parseVersion support.pgVersion (lookupValue DimPgVersion)
    errors = duplicateErrors <> unknownErrors <> tracingErrors <> metricsErrors <> durabilityErrors <> versionErrors

resolveOne :: (Eq a) => DimensionName -> (a -> Text) -> (Text -> Maybe a) -> Supported a -> Maybe Text -> (Maybe a, [Text])
resolveOne _ _ _ NotApplicable Nothing = (Nothing, [])
resolveOne name _ _ NotApplicable (Just _) = (Nothing, [renderDimensionName name <> ": not applicable to this scenario"])
resolveOne _ _ _ (Supported support) Nothing = (Just support.def, [])
resolveOne name _render parse (Supported support) (Just raw) = case parse raw of
  Nothing -> (Nothing, [renderDimensionName name <> ": unknown value \"" <> raw <> "\""])
  Just value | value `elem` support.values -> (Just value, [])
  Just _ -> (Nothing, [renderDimensionName name <> ": value \"" <> raw <> "\" is not supported"])

renderDimensions :: Dimensions -> [(Text, Text)]
renderDimensions dimensions =
  concat
    [ maybe [] (pure . (renderDimensionName DimTracing,) . renderTracing) dimensions.tracing,
      maybe [] (pure . (renderDimensionName DimMetrics,) . renderMetrics) dimensions.metrics,
      maybe [] (pure . (renderDimensionName DimPgDurability,) . renderDurability) dimensions.pgDurability,
      maybe [] (pure . (renderDimensionName DimPgVersion,) . renderVersion) dimensions.pgVersion
    ]

renderDimensionName :: DimensionName -> Text
renderDimensionName DimTracing = "telemetry.tracing"
renderDimensionName DimMetrics = "telemetry.metrics"
renderDimensionName DimPgDurability = "pg.durability"
renderDimensionName DimPgVersion = "pg.version"

renderTracing :: TracingArm -> Text
renderTracing TracingOff = "off"
renderTracing TracingNoop = "noop"
renderTracing TracingSdkInMemory = "sdk-inmemory"
renderTracing TracingSdkOtlp = "sdk-otlp"

parseTracing :: Text -> Maybe TracingArm
parseTracing value = lookup value [(renderTracing item, item) | item <- [TracingOff, TracingNoop, TracingSdkInMemory, TracingSdkOtlp]]

renderMetrics :: MetricsArm -> Text
renderMetrics MetricsOff = "off"
renderMetrics MetricsCollect = "collect"
renderMetrics MetricsServe = "serve"
renderMetrics MetricsServeScraped = "serve-scraped"

parseMetrics :: Text -> Maybe MetricsArm
parseMetrics value = lookup value [(renderMetrics item, item) | item <- [MetricsOff, MetricsCollect, MetricsServe, MetricsServeScraped]]

renderDurability :: PgDurability -> Text
renderDurability PgFsyncOff = "fsync-off"
renderDurability PgDurable = "durable"

parseDurability :: Text -> Maybe PgDurability
parseDurability value = lookup value [(renderDurability item, item) | item <- [PgFsyncOff, PgDurable]]

renderVersion :: PgVersion -> Text
renderVersion Pg17 = "17"
renderVersion Pg18 = "18"

parseVersion :: Text -> Maybe PgVersion
parseVersion value = lookup value [(renderVersion item, item) | item <- [Pg17, Pg18]]

instance ToJSON Dimensions where
  toJSON dimensions = object [Key.fromText name .= value | (name, value) <- renderDimensions dimensions]

instance FromJSON Dimensions where
  parseJSON = withObject "Dimensions" \value ->
    Dimensions
      <$> optionalArm value "telemetry.tracing" parseTracing
      <*> optionalArm value "telemetry.metrics" parseMetrics
      <*> optionalArm value "pg.durability" parseDurability
      <*> optionalArm value "pg.version" parseVersion
    where
      optionalArm objectValue name parse = do
        raw <- objectValue .:? Key.fromText name
        traverse (maybe (fail ("unknown dimension value for " <> Text.unpack name)) pure . parse) raw
