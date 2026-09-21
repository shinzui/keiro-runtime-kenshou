module Kenshou.Cli.Main (main, runWithArgs) where

import Data.Text.IO qualified as Text.IO
import Kenshou.Cli.Registry (bundles, commands, topics)
import Kenshou.Cli.Version (appVersionWithGit)
import Kenshou.Core.Cli (runCli)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)

main :: IO ()
main = getArgs >>= runWithArgs >>= exitWith

runWithArgs :: [String] -> IO ExitCode
runWithArgs ["--version"] = Text.IO.putStrLn appVersionWithGit >> pure ExitSuccess
runWithArgs arguments = runCli bundles commands topics arguments
