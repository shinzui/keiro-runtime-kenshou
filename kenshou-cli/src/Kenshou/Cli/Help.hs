{-# LANGUAGE TemplateHaskell #-}

module Kenshou.Cli.Help (helpCommand, topics) where

import Data.FileEmbed (embedStringFile)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Cli.Help.Width (renderForWidth, resolveWidth)
import Kenshou.Core.Cli (CliCommand (..), CliGroup (..), HelpTopic (..))
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (stderr)

topics :: [HelpTopic]
topics =
  [ HelpTopic "scenarios" "Scenario identifiers and metadata" (Text.pack $(embedStringFile "help/scenarios.md")),
    HelpTopic "selectors" "Selecting groups of scenarios" (Text.pack $(embedStringFile "help/selectors.md")),
    HelpTopic "run-specs" "Versioned run specification documents" (Text.pack $(embedStringFile "help/run-specs.md")),
    HelpTopic "planning" "Change-aware plans, suites, and safe resume" (Text.pack $(embedStringFile "help/planning.md")),
    HelpTopic "outcomes" "Run outcomes and known defects" (Text.pack $(embedStringFile "help/outcomes.md")),
    HelpTopic "exit-codes" "Stable process exit codes" (Text.pack $(embedStringFile "help/exit-codes.md"))
  ]

data HelpOptions = HelpOptions {topic :: Maybe Text, width :: Maybe Int}

helpCommand :: CliCommand
helpCommand =
  CliCommand
    { name = "help",
      description = "Read a long-form help topic",
      group = Discovery,
      hidden = False,
      parser = runHelp <$> helpParser
    }

helpParser :: Parser HelpOptions
helpParser =
  HelpOptions
    <$> optional (Text.pack <$> strArgument (metavar "TOPIC" <> help "Topic name"))
    <*> optional (option auto (long "width" <> metavar "COLUMNS" <> help "Wrap prose to this width"))

runHelp :: HelpOptions -> environment -> IO ExitCode
runHelp options _ = case options.topic of
  Nothing -> Text.IO.putStr (Text.unlines [topic.name <> "  " <> topic.description | topic <- topics]) >> pure ExitSuccess
  Just wanted -> case filter ((== Text.toCaseFold wanted) . Text.toCaseFold . (.name)) topics of
    [] -> Text.IO.hPutStrLn stderr ("kenshou: unknown help topic \"" <> wanted <> "\"") >> pure (ExitFailure 2)
    topic : _ -> do
      width <- resolveWidth options.width
      Text.IO.putStr (renderForWidth width topic.content)
      pure ExitSuccess
