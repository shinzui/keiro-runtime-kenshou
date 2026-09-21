module Kenshou.Cli.Command.Worker (workerCommand) where

import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Kenshou.Core.Cli (CliCommand (..), CliEnv (..), CliGroup (..))
import Kenshou.Core.Role (mkRoleName, renderRoleName)
import Kenshou.Core.Role.Dispatch (runWorker)
import Kenshou.Diagnose.Threads (installThreadDumpSignal)
import Options.Applicative

workerCommand :: CliCommand
workerCommand = CliCommand "worker" "Run an internal worker role" Execution True (uncurry handler <$> parser)
  where
    parser = (,) <$> option (eitherReader (first Text.unpack . mkRoleName . Text.pack)) (long "role" <> metavar "ROLE") <*> optional (strOption (long "diagnosis-root" <> metavar "DIR" <> internal))
    handler role diagnosisRoot environment = do
      traverse_ (\root -> installThreadDumpSignal root (renderRoleName role)) diagnosisRoot
      runWorker environment.registry role
