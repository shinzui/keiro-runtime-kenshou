module Kenshou.Remote.Cell.Exec (resolveOnCell, resolveWorkJson, cellExec) where

import Control.Exception (SomeAsyncException, SomeException, displayException, finally, fromException, throwIO, try)
import Control.Monad (when)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Kenshou.Core.Bundle (Registry, lookupScenario)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..), TracingArm (..), resolveDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (Kind (..), RunId, ScenarioId (..), parseRunId, renderScenarioId)
import Kenshou.Core.Knob (KnobSpec (..), RawKnob (..), mkKnobName)
import Kenshou.Core.RunSpec (ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..))
import Kenshou.Plan.Execute (ExecuteOptions (..), executePlan)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Plan.Summary (summaryExitCode)
import Kenshou.Remote.Cell.Docs (CellBroker (..), CellEnvironment (..), CellPostgres (..), OtlpEndpoint (..), OtlpSinks (..))
import Kenshou.Remote.Cell.Health (withCellHealthFile)
import Kenshou.Remote.Cell.Prepare (OtlpSink (..))
import System.Directory (Permissions (..), createDirectoryIfMissing, doesFileExist, getPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process (readProcessWithExitCode)

-- Bind the generic environment in a prepared work plan to endpoints available
-- on this cell. Run IDs and plan metadata are preserved; no run is silently
-- dropped here.
resolveOnCell :: Registry -> CellEnvironment -> OtlpSink -> RunPlan -> Either Text RunPlan
resolveOnCell registry environment sink plan = do
  runs <- traverse resolveRun plan.runs
  pure (RunPlan plan.planId plan.createdAt plan.context plan.policy runs plan.skipped plan.estimateMinutes)
  where
    resolveRun entry = do
      resolved <- resolveSpec registry environment sink entry.spec
      pure (PlannedRun entry.ordinal entry.runId entry.estimateMinutes entry.reasons entry.trial resolved)

-- The executor accepts a narrow run-plan JSON document rather than decoding
-- every planning provenance type. Rewrite just the spec member of each entry.
resolveWorkJson :: Registry -> CellEnvironment -> OtlpSink -> Value -> Either Text Value
resolveWorkJson registry environment sink work = fst <$> resolveWorkDocument registry environment sink work

resolveWorkDocument :: Registry -> CellEnvironment -> OtlpSink -> Value -> Either Text (Value, [RunSpec])
resolveWorkDocument registry environment sink work = case work of
  Object fields -> case (KeyMap.lookup "schema" fields, KeyMap.lookup "runs" fields) of
    (Just (String "kenshou.run-plan/v1"), Just (Array runs)) -> do
      resolved <- traverse resolveEntry runs
      pure (Object (KeyMap.insert "runs" (Array (fmap fst resolved)) fields), toList (fmap snd resolved))
    _ -> Left "cell work is not a kenshou.run-plan/v1 document"
  _ -> Left "cell work is not a JSON object"
  where
    resolveEntry (Object entry) = do
      identifier <- case KeyMap.lookup "runId" entry of
        Just value -> (decodeValue "planned run ID" value :: Either Text RunId)
        Nothing -> Left "cell work entry has no run ID"
      spec <- case KeyMap.lookup "spec" entry of
        Just value -> (decodeValue "planned run spec" value :: Either Text RunSpec)
        Nothing -> Left "cell work entry has no run spec"
      if maybe True (== identifier) spec.runId
        then pure ()
        else Left "cell work entry and spec have different run IDs"
      resolved <- resolveSpec registry environment sink spec
      pure (Object (KeyMap.insert "spec" (Aeson.toJSON resolved) entry), resolved)
    resolveEntry _ = Left "cell work run is not an object"

    decodeValue :: (Aeson.FromJSON document) => Text -> Value -> Either Text document
    decodeValue label value = case Aeson.fromJSON value of
      Aeson.Error failure -> Left (label <> ": " <> Text.pack failure)
      Aeson.Success document -> Right document

resolveSpec :: Registry -> CellEnvironment -> OtlpSink -> RunSpec -> Either Text RunSpec
resolveSpec registry environment sink spec = do
  scenario <- maybe (Left ("unknown cell scenario: " <> renderScenarioId spec.scenario)) Right (lookupScenario registry spec.scenario)
  if scenario.placement == PlaceLocal
    then Left ("scenario is local-only: " <> renderScenarioId scenario.id)
    else pure ()
  dimensions <- either (Left . Text.intercalate "; " . NonEmpty.toList) Right (resolveDimensions scenario.dimensions spec.dimensions)
  postgres <- bindPostgres scenario dimensions
  extras <- bindExtras scenario postgres
  kafka <- bindKafka scenario
  telemetryKnobs <- bindOtlp scenario dimensions
  knobs <- bindRemoteScenario telemetryKnobs
  let prior = spec.environment
      cellEnvironment = EnvironmentSpec RunOnCell prior.machineProfile postgres extras kafka prior.telemetry
  pure (RunSpec spec.runId spec.scenario spec.scenarioRevision knobs spec.dimensions spec.seed spec.phases spec.timeoutSeconds cellEnvironment spec.cohortExpectation spec.comparison spec.labels)
  where
    bindPostgres scenario dimensions = case scenario.requires.postgres of
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

    bindExtras scenario primary =
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

    bindOtlp scenario dimensions
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

    bindRemoteScenario knobs
      | renderScenarioId spec.scenario /= "selftest/remote/correctness/cell-environment" = pure knobs
      | otherwise = do
          placementName <- mkKnobName "remote.expect-placement"
          otlpName <- mkKnobName "remote.otlp-endpoint"
          kafkaName <- mkKnobName "remote.kafka-bootstrap"
          let selectedOtlp = case environment.otlp of
                Nothing -> ""
                Just sinks -> case sink of NullSink -> sinks.nullEndpoint.http; FileSink -> sinks.fileEndpoint.http
              selectedKafka = maybe "" (.bootstrapServers) environment.broker
              placed = assign placementName "cell" knobs
              withOtlp = assignWhenBlank otlpName selectedOtlp placed
          pure (assignWhenBlank kafkaName selectedKafka withOtlp)

    assignWhenBlank name value knobs
      | Text.null value || maybe False (not . blank) (lookup name knobs) = knobs
      | otherwise = assign name value knobs
    blank (RawText value) = Text.null value
    blank (RawJson (String value)) = Text.null value
    blank _ = False
    assign name value knobs = (name, RawText value) : filter ((/= name) . fst) knobs

variableName :: Text -> Text
variableName = Text.map (\character -> if character == '-' then '_' else character) . Text.toUpper

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (first : rest) = first : unique (filter (/= first) rest)

-- The generic cell agent invokes this command on the first driver with the
-- submitted work and an environment document. Every child run receives the
-- resolved plan, the cell context and the same payload identity variables.
cellExec :: Registry -> FilePath -> FilePath -> IO ExitCode
cellExec registry workFile outDir = do
  result <- try (executeOnDriver registry workFile outDir) :: IO (Either SomeException ExitCode)
  case result of
    Left failure | Just async <- (fromException failure :: Maybe SomeAsyncException) -> throwIO async
    Left failure -> adapterFailure outDir (Text.pack (displayException failure))
    Right code -> pure code

executeOnDriver :: Registry -> FilePath -> FilePath -> IO ExitCode
executeOnDriver registry workFile outDir = do
  driverIndex <- integerEnv "CELL_DRIVER_INDEX" 0
  driverCount <- integerEnv "CELL_DRIVER_COUNT" 1
  when (driverIndex >= driverCount) (ioError (userError "CELL_DRIVER_INDEX exceeds CELL_DRIVER_COUNT"))
  let cellDirectory = outDir </> "kenshou-cell"
  createDirectoryIfMissing True cellDirectory
  if driverIndex /= 0
    then do
      LazyByteString.writeFile (outDir </> "idle-driver.json") (encode (object ["schema" .= ("kenshou.cell-idle-driver/v1" :: Text), "index" .= driverIndex, "count" .= driverCount]))
      pure ExitSuccess
    else do
      environmentPath <- requiredEnv "CELL_ENV_FILE"
      environment <- Aeson.eitherDecodeFileStrict' environmentPath >>= either (ioError . userError . ("invalid CELL_ENV_FILE: " <>)) pure
      cellRun <- requiredEnv "CELL_RUN_ID" >>= either (ioError . userError . Text.unpack) pure . parseRunId . Text.pack
      when (cellRun /= environment.runId) (ioError (userError "CELL_RUN_ID differs from the cell environment"))
      scratch <- requiredEnv "CELL_SCRATCH_DIR"
      sink <-
        requiredEnv "KENSHOU_OTLP_SINK" >>= \case
          "null" -> pure NullSink
          "file" -> pure FileSink
          _ -> ioError (userError "KENSHOU_OTLP_SINK must be null or file")
      identity <- requiredEnv "KENSHOU_COHORT_IDENTITY"
      present <- doesFileExist identity
      when (not present) (ioError (userError "payload cohort identity file is missing"))
      payload <- requiredPayloadIdentity
      work <- Aeson.eitherDecodeFileStrict' workFile >>= either (ioError . userError . ("invalid cell work: " <>)) pure
      (resolved, specs) <- either (ioError . userError . Text.unpack) pure (resolveWorkDocument registry environment sink work)
      let planPath = cellDirectory </> "plan.resolved.json"
          contextPath = cellDirectory </> "context.json"
          noticePath = cellDirectory </> "health-notices.jsonl"
          cachePath = scratch </> "cache"
          tempPath = scratch </> "tmp"
      createDirectoryIfMissing True cachePath
      createDirectoryIfMissing True tempPath
      LazyByteString.writeFile planPath (encode resolved)
      LazyByteString.writeFile noticePath ""
      setEnv "KENSHOU_CELL_PG_URL" (Text.unpack environment.postgres.connectionString)
      mapM_ (setExtraPostgres environment.postgres.connectionString) specs
      setEnv "KENSHOU_CELL_FINGERPRINT" contextPath
      setEnv "KENSHOU_HEALTH_NOTICES" noticePath
      setEnv "XDG_CACHE_HOME" cachePath
      setEnv "TMPDIR" tempPath
      faultEnabled <- case environment.faultHook of
        Nothing -> unsetEnv "KENSHOU_CELL_FAULT_HOOK" >> pure False
        Just hook -> do
          available <- doesFileExist (Text.unpack hook)
          executableHook <- if available then (.executable) <$> getPermissions (Text.unpack hook) else pure False
          if executableHook then setEnv "KENSHOU_CELL_FAULT_HOOK" (Text.unpack hook) else unsetEnv "KENSHOU_CELL_FAULT_HOOK"
          pure executableHook
      pgPartman <- probePgPartman environment.postgres.connectionString
      LazyByteString.writeFile contextPath (encode (cellContext environment driverIndex driverCount sink faultEnabled pgPartman payload))
      if driverCount > 1
        then setEnv "KENSHOU_CLOCK_SKEW_BOUND_MICROS" (show (maybe 50000 id environment.clockSkewBoundMicros))
        else unsetEnv "KENSHOU_CLOCK_SKEW_BOUND_MICROS"
      healthFile <- lookupEnv "CELL_HEALTH_FILE"
      let runPlan = executePlan (ExecuteOptions planPath outDir False False Nothing Nothing)
          withHealth = withCellHealthFile healthFile noticePath cellRun runPlan
      summary <- if faultEnabled then healAll environment.faultHook >> withHealth `finally` healAll environment.faultHook else withHealth
      pure (summaryExitCode summary)

healAll :: Maybe Text -> IO ()
healAll Nothing = pure ()
healAll (Just hook) = do
  (code, _, errors) <- readProcessWithExitCode (Text.unpack hook) ["heal-all"] ""
  when (code /= ExitSuccess) (ioError (userError ("cell fault hook heal-all failed: " <> errors)))

setExtraPostgres :: Text -> RunSpec -> IO ()
setExtraPostgres connection spec = mapM_ setOne (Map.elems spec.environment.extraPostgres)
  where
    setOne (PostgresExternal (ConnFromEnv name)) | "KENSHOU_CELL_PG_URL_" `Text.isPrefixOf` name = setEnv (Text.unpack name) (Text.unpack connection)
    setOne _ = pure ()

probePgPartman :: Text -> IO (Maybe Text)
probePgPartman connection = do
  (code, output, errors) <- readProcessWithExitCode "psql" ["-d", Text.unpack connection, "-Atqc", "SELECT COALESCE((SELECT default_version FROM pg_available_extensions WHERE name = 'pg_partman'), '')"] ""
  case code of
    ExitSuccess -> pure case Text.strip (Text.pack output) of
      "" -> Nothing
      version -> Just version
    _ -> ioError (userError ("PostgreSQL extension probe failed: " <> errors))

cellContext :: CellEnvironment -> Int -> Int -> OtlpSink -> Bool -> Maybe Text -> Map.Map Text Text -> Value
cellContext environment driverIndex driverCount sink faultEnabled pgPartman payload =
  object
    [ "schema" .= ("kenshou.cell-context/v1" :: Text),
      "cell" .= environment.cell,
      "cellRun" .= environment.runId,
      "leaseId" .= environment.leaseId,
      "driver" .= object ["index" .= driverIndex, "count" .= driverCount],
      "postgres" .= object ["major" .= environment.postgres.major, "host" .= environment.postgres.host, "port" .= environment.postgres.port, "placement" .= ("cell-server" :: Text), "extraPostgres" .= ("shared-server" :: Text), "extensions" .= object ["pg_partman" .= object ["available" .= maybe False (const True) pgPartman, "version" .= pgPartman]]],
      "broker" .= environment.broker,
      "capabilities"
        .= object
          [ "postgres.major" .= Text.pack (show environment.postgres.major),
            "postgres.pg_partman" .= maybe False (const True) pgPartman,
            "postgres.second-server" .= False,
            "postgres.control-hook" .= False,
            "broker" .= maybe "none" (\broker -> broker.implementation <> " " <> broker.version) environment.broker,
            "otlp.null" .= maybe False (not . Text.null . (.nullEndpoint.http)) environment.otlp,
            "otlp.file" .= maybe False (not . Text.null . (.fileEndpoint.http)) environment.otlp,
            "fault-hook" .= faultEnabled
          ],
      "otlpSink" .= (case sink of NullSink -> "null" :: Text; FileSink -> "file"),
      "faultHook" .= faultEnabled,
      "clock" .= object ["skewBoundMicros" .= environment.clockSkewBoundMicros],
      "payload"
        .= object
          [ "bundleSha256" .= field "KENSHOU_PAYLOAD_BUNDLE_SHA256",
            "storePath" .= field "KENSHOU_PAYLOAD_STORE_PATH",
            "narHash" .= field "KENSHOU_PAYLOAD_NAR_HASH",
            "cohort" .= field "KENSHOU_PAYLOAD_COHORT",
            "harness" .= object ["revision" .= field "KENSHOU_HARNESS_REVISION", "dirty" .= (field "KENSHOU_HARNESS_DIRTY" == "true")]
          ]
    ]
  where
    field name = Map.findWithDefault "" name payload

requiredPayloadIdentity :: IO (Map.Map Text Text)
requiredPayloadIdentity = do
  values <- Map.fromList <$> traverse load (filter (/= "KENSHOU_COHORT_IDENTITY") payloadIdentityNames)
  when (Map.lookup "KENSHOU_HARNESS_DIRTY" values `notElem` [Just "true", Just "false"]) (ioError (userError "KENSHOU_HARNESS_DIRTY must be true or false"))
  pure values
  where
    load name = (name,) . Text.pack <$> requiredEnv (Text.unpack name)

requiredEnv :: String -> IO String
requiredEnv name =
  lookupEnv name >>= \case
    Just value | not (null value) -> pure value
    _ -> ioError (userError (name <> " is required by the cell payload"))

integerEnv :: String -> Int -> IO Int
integerEnv name fallback =
  lookupEnv name >>= \case
    Nothing -> pure fallback
    Just raw -> case reads raw of
      [(value, "")] | value >= 0 -> pure value
      _ -> ioError (userError (name <> " must be a non-negative integer"))

adapterFailure :: FilePath -> Text -> IO ExitCode
adapterFailure outDir detail = do
  let directory = outDir </> "kenshou-cell"
      reason :: Text
      reason
        | "CELL_ENV_FILE" `Text.isInfixOf` detail = "cell-environment-missing"
        | any (`Text.isInfixOf` detail) payloadIdentityNames = "payload-identity-missing"
        | otherwise = "cell-exec-failed"
  createDirectoryIfMissing True directory
  LazyByteString.writeFile (directory </> "adapter-error.json") (encode (object ["schema" .= ("kenshou.cell-adapter-error/v1" :: Text), "reason" .= reason, "detail" .= detail]))
  TextIO.hPutStrLn stderr ("kenshou cell exec: " <> detail)
  pure (ExitFailure 4)

payloadIdentityNames :: [Text]
payloadIdentityNames =
  [ "KENSHOU_COHORT_IDENTITY",
    "KENSHOU_HARNESS_REVISION",
    "KENSHOU_HARNESS_DIRTY",
    "KENSHOU_PAYLOAD_BUNDLE_SHA256",
    "KENSHOU_PAYLOAD_STORE_PATH",
    "KENSHOU_PAYLOAD_NAR_HASH",
    "KENSHOU_PAYLOAD_COHORT"
  ]
