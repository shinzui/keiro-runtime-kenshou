module Kenshou.Cli.Options
  ( Command (..),
    CohortCommand (..),
    commandParserInfo,
    cohortCommandParser,
  )
where

import Data.Text qualified as Text
import Kenshou.Cli.Version (appVersionWithGit)
import Options.Applicative
  ( Parser,
    ParserInfo,
    command,
    fullDesc,
    header,
    help,
    helper,
    info,
    infoOption,
    long,
    metavar,
    optional,
    progDesc,
    strOption,
    subparser,
    switch,
    value,
    (<**>),
  )

data Command = CohortCommand CohortCommand
  deriving stock (Eq, Show)

data CohortCommand
  = CohortShow Bool FilePath (Maybe FilePath) (Maybe FilePath)
  | CohortCheck FilePath (Maybe FilePath) (Maybe FilePath)
  deriving stock (Eq, Show)

commandParserInfo :: ParserInfo Command
commandParserInfo =
  info
    (commandParser <**> helper <**> versionOption)
    (fullDesc <> header "kenshou - verify the Keiro runtime")
  where
    versionOption = infoOption (Text.unpack appVersionWithGit) (long "version" <> help "Show version")

commandParser :: Parser Command
commandParser = CohortCommand <$> subparser (command "cohort" (info cohortCommandParser (progDesc "Inspect the pinned runtime cohort")))

cohortCommandParser :: Parser CohortCommand
cohortCommandParser =
  subparser
    ( command "show" (info showParser (progDesc "Print the cohort resolved by cabal"))
        <> command "check" (info checkParser (progDesc "Check the resolved cohort against its descriptor"))
    )
  where
    showParser =
      CohortShow
        <$> switch (long "json" <> help "Write kenshou.cohort-identity/v1 JSON")
        <*> projectDirOption
        <*> optional planJsonOption
        <*> optional identityOption
    checkParser = CohortCheck <$> projectDirOption <*> optional planJsonOption <*> optional descriptorOption

projectDirOption :: Parser FilePath
projectDirOption = strOption (long "project-dir" <> metavar "DIR" <> value "." <> help "Cabal project directory")

planJsonOption :: Parser FilePath
planJsonOption = strOption (long "plan-json" <> metavar "FILE" <> help "Override dist-newstyle/cache/plan.json")

identityOption :: Parser FilePath
identityOption = strOption (long "identity" <> metavar "FILE" <> help "Read a captured cohort identity instead of a cabal plan")

descriptorOption :: Parser FilePath
descriptorOption = strOption (long "descriptor" <> metavar "FILE" <> help "Override the active cohort descriptor")
