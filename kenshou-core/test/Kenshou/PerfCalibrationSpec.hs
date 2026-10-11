module Kenshou.PerfCalibrationSpec (spec) where

import Data.Aeson
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kenshou.Core.Id (newRunId)
import Kenshou.Perf.Calibration
import Test.Hspec

spec :: Spec
spec = describe "performance calibration admission" do
  it "accepts twenty independently replayed slots and preserves frozen protocol roundtrips" do
    (definition, acceptance, aa, slowdown) <- fixture
    validateCalibration now now definition acceptance aa slowdown `shouldBe` Right 90
    eitherDecode (encode definition) `shouldBe` Right definition
    eitherDecode (encode acceptance) `shouldBe` Right acceptance
  it "never drops a completed statistical outcome to replace it with a better result" do
    (definition, acceptance, aa, slowdown) <- fixture
    replacementId <- newRunId
    let slot = first acceptance.aa
        replaced = slot {receipts = slot.receipts <> [CalibrationReceipt "gs://fixture/replacement/receipt.json" "sha256:replacement"]}
        statisticalRetry = first aa <> [(first (first aa)) {sessionId = replacementId}]
    validateCalibration now now definition acceptance {aa = replaced : drop 1 acceptance.aa} (statisticalRetry : drop 1 aa) slowdown `shouldSatisfy` isLeft
  it "requires at least nineteen expected outcomes and zero opposite outcomes" do
    (definition, acceptance, aa, slowdown) <- fixture
    let change verdict = map (\trial -> trial {verdict})
    validateCalibration now now definition acceptance (change "inconclusive" (first aa) : drop 1 aa) slowdown `shouldBe` Right 90
    validateCalibration now now definition acceptance (change "regression" (first aa) : drop 1 aa) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance aa (change "pass" (first slowdown) : drop 1 slowdown) `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (map (change "inconclusive") (take 2 aa) <> drop 2 aa) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (change "not-run" (first aa) : drop 1 aa) slowdown `shouldSatisfy` isLeft
  it "invalidates expired, drifted, duplicate, missing and runtime-blocked batches" do
    (definition, acceptance, aa, slowdown) <- fixture
    validateCalibration (addUTCTime 3601 now) now definition acceptance aa slowdown `shouldSatisfy` isLeft
    validateCalibration now (addUTCTime 1 now) definition acceptance aa slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (drop 1 aa) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (first aa : first aa : drop 2 aa) slowdown `shouldSatisfy` isLeft
    let corrupt :: (VerifiedCalibrationTrial -> VerifiedCalibrationTrial) -> [[VerifiedCalibrationTrial]]
        corrupt change = map change (first aa) : drop 1 aa
    validateCalibration now now definition acceptance (corrupt (\trial -> trial {trialMachineProfile = "different-cell-image"})) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (corrupt (\trial -> trial {trialToolchainSha256 = "changed"})) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (corrupt (\trial -> trial {trialHarnessSemanticsSha256 = "changed"})) slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition acceptance (corrupt (\trial -> trial {runtimeBlockers = ["known exit-zero defect"]})) slowdown `shouldSatisfy` isLeft
  it "retains infrastructure retries under the frozen cap and includes their time" do
    (definition, acceptance, aa, slowdown) <- fixture
    extra <- newRunId
    let failed = (first (first aa)) {sessionId = extra, infrastructureState = "failed", verdict = "not-run", elapsedSeconds = 850}
        original = first acceptance.aa
        slot = original {receipts = CalibrationReceipt "gs://fixture/failed/receipt.json" "sha256:failed" : original.receipts}
        revised = acceptance {aa = slot : drop 1 acceptance.aa}
        trials = (failed : first aa) : drop 1 aa
    validateCalibration now now definition {infrastructureRetryCap = 0} revised trials slowdown `shouldSatisfy` isLeft
    validateCalibration now now definition revised trials slowdown `shouldBe` Right 90
    let late = map (map (\trial -> trial {elapsedSeconds = 901})) aa
    validateCalibration now now definition acceptance late slowdown `shouldSatisfy` isLeft

fixture :: IO (CalibrationDefinition, CalibrationAcceptance, [[VerifiedCalibrationTrial]], [[VerifiedCalibrationTrial]])
fixture = do
  identifier <- newRunId
  let seeds = [1 .. 20]
      definition = CalibrationDefinition identifier "mori://fixture/runtime" "core" "synthetic-machine" (digest "a") (digest "b") (digest "c") (Text.replicate 40 "a") (Text.replicate 40 "b") "delay at operation boundary" "op.latency.p99" 0.5 1000000 seeds 1 (addUTCTime 3600 now)
      slot control seed = CalibrationSlot seed [CalibrationReceipt ("gs://fixture/" <> control <> "/" <> Text.pack (show seed) <> "/receipt.json") "sha256:receipt"]
      acceptance = CalibrationAcceptance identifier (map (slot "aa") seeds) (map (slot "slowdown") seeds)
      trial control verdict seed = do
        session <- newRunId
        pure [VerifiedCalibrationTrial session seed control definition.project definition.baselineRevision (if control == "aa" then definition.baselineRevision else definition.slowdownRevision) definition.profile definition.machineProfile definition.workloadSha256 definition.toolchainSha256 definition.harnessSemanticsSha256 verdict "healthy" [] now 90]
  aa <- traverse (trial "aa" "pass") seeds
  slowdown <- traverse (trial "none" "regression") seeds
  pure (definition, acceptance, aa, slowdown)
  where
    digest letter = "sha256:" <> Text.replicate 64 letter

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 11) (secondsToDiffTime 0)

first :: [a] -> a
first (value : _) = value
first [] = error "empty synthetic calibration fixture"
