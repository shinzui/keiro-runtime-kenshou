module Kenshou.Cli.Command.Run (runCommand) where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Cli.Config
import Kenshou.Core.Cli
import Kenshou.Core.Cli.Config
import Kenshou.Core.Cohort (CohortSource (..), resolveCohortIdentity)
import Kenshou.Core.Id
import Kenshou.Core.Knob (parseAssignment)
import Kenshou.Core.Outcome (renderOutcome)
import Kenshou.Core.Phase (PhasePlan (..), zeroPhases)
import Kenshou.Core.Run
import Kenshou.Core.RunResult (RunResult (..))
import Kenshou.Core.RunSpec
import Kenshou.Core.RunSpec.Resolve
import Kenshou.Env.Kafka.Spec (kafkaEnvSpecFromValue)
import Options.Applicative
import Settei hiding (optional)
import Settei.Env (envSnapshot)
import Settei.Optparse
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (stderr)

data RunOptions = RunOptions
  { specFile :: Maybe InputSource,
    scenario :: Maybe Text,
    config :: ConfigInputs,
    knobs :: [Text],
    dimensions :: [Text],
    seed :: Maybe Seed,
    runId :: Maybe RunId,
    timeout :: Maybe Int,
    phases :: [Text],
    pgUrl :: Maybe Text,
    pgUrlEnv :: Maybe Text,
    placement :: Maybe SpecPlacement,
    machineProfile :: Maybe Text,
    cohortIdentity :: Maybe InputSource,
    cellFingerprint :: Maybe InputSource,
    keepEnvironment :: Bool,
    printSpec :: Bool,
    json :: Bool,
    strictKnownDefects :: Bool
  }

runCommand :: CliCommand
runCommand = CliCommand "run" "Resolve or execute one scenario" Execution False (runHandler <$> runParser)

runParser :: Parser RunOptions
runParser =
  RunOptions
    <$> optional (option (parseInputSource <$> str) (long "spec" <> metavar "FILE" <> help "Read a kenshou.run-spec/v1 document; use - for stdin"))
    <*> optional (Text.pack <$> strArgument (metavar "SCENARIO" <> help "Registered scenario identifier"))
    <*> configInputsParser ((: []) <$> namedOption "--out" outputRootKey (long "out" <> metavar "DIR" <> help "Run output directory"))
    <*> many (Text.pack <$> strOption (long "set" <> metavar "NAME=VALUE" <> help "Set a scenario knob"))
    <*> many (Text.pack <$> strOption (long "dim" <> metavar "NAME=VALUE" <> help "Set a cross-cutting dimension"))
    <*> optional (option (eitherReader readSeed) (long "seed" <> metavar "N" <> help "Replayable random seed"))
    <*> optional (option (eitherReader readRunId) (long "run-id" <> metavar "UUID" <> help "Pre-assign a UUIDv7 run id"))
    <*> optional (option auto (long "timeout" <> metavar "SECONDS" <> help "Run timeout"))
    <*> many (Text.pack <$> strOption (long "phase" <> metavar "NAME=SECONDS" <> help "Override warm-up, steady, or drain duration"))
    <*> optional (Text.pack <$> strOption (long "pg-url" <> metavar "CONNECTION" <> help "Use an external PostgreSQL connection string"))
    <*> optional (Text.pack <$> strOption (long "pg-url-env" <> metavar "VAR" <> help "Read the external PostgreSQL connection string from VAR"))
    <*> optional (option (eitherReader readPlacement) (long "placement" <> metavar "local|cell" <> help "Execution placement"))
    <*> optional (Text.pack <$> strOption (long "machine-profile" <> metavar "NAME" <> help "Stable machine profile name"))
    <*> optional (option (parseInputSource <$> str) (long "cohort-identity" <> metavar "FILE" <> help "Use a resolved cohort identity; use - for stdin"))
    <*> optional (option (parseInputSource <$> str) (long "cell-fingerprint" <> metavar "FILE" <> help "Attach a cell fingerprint; use - for stdin"))
    <*> switch (long "keep-env" <> help "Leave disposable environments running for inspection")
    <*> switch (long "print-spec" <> help "Print the effective run specification without executing")
    <*> switch (long "json" <> help "Print the run result as JSON")
    <*> switch (long "strict-known-defects" <> help "Treat reproduced known defects as blocking")

