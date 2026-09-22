module Kenshou.Cli.Command.Overhead (overheadCommand) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (isPrefixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Word (Word64)
import Kenshou.Core.Bundle (lookupScenario)
import Kenshou.Core.Cli
import Kenshou.Core.Id (ScenarioId, newRunId, parseScenarioId, renderRunId)
import Kenshou.Core.Knob (KnobError (..), KnobName, RawKnob, parseAssignment)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Diagnose.Leak (analyseRunDirectory, defaultLeakSpec)
import Kenshou.Measure.Compare (Verdict (..), compareRuns)
import Kenshou.Telemetry.Overhead
import Kenshou.Telemetry.Overhead.Policy
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO (IOMode (..), stderr, withFile)
import System.Process (StdStream (..), createProcess, proc, std_err, std_out, waitForProcess)

data OverheadOptions = OverheadOptions
  { scenario :: Text,
    arms :: [Text],
    mode :: OverheadMode,
    control :: Bool,
    trials :: Int,
    knobs :: [Text],
    dimensions :: [Text],
    policy :: Maybe InputSource,
    seed :: Word64,
    settleSeconds :: Int,
    retries :: Int,
    resume :: Bool,
    analyseOnly :: Bool,
    json :: Bool,
    out :: FilePath
  }

overheadCommand :: CliCommand
overheadCommand = CliCommand "overhead" "Run interleaved telemetry overhead arms" Execution False (overheadHandler <$> overheadParser)

overheadParser :: Parser OverheadOptions
overheadParser =
  OverheadOptions
    <$> (Text.pack <$> strArgument (metavar "SCENARIO" <> help "Registered benchmark scenario"))
    <*> some (Text.pack <$> strOption (long "arms" <> metavar "FACTOR=VALUE,..." <> help "Telemetry factor and ordered arm values"))
    <*> option (eitherReader parseMode) (long "mode" <> metavar "one-factor|full" <> value OneFactor <> showDefaultWith (const "one-factor") <> help "Arm expansion mode")
    <*> switch (long "control" <> help "Add an identical baseline A/A arm")
    <*> option auto (long "trials" <> metavar "N" <> value 3 <> showDefault <> help "Valid paired blocks")
    <*> many (Text.pack <$> strOption (long "set" <> metavar "NAME=VALUE" <> help "Set a fixed scenario knob"))
    <*> many (Text.pack <$> strOption (long "dim" <> metavar "NAME=VALUE" <> help "Set a fixed dimension"))
    <*> optional (option (parseInputSource <$> str) (long "policy" <> metavar "FILE" <> help "Read kenshou.overhead-policy/v1; use - for stdin"))
    <*> option auto (long "seed" <> metavar "N" <> value 7 <> showDefault <> help "Replayable ordering seed")
    <*> option auto (long "settle-seconds" <> metavar "S" <> value 2 <> showDefault <> help "Pause between child runs")
    <*> option auto (long "retries" <> metavar "R" <> value 1 <> showDefault <> help "Retries for infrastructure failures")
    <*> switch (long "resume" <> help "Resume the latest matching overhead directory")
    <*> switch (long "analyse-only" <> help "Rebuild a report without running child slots")
    <*> switch (long "json" <> help "Print only the overhead report JSON")
    <*> strOption (long "out" <> metavar "DIR" <> help "Output root or overhead invocation directory")

overheadHandler :: OverheadOptions -> CliEnv -> IO ExitCode
overheadHandler options environment = case parseScenarioId options.scenario of
  Left err -> usage err
  Right scenarioId -> case lookupScenario environment.registry scenarioId of
    Nothing -> usage ("unknown scenario " <> options.scenario)
    Just scenario -> do
      parsed <- pure (parseInputs options)
      case parsed of
        Left err -> usage err
        Right (factors, fixedKnobs, fixedDimensions) -> do
          selectedPolicy <- loadPolicy options.policy
          case selectedPolicy of
            Left err -> usage err
            Right policy -> do
              resumed <- if options.resume || options.analyseOnly then findResumeDirectory options.out scenarioId else pure Nothing
              case (options.resume || options.analyseOnly, resumed) of
                (True, Nothing) -> usage "no matching overhead state was found under --out"
                (_, Just directory) -> continue policy directory
                (_, Nothing) -> do
                  identifier <- renderRunId <$> newRunId
                  let directory = options.out </> ("overhead-" <> Text.unpack identifier)
                      request = OverheadRequest identifier scenarioId factors options.mode options.control options.trials fixedKnobs fixedDimensions options.seed options.settleSeconds options.retries
                  case planOverhead request scenario of
                    Left (UsageError err) -> usage err
                    Right plan -> do
                      createDirectoryIfMissing True directory
                      runPlan policy directory plan Nothing
  where
    continue policy directory = do
      loaded <- loadOverheadState directory
      case loaded of
        Left err -> usage ("invalid overhead state: " <> Text.pack err)
        Right state -> runPlan policy directory state.plan (Just state)

    runPlan policy directory plan existing = do
      executable <- getExecutablePath
      let leakCheck runDirectory = fmap (either (const Nothing) (Just . Aeson.toJSON)) (analyseRunDirectory runDirectory defaultLeakSpec plan.seed)
          hooks = OverheadHooks (runChildProcess executable directory) compareRuns (Just leakCheck)
      state <- if options.analyseOnly then maybe (fail "missing overhead state") pure existing else executeOverhead hooks plan directory
      report <- analyseOverhead hooks policy plan state directory
      if options.json
        then LazyByteString.putStrLn (Aeson.encode report)
        else do
          mapM_ printComparison report.comparisons
          Text.IO.putStrLn ("verdict " <> verdictText report.verdict <> "  " <> Text.pack directory)
      pure case overheadVerdictExitCode report.verdict of 0 -> ExitSuccess; code -> ExitFailure code

    printComparison comparison =
      Text.IO.putStrLn (comparison.candidate <> " vs " <> comparison.baseline <> "  " <> verdictText comparison.verdict)

usage :: Text -> IO ExitCode
usage message = Text.IO.hPutStrLn stderr ("kenshou: " <> message) >> pure (ExitFailure 2)

parseInputs :: OverheadOptions -> Either Text (Map Text [Text], [(KnobName, RawKnob)], Map Text Text)
parseInputs options = do
  factorPairs <- traverse parseArms options.arms
  let factorNames = fmap fst factorPairs
  if length factorNames /= Map.size (Map.fromList [(name, ()) | name <- factorNames])
    then Left "each --arms factor may be specified only once"
    else pure ()
  fixedKnobs <- traverse parseKnob options.knobs
  fixedDimensions <- Map.fromList <$> traverse parseAssignmentText options.dimensions
  pure (Map.fromList factorPairs, fixedKnobs, fixedDimensions)
  where
    parseKnob input = case parseAssignment input of Left (KnobError err) -> Left err; Right parsed -> Right parsed

parseArms :: Text -> Either Text (Text, [Text])
parseArms input = do
  (rawName, rawValues) <- parseAssignmentText input
  name <- case rawName of
    "tracing" -> Right "telemetry.tracing"
    "metrics" -> Right "telemetry.metrics"
    "telemetry.tracing" -> Right rawName
    "telemetry.metrics" -> Right rawName
    _ -> Left ("unknown overhead factor " <> rawName)
  let values = Text.splitOn "," rawValues
  if any Text.null values then Left (name <> " contains an empty arm value") else Right (name, values)

parseAssignmentText :: Text -> Either Text (Text, Text)
parseAssignmentText input = case Text.breakOn "=" input of
  (name, assignment) | not (Text.null name) && not (Text.null assignment) -> Right (name, Text.drop 1 assignment)
  _ -> Left ("expected NAME=VALUE, got " <> input)

parseMode :: String -> Either String OverheadMode
parseMode "one-factor" = Right OneFactor
parseMode "full" = Right FullFactorial
parseMode input = Left ("unknown mode " <> input)

loadPolicy :: Maybe InputSource -> IO (Either Text OverheadPolicy)
loadPolicy source = do
  bytes <- readInputSource (maybe (InputFile "policies/telemetry-overhead.json") id source)
  pure (either (Left . Text.pack) Right (decodeOverheadPolicy bytes))

findResumeDirectory :: FilePath -> ScenarioId -> IO (Maybe FilePath)
findResumeDirectory root scenarioId = do
  direct <- doesFileExist (root </> "state.json")
  if direct
    then matching root
    else do
      namesResult <- try (listDirectory root) :: IO (Either IOException [FilePath])
      let candidates = case namesResult of Left _ -> []; Right names -> reverse (sort [root </> name | name <- names, "overhead-" `isPrefixOf` takeFileName name])
      firstMatching candidates
  where
    matching directory = do
      loaded <- loadOverheadState directory
      pure case loaded of Right state | state.plan.scenarioId == scenarioId -> Just directory; _ -> Nothing
    firstMatching [] = pure Nothing
    firstMatching (directory : rest) = matching directory >>= maybe (firstMatching rest) (pure . Just)

runChildProcess :: FilePath -> FilePath -> RunSpec -> FilePath -> IO ExitCode
runChildProcess executable invocation spec runsRoot = do
  createDirectoryIfMissing True (invocation </> ".specs")
  createDirectoryIfMissing True (invocation </> "logs")
  let identifier = maybe "unassigned" (Text.unpack . renderRunId) spec.runId
      specPath = invocation </> ".specs" </> identifier <> ".json"
      logPath = invocation </> "logs" </> identifier <> ".log"
  Aeson.encodeFile specPath spec
  withFile logPath WriteMode \handle -> do
    (_, _, _, process) <- createProcess (proc executable ["run", "--spec", specPath, "--out", runsRoot]) {std_out = UseHandle handle, std_err = UseHandle handle}
    waitForProcess process

verdictText :: Verdict -> Text
verdictText VerdictPass = "pass"
verdictText VerdictRegression = "regression"
verdictText VerdictInconclusive = "inconclusive"
verdictText VerdictInfrastructureFailure = "infrastructure-failure"
