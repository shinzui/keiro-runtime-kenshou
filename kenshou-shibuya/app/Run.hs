module Main (main) where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Bundle (mkRegistry)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort (identityFromPlan, loadCohortDescriptor)
import Kenshou.Core.Outcome (renderOutcome)
import Kenshou.Core.Run (RunOutput (..), RunnerConfig (..), executeRun)
import Kenshou.Core.RunResult (RunResult (..))
import Kenshou.Core.RunSpec (RunSpec)
import Kenshou.Suite.Shibuya (bundle)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["run", specPath, outRoot] -> runCurrent arguments specPath outRoot
    _ -> do
      hPutStrLn stderr "usage: kenshou-shibuya-run run RUN-SPEC.json OUT-DIR"
      exitWith (ExitFailure 2)

-- The isolated Cabal project omits the full CLI because Keiro still bounds
-- Shibuya below 0.10. This executable runs the same kernel against its plan.
runCurrent :: [String] -> FilePath -> FilePath -> IO ()
runCurrent arguments specPath outRoot = do
  let descriptorPath = "cohort/shibuya-current.json"
      planPath = "dist-newstyle/cache/plan.json"
  descriptorBytes <- ByteString.readFile descriptorPath
  descriptor <- loadCohortDescriptor descriptorPath >>= either (fail . show) pure
  planBytes <- ByteString.readFile planPath
  plan <- either (fail . ("Cabal plan: " <>)) pure (eitherDecodeStrict' planBytes)
  identity <- either (fail . show) pure (identityFromPlan descriptor (sha256Hex descriptorBytes) plan)
  specification <- ByteString.readFile specPath >>= either (fail . ("run spec: " <>)) pure . eitherDecodeStrict' @RunSpec
  registry <- either (fail . show . NonEmpty.toList) pure (mkRegistry [bundle])
  output <- executeRun (RunnerConfig registry outRoot identity Nothing False False arguments) specification
  case output of
    Left problems -> fail (show (NonEmpty.toList problems))
    Right result -> do
      Text.IO.putStrLn (renderOutcome result.result.outcome <> "  " <> Text.pack result.directory)
      exitWith (if result.result.exitCode == 0 then ExitSuccess else ExitFailure result.result.exitCode)