runHandler :: RunOptions -> CliEnv -> IO ExitCode
runHandler options environment = case schemaDiagnostic options.config.diagnostic (describe runDefaultsConfig) of
  Just output -> Text.IO.putStr output >> pure ExitSuccess
  Nothing -> do
    processEnvironment <- fmap (fmap (\(name, value) -> (Text.pack name, Text.pack value))) getEnvironment
    defaultsResult <- resolveRunDefaults (envSnapshot processEnvironment) options.config
    case defaultsResult of
      Left err -> Text.IO.hPutStrLn stderr err >> pure (ExitFailure 2)
      Right resolved -> case resolved.answer of
        Left problems -> Text.IO.hPutStr stderr (renderErrorsText problems) >> pure (ExitFailure 2)
        Right defaults -> case resolutionDiagnostic options.config.diagnostic resolved of
          Just output -> Text.IO.putStr output >> pure ExitSuccess
          Nothing -> resolveAndRun defaults
  where
    resolveAndRun defaults = do
      if stdinInputCount options > 1
        then Text.IO.hPutStrLn stderr "kenshou: at most one document input may use standard input" >> pure (ExitFailure 2)
        else do
          input <- loadInput options
          case input >>= applyOverrides options of
            Left err -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
            Right spec -> case kafkaEnvSpecFromValue spec.environment.kafka of
              Left err -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
              Right _ -> do
                resolved <- resolveRunSpec environment.registry spec
                case resolved of
                  Left problems -> Text.IO.hPutStrLn stderr (Text.intercalate "\n" [message | SpecError message <- NonEmpty.toList problems]) >> pure (ExitFailure 2)
                  Right (_, effective)
                    | options.printSpec -> LazyByteString.putStrLn (Aeson.encode effective) >> pure ExitSuccess
                    | otherwise -> execute defaults spec

    execute defaults spec = do
      cohortResult <- loadCohort options.cohortIdentity
      cellResult <- loadJsonDocument options.cellFingerprint
      case (cohortResult, cellResult) of
        (Left err, _) -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
        (_, Left err) -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
        (Right cohort, Right cellFingerprint) -> do
          argv <- getArgs
          result <- executeRun (RunnerConfig environment.registry (Text.unpack defaults.outputRoot) cohort cellFingerprint options.keepEnvironment options.strictKnownDefects argv) spec
          case result of
            Left problems -> Text.IO.hPutStrLn stderr (Text.intercalate "\n" [message | SpecError message <- NonEmpty.toList problems]) >> pure (ExitFailure 2)
            Right output -> do
              if options.json
                then LazyByteString.putStrLn (Aeson.encode output.result)
                else Text.IO.putStrLn (renderOutcome output.result.outcome <> "  " <> renderScenarioId output.result.scenario <> "  " <> Text.pack output.directory)
              pure (if output.result.exitCode == 0 then ExitSuccess else ExitFailure output.result.exitCode)

    loadCohort Nothing = first (("unable to resolve cohort identity: " <>) . Text.pack . show) <$> resolveCohortIdentity (FromProject "." Nothing Nothing)
    loadCohort (Just source) = loadDocument "cohort identity" source

    loadJsonDocument Nothing = pure (Right Nothing)
    loadJsonDocument (Just source) = fmap Just <$> loadDocument "cell fingerprint" source

    loadDocument :: (Aeson.FromJSON value) => Text -> InputSource -> IO (Either Text value)
    loadDocument label source = first (("invalid " <> label <> ": ") <>) . first Text.pack . Aeson.eitherDecodeStrict' <$> readInputSource source

