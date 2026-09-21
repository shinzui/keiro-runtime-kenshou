module Kenshou.Cli.Command.Run (runCommand) where

import Control.Applicative ((<|>))
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
import Kenshou.Core.Id
import Kenshou.Core.Knob (parseAssignment)
import Kenshou.Core.RunSpec
import Kenshou.Core.RunSpec.Resolve
import Options.Applicative
import Settei hiding (optional)
import Settei.Env (envSnapshot)
import Settei.Optparse
import System.Environment (getEnvironment)
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
    printSpec :: Bool
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
    <*> switch (long "print-spec" <> help "Print the effective run specification without executing")

runHandler :: RunOptions -> CliEnv -> IO ExitCode
runHandler options environment = case schemaDiagnostic options.config.diagnostic (describe runDefaultsConfig) of
  Just output -> Text.IO.putStr output >> pure ExitSuccess
  Nothing -> do
    processEnvironment <- fmap (fmap (\(name, value) -> (Text.pack name, Text.pack value))) getEnvironment
    defaultsResult <- resolveRunDefaults (envSnapshot processEnvironment) options.config
    case defaultsResult of
      Left err -> Text.IO.hPutStrLn stderr err >> pure (ExitFailure 4)
      Right resolved -> case resolved.answer of
        Left problems -> Text.IO.hPutStr stderr (renderErrorsText problems) >> pure (ExitFailure 4)
        Right _defaults -> case resolutionDiagnostic options.config.diagnostic resolved of
          Just output -> Text.IO.putStr output >> pure ExitSuccess
          Nothing -> resolveAndPrint
  where
    resolveAndPrint = do
      input <- loadInput options
      case input >>= applyOverrides options of
        Left err -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
        Right spec -> do
          resolved <- resolveRunSpec environment.registry spec
          case resolved of
            Left problems -> Text.IO.hPutStrLn stderr (Text.intercalate "\n" [message | SpecError message <- NonEmpty.toList problems]) >> pure (ExitFailure 2)
            Right (_, effective)
              | options.printSpec -> LazyByteString.putStrLn (Aeson.encode effective) >> pure ExitSuccess
              | otherwise -> Text.IO.hPutStrLn stderr "kenshou: execution requires Milestone 4; use --print-spec" >> pure (ExitFailure 4)

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
  pure
    RunSpec
      { runId = options.runId <|> spec.runId,
        scenario = spec.scenario,
        scenarioRevision = spec.scenarioRevision,
        knobs = spec.knobs <> knobs,
        dimensions = spec.dimensions <> dimensions,
        seed = options.seed <|> spec.seed,
        phases = spec.phases,
        timeoutSeconds = options.timeout <|> spec.timeoutSeconds,
        environment = spec.environment,
        cohortExpectation = spec.cohortExpectation,
        comparison = spec.comparison,
        labels = spec.labels
      }
  where
    parseDimension input = case Text.breakOn "=" input of
      (name, assignment) | not (Text.null name) && not (Text.null assignment) -> Right (name, Text.drop 1 assignment)
      _ -> Left ("invalid dimension assignment \"" <> input <> "\"")

readSeed :: String -> Either String Seed
readSeed input = case reads input of [(value, "")] -> first Text.unpack (mkSeed value); _ -> Left "seed must be an integer"

readRunId :: String -> Either String RunId
readRunId = first Text.unpack . parseRunId . Text.pack
