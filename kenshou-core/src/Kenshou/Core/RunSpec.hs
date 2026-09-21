module Kenshou.Core.RunSpec
  ( SpecPlacement (..),
    ConnectionSource (..),
    PostgresSpec (..),
    EnvironmentSpec (..),
    CohortExpectation (..),
    ComparisonMembership (..),
    RunSpec (..),
    EffectiveRunSpec (..),
    minimalRunSpec,
    redactConnectionString,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Dimension (Dimensions, renderDimensions)
import Kenshou.Core.Id (RunId, ScenarioId, Seed)
import Kenshou.Core.Knob (KnobName, RawKnob (..), ResolvedKnobs)
import Kenshou.Core.Knob qualified
import Kenshou.Core.Phase (PhasePlan)

data SpecPlacement = RunLocal | RunOnCell deriving stock (Eq, Show)

data ConnectionSource = ConnLiteral Text | ConnFromEnv Text deriving stock (Eq, Show)

data PostgresSpec = PostgresEphemeral [(Text, Text)] | PostgresExternal ConnectionSource deriving stock (Eq, Show)

data EnvironmentSpec = EnvironmentSpec
  { placement :: SpecPlacement,
    machineProfile :: Maybe Text,
    postgres :: Maybe PostgresSpec,
    extraPostgres :: Map Text PostgresSpec,
    kafka :: Maybe Value,
    telemetry :: Maybe Value
  }
  deriving stock (Eq, Show)

data CohortExpectation = CohortExpectation {name :: Maybe Text, planHash :: Text} deriving stock (Eq, Show)

data ComparisonMembership = ComparisonMembership {group :: Text, arm :: Text, trial :: Int, position :: Int} deriving stock (Eq, Show)

data RunSpec = RunSpec
  { runId :: Maybe RunId,
    scenario :: ScenarioId,
    scenarioRevision :: Maybe Int,
    knobs :: [(KnobName, RawKnob)],
    dimensions :: [(Text, Text)],
    seed :: Maybe Seed,
    phases :: Maybe PhasePlan,
    timeoutSeconds :: Maybe Int,
    environment :: EnvironmentSpec,
    cohortExpectation :: Maybe CohortExpectation,
    comparison :: Maybe ComparisonMembership,
    labels :: Map Text Text
  }
  deriving stock (Eq, Show)

data EffectiveRunSpec = EffectiveRunSpec
  { runId :: RunId,
    scenario :: ScenarioId,
    scenarioRevision :: Int,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    seed :: Seed,
    phases :: PhasePlan,
    timeoutSeconds :: Int,
    environment :: EnvironmentSpec,
    cohortExpectation :: Maybe CohortExpectation,
    comparison :: Maybe ComparisonMembership,
    labels :: Map Text Text
  }
  deriving stock (Eq, Show)

minimalRunSpec :: ScenarioId -> RunSpec
minimalRunSpec scenario = RunSpec Nothing scenario Nothing [] [] Nothing Nothing Nothing (EnvironmentSpec RunLocal Nothing Nothing Map.empty Nothing Nothing) Nothing Nothing Map.empty

redactConnectionString :: Text -> Text
redactConnectionString value = redactUri (Text.unwords (fmap redactWord (Text.words value)))
  where
    redactWord word
      | "password=" `Text.isPrefixOf` Text.toCaseFold word = "password=<redacted>"
      | otherwise = word
    redactUri input = case Text.breakOn "://" input of
      (scheme, rest)
        | not (Text.null rest) ->
            let afterScheme = Text.drop 3 rest
                (authority, suffix) = Text.breakOn "/" afterScheme
             in case Text.breakOnEnd "@" authority of
                  (credentials, host)
                    | not (Text.null credentials) ->
                        let (user, password) = Text.breakOn ":" (Text.dropEnd 1 credentials)
                         in if Text.null password then input else scheme <> "://" <> user <> ":<redacted>@" <> host <> suffix
                  _ -> input
      _ -> input

instance FromJSON RunSpec where
  parseJSON = withObject "RunSpec" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.run-spec/v1" :: Text) then fail "unsupported run-spec schema" else pure ()
    runId <- value .:? "runId"
    scenario <- value .: "scenario"
    scenarioRevision <- value .:? "scenarioRevision"
    rawKnobs <- value .:? "knobs" .!= Map.empty
    knobs <- traverse parseKnob (Map.toList rawKnobs)
    dimensions <- Map.toList <$> value .:? "dimensions" .!= Map.empty
    seed <- value .:? "seed"
    phases <- value .:? "phases"
    timeoutSeconds <- value .:? "timeoutSeconds"
    environment <- value .:? "environment" .!= EnvironmentSpec RunLocal Nothing Nothing Map.empty Nothing Nothing
    cohortExpectation <- value .:? "cohortExpectation"
    comparison <- value .:? "comparison"
    labels <- value .:? "labels" .!= Map.empty
    pure RunSpec {runId, scenario, scenarioRevision, knobs, dimensions, seed, phases, timeoutSeconds, environment, cohortExpectation, comparison, labels}
    where
      parseKnob (name, raw) = case Kenshou.Core.Knob.mkKnobName name of
        Left err -> fail (Text.unpack err)
        Right parsed -> pure (parsed, RawJson raw)

instance ToJSON RunSpec where
  toJSON spec =
    object $
      [ "schema" .= ("kenshou.run-spec/v1" :: Text),
        "scenario" .= spec.scenario,
        "knobs" .= Map.fromList [(Kenshou.Core.Knob.renderKnobName name, rawValue raw) | (name, raw) <- spec.knobs],
        "dimensions" .= Map.fromList spec.dimensions,
        "environment" .= spec.environment,
        "cohortExpectation" .= spec.cohortExpectation,
        "comparison" .= spec.comparison,
        "labels" .= spec.labels
      ]
        <> maybe [] (pure . ("runId" .=)) spec.runId
        <> maybe [] (pure . ("scenarioRevision" .=)) spec.scenarioRevision
        <> maybe [] (pure . ("seed" .=)) spec.seed
        <> maybe [] (pure . ("phases" .=)) spec.phases
        <> maybe [] (pure . ("timeoutSeconds" .=)) spec.timeoutSeconds
    where
      rawValue (RawText value) = String value
      rawValue (RawJson value) = value

instance ToJSON EffectiveRunSpec where
  toJSON spec =
    object
      [ "schema" .= ("kenshou.run-spec/v1" :: Text),
        "runId" .= spec.runId,
        "scenario" .= spec.scenario,
        "scenarioRevision" .= spec.scenarioRevision,
        "knobs" .= spec.knobs,
        "dimensions" .= object [Key.fromText name .= value | (name, value) <- renderDimensions spec.dimensions],
        "seed" .= spec.seed,
        "phases" .= spec.phases,
        "timeoutSeconds" .= spec.timeoutSeconds,
        "environment" .= spec.environment,
        "cohortExpectation" .= spec.cohortExpectation,
        "comparison" .= spec.comparison,
        "labels" .= spec.labels
      ]

instance ToJSON EnvironmentSpec where
  toJSON environment =
    object $
      ["placement" .= placementText environment.placement, "machineProfile" .= environment.machineProfile, "postgres" .= environment.postgres]
        <> ["extraPostgres" .= environment.extraPostgres | not (Map.null environment.extraPostgres)]
        <> ["kafka" .= environment.kafka, "telemetry" .= environment.telemetry]

instance FromJSON EnvironmentSpec where
  parseJSON = withObject "EnvironmentSpec" \value -> EnvironmentSpec <$> (value .:? "placement" .!= RunLocal) <*> value .:? "machineProfile" <*> value .:? "postgres" <*> (value .:? "extraPostgres" .!= Map.empty) <*> value .:? "kafka" <*> value .:? "telemetry"

instance ToJSON SpecPlacement where toJSON = String . placementText

instance FromJSON SpecPlacement where parseJSON = withText "SpecPlacement" \case "local" -> pure RunLocal; "cell" -> pure RunOnCell; other -> fail ("unknown placement " <> Text.unpack other)

placementText :: SpecPlacement -> Text
placementText RunLocal = "local"
placementText RunOnCell = "cell"

instance ToJSON PostgresSpec where
  toJSON (PostgresEphemeral settings) = object ["mode" .= ("ephemeral" :: Text), "settings" .= Map.fromList settings]
  toJSON (PostgresExternal (ConnFromEnv name)) = object ["mode" .= ("external" :: Text), "connectionStringEnv" .= name]
  toJSON (PostgresExternal (ConnLiteral value)) = object ["mode" .= ("external" :: Text), "connectionString" .= redactConnectionString value]

instance FromJSON PostgresSpec where
  parseJSON = withObject "PostgresSpec" \value -> do
    mode <- value .: "mode" :: Parser Text
    case mode of
      "ephemeral" -> PostgresEphemeral . Map.toList <$> value .:? "settings" .!= Map.empty
      "external" -> do
        env <- value .:? "connectionStringEnv"
        literal <- value .:? "connectionString"
        case (env, literal) of (Just name, Nothing) -> pure (PostgresExternal (ConnFromEnv name)); (Nothing, Just connection) -> pure (PostgresExternal (ConnLiteral connection)); _ -> fail "external PostgreSQL requires exactly one connection source"
      _ -> fail "unknown PostgreSQL mode"

instance ToJSON CohortExpectation where toJSON value = object ["name" .= value.name, "planHash" .= value.planHash]

instance FromJSON CohortExpectation where parseJSON = withObject "CohortExpectation" \value -> CohortExpectation <$> value .:? "name" <*> value .: "planHash"

instance ToJSON ComparisonMembership where toJSON value = object ["group" .= value.group, "arm" .= value.arm, "trial" .= value.trial, "position" .= value.position]

instance FromJSON ComparisonMembership where parseJSON = withObject "ComparisonMembership" \value -> ComparisonMembership <$> value .: "group" <*> value .: "arm" <*> value .: "trial" <*> value .: "position"
