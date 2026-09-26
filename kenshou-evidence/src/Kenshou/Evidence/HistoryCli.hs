module Kenshou.Evidence.HistoryCli (historyCommand) where

import Data.Aeson (Value (String), encode)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (Day, defaultTimeLocale, parseTimeM)
import Kenshou.Core.Cli (CliCommand (..), CliEnv, CliGroup (Analysis))
import Kenshou.Core.Cli.Config (ConfigInputs (..), configInputsParser)
import Kenshou.Core.Id (ScenarioId, parseScenarioId)
import Kenshou.Core.Outcome (Outcome)
import Kenshou.Evidence.Config (EvidenceDefaults (..), bundleRootKey, evidenceConfig, resolveEvidenceDefaults)
import Kenshou.Evidence.History (HistoryDocument (..), HistoryEntry (..), HistoryError (..), HistoryQuery (..), history)
import Options.Applicative
import Settei (ResolveResult (..), describe, renderErrorsText)
import Settei.Env (envSnapshot)
import Settei.Optparse (namedOption, resolutionDiagnostic, schemaDiagnostic)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (stderr)

data HistoryCli = HistoryCli
  { config :: !ConfigInputs,
    scenario :: !ScenarioId,
    cohortComponent :: !(Maybe (Text, Maybe Text)),
    outcomes :: ![Outcome],
    since :: !(Maybe Day),
    confirmedOnly :: !Bool,
    json :: !Bool
  }

historyCommand :: CliCommand
historyCommand = CliCommand "history" "Read verification evidence for a scenario" Analysis False (historyHandler <$> historyParser)

historyParser :: Parser HistoryCli
historyParser =
  HistoryCli
    <$> configInputsParser
      ((: []) <$> namedOption "--bundle" bundleRootKey (long "bundle" <> metavar "DIR" <> help "OKF evidence bundle"))
    <*> parserOptionGroup "Scenario filters" (option (eitherReader (either (Left . Text.unpack) Right . parseScenarioId . Text.pack)) (long "scenario" <> metavar "SCENARIO" <> help "Scenario identifier"))
    <*> parserOptionGroup "Scenario filters" (optional (option (eitherReader parseComponent) (long "cohort-component" <> metavar "PACKAGE[=VERSION|REVISION]" <> help "Require a runtime cohort package")))
    <*> parserOptionGroup "Scenario filters" (many (option (eitherReader parseOutcome) (long "outcome" <> metavar "OUTCOME" <> help "Include this outcome; may repeat")))
    <*> parserOptionGroup "Scenario filters" (optional (option (eitherReader parseDay) (long "since" <> metavar "YYYY-MM-DD" <> help "Include records from this UTC day")))
    <*> parserOptionGroup "Trust filters" (switch (long "confirmed-only" <> help "Include machine-confirmed or human-reviewed records"))
    <*> parserOptionGroup "Output" (switch (long "json" <> help "Emit kenshou.evidence-history/v1 JSON"))

historyHandler :: HistoryCli -> CliEnv -> IO ExitCode
historyHandler options _
  | Just output <- schemaDiagnostic options.config.diagnostic (describe evidenceConfig) = Text.IO.putStr output >> pure ExitSuccess
  | otherwise = do
      processEnvironment <- fmap (fmap (\(name, setting) -> (Text.pack name, Text.pack setting))) getEnvironment
      resolved <- resolveEvidenceDefaults (envSnapshot processEnvironment) options.config
      case resolved of
        Left message -> failure message
        Right result -> case result.answer of
          Left problems -> failure (renderErrorsText problems)
          Right defaults -> case resolutionDiagnostic options.config.diagnostic result of
            Just output -> Text.IO.putStr output >> pure ExitSuccess
            Nothing -> do
              let query = HistoryQuery options.scenario options.cohortComponent options.outcomes options.since options.confirmedOnly
              observed <- history (Text.unpack defaults.bundleRoot) query
              case observed of
                Left (HistoryError message) -> failure message
                Right document -> do
                  if options.json
                    then LazyByteString.putStrLn (encode document)
                    else mapM_ (\entry -> Text.IO.putStrLn (entry.concept <> "  " <> entry.outcome <> "  " <> entry.trust)) document.entries
                  pure ExitSuccess
  where
    failure message = Text.IO.hPutStrLn stderr ("kenshou history: " <> message) >> pure (ExitFailure 4)

parseComponent :: String -> Either String (Text, Maybe Text)
parseComponent raw = case break (== '=') raw of
  ([], _) -> Left "cohort component package cannot be empty"
  (_, "=") -> Left "cohort component version or revision cannot be empty"
  (name, '=' : revision) -> Right (Text.pack name, Just (Text.pack revision))
  (name, _) -> Right (Text.pack name, Nothing)

parseOutcome :: String -> Either String Outcome
parseOutcome raw = case Aeson.fromJSON (String (Text.pack raw)) of
  Aeson.Success outcome -> Right outcome
  Aeson.Error message -> Left message

parseDay :: String -> Either String Day
parseDay raw = maybe (Left "day must be YYYY-MM-DD") Right (parseTimeM True defaultTimeLocale "%Y-%m-%d" raw)
