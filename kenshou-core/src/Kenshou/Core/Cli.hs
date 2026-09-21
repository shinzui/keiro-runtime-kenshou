module Kenshou.Core.Cli
  ( CliEnv (..),
    CliGroup (..),
    CliCommand (..),
    HelpTopic (..),
    InputSource (..),
    parseInputSource,
    readInputSource,
    runCli,
    exitWithOutcome,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Kenshou.Core.Bundle (LayerBundle, Registry, mkRegistry)
import Kenshou.Core.Outcome (Outcome, outcomeExitCode)
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr, stdin, stdout)

data CliEnv = CliEnv {registry :: Registry, programName :: Text}

data CliGroup = Discovery | Execution | Analysis | Evidence | Maintenance | Internal deriving stock (Eq, Ord, Show, Enum, Bounded)

data CliCommand = CliCommand
  { name :: String,
    description :: String,
    group :: CliGroup,
    hidden :: Bool,
    parser :: Parser (CliEnv -> IO ExitCode)
  }

data HelpTopic = HelpTopic {name :: Text, description :: Text, content :: Text}

data InputSource = InputFile FilePath | InputStdin deriving stock (Eq, Show)

parseInputSource :: String -> InputSource
parseInputSource "-" = InputStdin
parseInputSource path = InputFile path

readInputSource :: InputSource -> IO ByteString
readInputSource InputStdin = ByteString.hGetContents stdin
readInputSource (InputFile path) = ByteString.readFile path

runCli :: [LayerBundle] -> [CliCommand] -> [HelpTopic] -> [String] -> IO ExitCode
runCli bundles commands _ arguments = case mkRegistry bundles of
  Left problems -> do
    mapM_ (hPutStrLn stderr . show) (NonEmpty.toList problems)
    pure (ExitFailure 4)
  Right registry -> case execParserPure defaultPrefs (parserInfo commands) arguments of
    Success action -> action (CliEnv registry "kenshou")
    Failure failure -> do
      let (message, code) = renderFailure failure "kenshou"
      case code of
        ExitSuccess -> hPutStrLn stdout message >> pure ExitSuccess
        ExitFailure _ -> hPutStrLn stderr message >> pure (ExitFailure 2)
    CompletionInvoked completion -> execCompletion completion "kenshou" >>= putStr >> pure ExitSuccess

parserInfo :: [CliCommand] -> ParserInfo (CliEnv -> IO ExitCode)
parserInfo commands = info (commandParser commands <**> helper) (fullDesc <> header "kenshou - verify the Keiro runtime")

commandParser :: [CliCommand] -> Parser (CliEnv -> IO ExitCode)
commandParser commands = foldr1 (<|>) (fmap groupParser populatedGroups)
  where
    populatedGroups = filter (not . null . commandsIn) [Discovery .. Internal]
    commandsIn groupValue = filter ((== groupValue) . (.group)) commands
    groupParser groupValue = subparser (groupModifier groupValue <> foldMap commandModifier (commandsIn groupValue))
    groupModifier Internal = mempty
    groupModifier groupValue = commandGroup (groupLabel groupValue)
    commandModifier commandValue =
      command commandValue.name (info commandValue.parser (progDesc commandValue.description))
        <> if commandValue.hidden then hidden else mempty

groupLabel :: CliGroup -> String
groupLabel Discovery = "Discovery"
groupLabel Execution = "Execution"
groupLabel Analysis = "Analysis"
groupLabel Evidence = "Evidence"
groupLabel Maintenance = "Maintenance"
groupLabel Internal = "Internal"

exitWithOutcome :: Outcome -> ExitCode
exitWithOutcome outcome = case outcomeExitCode outcome of
  0 -> ExitSuccess
  code -> ExitFailure code
