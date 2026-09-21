module Kenshou.Cli.Main (main, runWithArgs) where

import Data.Text.IO qualified as Text.IO
import Kenshou.Cli.Registry (bundles, commands, topics)
import Kenshou.Cli.Version (appVersionWithGit)
import Kenshou.Core.Cli (runCli)
import Kenshou.Diagnose.Profile.EventlogGuard (withEventlogGuard)
import Kenshou.Diagnose.Profile.GhcDebug (withGhcDebugIfRequested)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)

main :: IO ()
main = withGhcDebugIfRequested (withEventlogGuard (getArgs >>= runWithArgs >>= exitWith))

runWithArgs :: [String] -> IO ExitCode
runWithArgs ["--version"] = Text.IO.putStrLn appVersionWithGit >> pure ExitSuccess
runWithArgs arguments = runCli bundles commands topics arguments
