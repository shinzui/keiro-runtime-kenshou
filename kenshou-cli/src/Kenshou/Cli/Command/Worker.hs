module Kenshou.Cli.Command.Worker (workerCommand) where

import Data.Bifunctor (first)
import Data.Text qualified as Text
import Kenshou.Core.Cli (CliCommand (..), CliEnv (..), CliGroup (..))
import Kenshou.Core.Role (mkRoleName)
import Kenshou.Core.Role.Dispatch (runWorker)
import Options.Applicative

workerCommand :: CliCommand
workerCommand = CliCommand "worker" "Run an internal worker role" Execution True (handler <$> parser)
  where
    parser = option (eitherReader (first Text.unpack . mkRoleName . Text.pack)) (long "role" <> metavar "ROLE")
    handler role environment = runWorker environment.registry role
