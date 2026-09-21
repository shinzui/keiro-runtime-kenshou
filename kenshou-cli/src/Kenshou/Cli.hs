module Kenshou.Cli
  ( main,
    runWithArgs,
  )
where

import Kenshou.Cli.Cohort (runCohortCommand)
import Kenshou.Cli.Options (Command (..), commandParserInfo)
import Options.Applicative
  ( ParserResult (..),
    defaultPrefs,
    execCompletion,
    execParserPure,
    renderFailure,
  )
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = getArgs >>= runWithArgs >>= exitWith

runWithArgs :: [String] -> IO ExitCode
runWithArgs arguments = case execParserPure defaultPrefs commandParserInfo arguments of
  Success (CohortCommand command) -> runCohortCommand command
  Failure failure -> do
    let (message, parserExit) = renderFailure failure "kenshou"
    case parserExit of
      ExitSuccess -> putStrLn message >> pure ExitSuccess
      ExitFailure _ -> hPutStrLn stderr message >> pure (ExitFailure 2)
  CompletionInvoked completion -> execCompletion completion "kenshou" >>= putStr >> pure ExitSuccess
