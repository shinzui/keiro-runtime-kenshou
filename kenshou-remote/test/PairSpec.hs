module PairSpec (pairSpec) where

import Data.Aeson (Value, eitherDecodeFileStrict', toJSON)
import Data.List (nub)
import Data.Text qualified as Text
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Measure.Compare.Ordering (Arm (..), PairedOrdering (..))
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..), TrialInfo (..))
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Pair (PairRequest (..), PairState (..), SliceResult (..), judgePairs, pairPlan)
import Test.Hspec

pairSpec :: Spec
pairSpec = describe "cell paired schedule" do
  it "interleaves fresh same-seed benchmark arms and reserves replacement pairs" do
    source <- fixture
    let request = PairRequest "candidate" "baseline" 3 ABBA 7 1
    paired <- case pairPlan request source of
      Left problem -> expectationFailure (Text.unpack problem) >> error "unreachable"
      Right result -> pure result
    length paired.runs `shouldBe` 8
    paired.estimateMinutes `shouldBe` 8
    fmap (fmap (.arm) . (.trial)) paired.runs `shouldBe` fmap Just ["baseline", "candidate", "candidate", "baseline", "baseline", "candidate", "candidate", "baseline"]
    length (nub (fmap (.runId) paired.runs)) `shouldBe` 8
    fmap (.spec.seed) (take 2 paired.runs) `shouldSatisfy` \case [Just first, Just second] -> first == second; _ -> False
    fmap (.spec.seed) (take 2 (drop 2 paired.runs)) `shouldSatisfy` \case [Just first, Just second] -> first == second; _ -> False
    fmap (.comparison) (fmap (.spec) paired.runs) `shouldSatisfy` all (/= Nothing)
    pairPlan request source `shouldBe` Right paired
    decodeWorkPlan (toJSON paired) `shouldBe` Right paired

  it "keeps one failed arm out of a valid pair" do
    let result index arm passed = SliceResult "group" index arm passed
    judgePairs [result 0 Baseline True, result 0 Candidate True, result 1 Candidate False, result 1 Baseline True]
      `shouldBe` [(("group", 0), PairValid), (("group", 1), PairInvalid "one or both cell trials failed or are missing")]

  it "rejects a correctness plan or fewer than three pairs" do
    source <- sourceFixture
    pairPlan (PairRequest "candidate" "baseline" 3 ABBA 7 0) source `shouldBe` Left "paired comparisons require benchmark runs only"
    benchmark <- fixture
    pairPlan (PairRequest "candidate" "baseline" 2 ABBA 7 0) benchmark `shouldBe` Left "paired comparisons need at least three pairs"

fixture :: IO RunPlan
fixture = do
  source <- sourceFixture
  scenario <- case parseScenarioId "selftest/measure/benchmark/sleep-service" of
    Left problem -> expectationFailure (Text.unpack problem) >> error "unreachable"
    Right identifier -> pure identifier
  pure source {runs = [entry {spec = entry.spec {scenario = scenario}} | entry <- source.runs]}

sourceFixture :: IO RunPlan
sourceFixture = do
  decoded <- eitherDecodeFileStrict' "../kenshou-core/test/golden/run-plan.minimal.json" :: IO (Either String Value)
  document <- case decoded of
    Left problem -> expectationFailure problem >> error "unreachable"
    Right value -> pure value
  case decodeWorkPlan document of
    Left problem -> expectationFailure (Text.unpack problem) >> error "unreachable"
    Right plan -> pure plan
