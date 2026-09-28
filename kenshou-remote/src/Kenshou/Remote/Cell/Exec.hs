module Kenshou.Remote.Cell.Exec (resolveOnCell) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry, lookupScenario)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..), TracingArm (..), resolveDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (Kind (..), ScenarioId (..), renderScenarioId)
import Kenshou.Core.Knob (KnobSpec (..), RawKnob (..), mkKnobName)
import Kenshou.Core.RunSpec (ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..))
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (CellBroker (..), CellEnvironment (..), CellPostgres (..), OtlpEndpoint (..), OtlpSinks (..))
import Kenshou.Remote.Cell.Prepare (OtlpSink (..))

-- Bind the generic environment in a prepared work plan to endpoints available
-- on this cell. Run IDs and plan metadata are preserved; no run is silently
-- dropped here.
resolveOnCell :: Registry -> CellEnvironment -> OtlpSink -> RunPlan -> Either Text RunPlan
resolveOnCell registry environment sink plan = do
  runs <- traverse resolveRun plan.runs
  pure (RunPlan plan.planId plan.createdAt plan.context plan.policy runs plan.skipped plan.estimateMinutes)
  where
    resolveRun entry = do
      scenario <- maybe (Left ("unknown cell scenario: " <> renderScenarioId entry.spec.scenario)) Right (lookupScenario registry entry.spec.scenario)
      if scenario.placement == PlaceLocal
        then Left ("scenario is local-only: " <> renderScenarioId scenario.id)
        else pure ()
      dimensions <- either (Left . Text.intercalate "; " . NonEmpty.toList) Right (resolveDimensions scenario.dimensions entry.spec.dimensions)
      postgres <- bindPostgres scenario entry.spec dimensions
      extras <- bindExtras scenario entry.spec postgres
      kafka <- bindKafka scenario
      knobs <- bindOtlp scenario entry.spec dimensions
      let prior = entry.spec.environment
          cellEnvironment = EnvironmentSpec RunOnCell prior.machineProfile postgres extras kafka prior.telemetry
          spec = entry.spec
          resolved = RunSpec spec.runId spec.scenario spec.scenarioRevision knobs spec.dimensions spec.seed spec.phases spec.timeoutSeconds cellEnvironment spec.cohortExpectation spec.comparison spec.labels
      pure (PlannedRun entry.ordinal entry.runId entry.estimateMinutes entry.reasons entry.trial resolved)

    bindPostgres scenario spec dimensions = case scenario.requires.postgres of
      Nothing -> pure spec.environment.postgres
      Just requirement
        | requirement.needsServerControl ->
            if scenario.id.kind `elem` [Correctness, Concurrency]
              then case spec.environment.postgres of
                Just ephemeral@(PostgresEphemeral _) -> pure (Just ephemeral)
                _ -> Left ("scenario needs driver-local PostgreSQL server control: " <> renderScenarioId scenario.id)
              else Left ("benchmark or soak cannot control the cell PostgreSQL server: " <> renderScenarioId scenario.id)
        | otherwise -> do
            if dimensions.pgDurability /= Just PgDurable
              then Left ("cell run requires pg.durability=durable: " <> renderScenarioId scenario.id)
              else pure ()
            let requested = case dimensions.pgVersion of Just Pg17 -> 17; Just Pg18 -> 18; Nothing -> 0
            if requested /= environment.postgres.major
              then Left ("cell PostgreSQL major differs from pg.version for " <> renderScenarioId scenario.id)
              else pure (Just (PostgresExternal (ConnFromEnv "KENSHOU_CELL_PG_URL")))

    bindExtras scenario spec primary =
      if case primary of Just (PostgresEphemeral _) -> True; _ -> False
        then Map.fromList <$> traverse driverExtra scenario.requires.extraPostgres
        else do
          let requirements = scenario.requires.extraPostgres
              variableNames = fmap (variableName . fst) requirements
          if any (.needsServerControl) (fmap snd requirements)
            then Left ("extra PostgreSQL server needs driver-local control: " <> renderScenarioId scenario.id)
            else pure ()
          if length variableNames /= length (unique variableNames)
            then Left "extra PostgreSQL names collide as environment variables"
            else pure (Map.fromList [(name, PostgresExternal (ConnFromEnv ("KENSHOU_CELL_PG_URL_" <> variableName name))) | (name, _) <- requirements])
      where
        driverExtra (name, _) = case Map.lookup name spec.environment.extraPostgres of
          Nothing -> pure (name, PostgresEphemeral [])
          Just local@(PostgresEphemeral _) -> pure (name, local)
          Just (PostgresExternal _) -> Left ("driver-local PostgreSQL requires every extra server to be ephemeral: " <> name)

    bindKafka scenario
      | not scenario.requires.kafka = pure Nothing
      | otherwise = case environment.broker of
          Nothing -> Left ("cell has no Kafka broker for " <> renderScenarioId scenario.id)
          Just broker ->
            let addresses = filter (not . Text.null) (fmap Text.strip (Text.splitOn "," broker.bootstrapServers))
             in if null addresses
                  then Left "cell broker has no bootstrap servers"
                  else pure (Just (object ["backend" .= ("external" :: Text), "brokers" .= addresses, "lanes" .= (0 :: Int)]))

    bindOtlp scenario spec dimensions
      | dimensions.tracing /= Just TracingSdkOtlp = pure spec.knobs
      | otherwise = do
          name <- mkKnobName "otel.endpoint"
          if name `notElem` fmap (.name) scenario.knobs
            then Left ("tracing scenario lacks otel.endpoint: " <> renderScenarioId scenario.id)
            else pure ()
          sinks <- maybe (Left "cell has no OTLP sink") Right environment.otlp
          let endpoint = case sink of NullSink -> sinks.nullEndpoint.http; FileSink -> sinks.fileEndpoint.http
          if Text.null endpoint
            then Left "cell OTLP sink has no HTTP endpoint"
            else pure ((name, RawText endpoint) : filter ((/= name) . fst) spec.knobs)

variableName :: Text -> Text
variableName = Text.map (\character -> if character == '-' then '_' else character) . Text.toUpper

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (first : rest) = first : unique (filter (/= first) rest)
