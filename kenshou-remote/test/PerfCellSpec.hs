module PerfCellSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import FetchSpec (completeTreeWithNested)
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Perf.Plan
import Kenshou.Plan.RunPlan qualified as Plan
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (Completed), WorkObject (..))
import Kenshou.Remote.Cell.Docs qualified as Submission (Submission (..))
import Kenshou.Remote.Cell.Session.Journal
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Perf.Cell
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance sealed runtime observations" do
  it "retains an exit-zero runtime defect even before the outer trial becomes admissible" $ withSystemTempDirectory "perf-cell-defect" \root -> do
    plan <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-plan.json" >>= either fail pure
    entry <- case (plan :: PerfPlan).selected of first : _ -> pure first; _ -> fail "empty plan fixture"
    journal <- eitherDecodeFileStrict' "test/golden/cell-session.json" >>= either fail pure
    slice <- case (journal :: SessionJournal).slices of [first] -> pure first; _ -> fail "expected one slice"
    identifier <- newRunId
    cellRun <- newRunId
    schedule <- either (fail . Text.unpack) pure (decodeWorkPlan (object ["schema" .= ("kenshou.run-plan/v1" :: Text.Text), "planId" .= identifier, "runs" .= [object ["ordinal" .= (1 :: Int), "runId" .= identifier, "estimateMinutes" .= (1 :: Int), "spec" .= object ["schema" .= ("kenshou.run-spec/v1" :: Text.Text), "runId" .= identifier, "scenario" .= entry.profile.scenario]]]]))
    run <- case schedule.runs of [first] -> pure first; _ -> fail "expected one run"
    (tree, outer) <- completeTreeWithNested (root </> "trials" </> Text.unpack (renderRunId cellRun)) cellRun journal.leaseId identifier False False False
    let nested = tree </> "output" </> Text.unpack (renderRunId identifier)
    original <- eitherDecodeFileStrict' (nested </> "run-result.json") >>= either fail pure
    case original of
      Object fields -> encodeFile (nested </> "run-result.json") (Object (KeyMap.insert "outcome" (String "failed") (KeyMap.insert "exitCode" (Number 0) (KeyMap.insert "blocking" (Bool False) fields))))
      _ -> fail "expected a result object"
    manifest <- writeManifest nested identifier Map.empty
    encodeFile (nested </> "manifest.json") manifest
    artifacts <-
      traverse
        ( \artifact -> do
            bytes <- Lazy.readFile (tree </> Text.unpack artifact.path)
            let work = workObjectFor "application/json" bytes
            pure (Artifact artifact.path work.sha256 work.bytes artifact.mediaType)
        )
        outer.artifacts
    let updated = outer {artifacts}
    encodeFile (tree </> "manifest.json") updated
    bytes <- Lazy.readFile (tree </> "manifest.json")
    let retained = journal {slices = [slice {cellRun, runIds = [identifier], submission = slice.submission {Submission.runId = cellRun}, state = SliceFetched, cellOutcome = Just Completed, manifestSha256 = Just (workObjectFor "application/json" bytes).sha256, fetchedPath = Just "tree"}]}
        trial = root </> "trials" </> Text.unpack (renderRunId identifier)
    problems <- retainedRuntimeProblems entry.profile (run :: Plan.PlannedRun) trial retained
    List.nub problems `shouldBe` ["runtime assertions failed (including nonblocking known defects)"]