loadInput :: RunOptions -> IO (Either Text RunSpec)
loadInput options = case (options.specFile, options.scenario) of
  (Just _, Just _) -> pure (Left "choose either --spec FILE or SCENARIO")
  (Nothing, Nothing) -> pure (Left "provide --spec FILE or SCENARIO")
  (Just source, Nothing) -> do
    bytes <- readInputSource source
    pure (first Text.pack (Aeson.eitherDecodeStrict' bytes))
  (Nothing, Just scenarioText) -> pure (minimalRunSpec <$> parseScenarioId scenarioText)

applyOverrides :: RunOptions -> RunSpec -> Either Text RunSpec
applyOverrides options spec = do
  knobs <- first (Text.pack . show) (traverse parseAssignment options.knobs)
  dimensions <- traverse parseDimension options.dimensions
  phases <- applyPhaseOverrides spec.phases options.phases
  postgres <- case (options.pgUrl, options.pgUrlEnv) of
    (Just _, Just _) -> Left "choose either --pg-url or --pg-url-env"
    (Just connection, Nothing) -> Right (Just (PostgresExternal (ConnLiteral connection)))
    (Nothing, Just variable) -> Right (Just (PostgresExternal (ConnFromEnv variable)))
    (Nothing, Nothing) -> Right spec.environment.postgres
  let environment =
        spec.environment
          { placement = maybe spec.environment.placement id options.placement,
            machineProfile = options.machineProfile <> spec.environment.machineProfile,
            postgres
          }
  pure
    RunSpec
      { runId = options.runId <|> spec.runId,
        scenario = spec.scenario,
        scenarioRevision = spec.scenarioRevision,
        knobs = spec.knobs <> knobs,
        dimensions = spec.dimensions <> dimensions,
        seed = options.seed <|> spec.seed,
        phases,
        timeoutSeconds = options.timeout <|> spec.timeoutSeconds,
        environment,
        cohortExpectation = spec.cohortExpectation,
        comparison = spec.comparison,
        labels = spec.labels
      }
  where
    parseDimension input = case Text.breakOn "=" input of
      (name, assignment) | not (Text.null name) && not (Text.null assignment) -> Right (name, Text.drop 1 assignment)
      _ -> Left ("invalid dimension assignment \"" <> input <> "\"")

applyPhaseOverrides :: Maybe PhasePlan -> [Text] -> Either Text (Maybe PhasePlan)
applyPhaseOverrides existing [] = Right existing
applyPhaseOverrides existing assignments = Just <$> foldl step (Right (maybe zeroPhases id existing)) assignments
  where
    step result assignment = do
      plan <- result
      let (name, rawValue) = Text.breakOn "=" assignment
      seconds <- case reads (Text.unpack (Text.drop 1 rawValue)) of
        [(value, "")] | value >= (0 :: Double) -> Right value
        _ -> Left ("invalid phase assignment \"" <> assignment <> "\"")
      case name of
        "warm-up" -> Right plan {warmUpSeconds = seconds}
        "steady" -> Right plan {steadySeconds = seconds}
        "drain" -> Right plan {drainSeconds = seconds}
        _ -> Left ("unknown phase \"" <> name <> "\"")

stdinInputCount :: RunOptions -> Int
stdinInputCount options = length [() | Just InputStdin <- [options.specFile, options.cohortIdentity, options.cellFingerprint]]

readSeed :: String -> Either String Seed
readSeed input = case reads input of [(value, "")] -> first Text.unpack (mkSeed value); _ -> Left "seed must be an integer"

readRunId :: String -> Either String RunId
readRunId = first Text.unpack . parseRunId . Text.pack

readPlacement :: String -> Either String SpecPlacement
readPlacement "local" = Right RunLocal
readPlacement "cell" = Right RunOnCell
readPlacement value = Left ("unknown placement " <> show value)
