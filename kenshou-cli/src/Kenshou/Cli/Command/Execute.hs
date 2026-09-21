{-# LANGUAGE FieldSelectors #-}

module Kenshou.Cli.Command.Execute (executeCommand) where

import Control.Exception (IOException, displayException, try)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Cli
import Kenshou.Plan.Execute
import Kenshou.Plan.Summary
import Options.Applicative
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

data ExecuteCliOptions = ExecuteCliOptions
  { planSource :: InputSource,
    outDir :: FilePath,
    resume :: Bool,
    failFast :: Bool,
    environmentSource :: Maybe InputSource,
    timeoutFactor :: Maybe Double
  }

executeCommand :: CliCommand
executeCommand = CliCommand "execute" "Execute or resume a run plan" Execution False (runExecute <$> executeParser)

executeParser :: Parser ExecuteCliOptions
executeParser =
  ExecuteCliOptions
    <$> option (parseInputSource <$> str) (long "plan" <> metavar "FILE" <> help "Read a kenshou.run-plan/v1 document; use - for stdin")
    <*> strOption (long "out" <> metavar "DIR" <> help "Execution output directory")
    <*> switch (long "resume" <> help "Resume the identical plan in an existing output directory")
    <*> switch (long "fail-fast" <> help "Stop after the first blocking failure")
    <*> optional (option (parseInputSource <$> str) (long "environment" <> metavar "FILE" <> help "Replace each run's environment object; use - for stdin"))
    <*> optional (option auto (long "timeout-factor" <> metavar "F" <> help "Limit runs to F times their estimate"))

runExecute :: ExecuteCliOptions -> CliEnv -> IO ExitCode
runExecute options _
  | stdinCount options > 1 = Text.IO.hPutStrLn stderr "kenshou: at most one document input may use standard input" >> pure (ExitFailure 2)
  | maybe False (<= 0) options.timeoutFactor = Text.IO.hPutStrLn stderr "kenshou: --timeout-factor must be positive" >> pure (ExitFailure 2)
  | otherwise = withSystemTempDirectory "kenshou-execute" \temporary -> do
      planFile <- materialize temporary "plan.json" options.planSource
      environment <- traverse (materialize temporary "environment.json") options.environmentSource
      let executeOptions = ExecuteOptions planFile options.outDir options.resume options.failFast environment options.timeoutFactor
      result <- try (executePlan executeOptions) :: IO (Either IOException PlanSummary)
      case result of
        Left err -> Text.IO.hPutStrLn stderr ("kenshou: " <> Text.pack (displayException err)) >> pure (ExitFailure 2)
        Right summary -> do
          Text.IO.putStrLn ("exit=" <> Text.pack (show summary.exitCode) <> " worst=" <> Text.pack (show summary.worst))
          pure (summaryExitCode summary)

materialize :: FilePath -> FilePath -> InputSource -> IO FilePath
materialize _ _ (InputFile path) = pure path
materialize directory name InputStdin = do
  bytes <- readInputSource InputStdin
  let path = directory </> name
  ByteString.writeFile path bytes
  pure path

stdinCount :: ExecuteCliOptions -> Int
stdinCount options = length [() | InputStdin <- options.planSource : maybe [] pure options.environmentSource]
