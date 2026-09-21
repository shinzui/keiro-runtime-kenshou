module Kenshou.Measure.CompareSpec (spec) where

import Data.Aeson (Value (Null))
import Data.ByteString.Char8 qualified as ByteString
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Measure.Compare
import Kenshou.Measure.Compare.Ordering
import Kenshou.Measure.Compare.Policy
import Kenshou.Measure.Health
import Kenshou.Measure.Stats
import Test.Hspec

spec :: Spec
spec = do
  describe "pairedSchedule" do
    it "assigns one shared seed to each pair in ABBA order" do
      let schedule = pairedSchedule ABBA 3 17
      fmap (.arm) schedule `shouldBe` [Baseline, Candidate, Candidate, Baseline, Baseline, Candidate]
      fmap (.pairIndex) schedule `shouldBe` [0, 0, 1, 1, 2, 2]
      fmap (.pairSeed) schedule `shouldSatisfy` pairSeedsMatch

  describe "statistics" do
    it "interpolates exact quantiles" do
      exactQuantile 0.25 [10, 0] `shouldBe` 2.5

    it "repeats bootstrap intervals exactly for a fixed seed" do
      let interval = bootstrapInterval 41 1_000 0.95 arithmeticMean [1, 2, 3, 4]
      bootstrapInterval 41 1_000 0.95 arithmeticMean [1, 2, 3, 4] `shouldBe` interval

  describe "comparison policy" do
    it "rejects fewer than three pairs" do
      decodePolicy (policyJson 2 1_000) `shouldSatisfy` isLeft

    it "rejects fewer than one thousand bootstrap iterations" do
      decodePolicy (policyJson 3 999) `shouldSatisfy` isLeft

    it "accepts the minimum supported policy" do
      decodePolicy (policyJson 3 1_000) `shouldSatisfy` isRight

  describe "paired metric classification" do
    it "reports a clear regression only after both gates are exceeded" do
      let result = compareMetricPairs testPolicy "latency" "ns" latencyRule [(100, 130), (100, 130), (100, 130)]
      result.status `shouldBe` MetricRegression

    it "passes stable identical measurements" do
      let result = compareMetricPairs testPolicy "latency" "ns" latencyRule [(100, 100), (101, 101), (99, 99)]
      result.status `shouldBe` MetricPass

    it "reports noisy mixed measurements as inconclusive" do
      let result = compareMetricPairs testPolicy "latency" "ns" latencyRule [(100, 140), (100, 60), (100, 100)]
      result.status `shouldBe` MetricInconclusive

    it "lets a hard health observation override a statistical regression" do
      decideVerdict True [] [MetricRegression] `shouldBe` VerdictInfrastructureFailure

    it "lets checkpoint asymmetry make a statistical regression inconclusive" do
      decideVerdict False ["checkpoint overlap differs"] [MetricRegression] `shouldBe` VerdictInconclusive

  describe "health outcomes" do
    it "maps soft observations to inconclusive and hard observations to infrastructure failure" do
      healthOutcome [health Soft] `shouldBe` Just Inconclusive
      healthOutcome [health Hard] `shouldBe` Just InfrastructureFailure

pairSeedsMatch :: (Eq a) => [a] -> Bool
pairSeedsMatch [firstA, firstB, secondA, secondB, thirdA, thirdB] = firstA == firstB && secondA == secondB && thirdA == thirdB
pairSeedsMatch _ = False

testPolicy :: Policy
testPolicy = Policy "test" 3 0.95 1_000 42 False "benchmark" 0.5 1 []

latencyRule :: MetricRule
latencyRule = MetricRule "latency" LowerIsBetter 0.1 5

health :: Severity -> HealthObservation
health severity = HealthObservation "test" severity 0 1 "test observation" Null

policyJson :: Int -> Int -> ByteString.ByteString
policyJson pairs iterations =
  ByteString.pack
    ( concat
        [ "{\"schema\":\"kenshou.comparison-policy/v1\",\"name\":\"test\",\"minimumPairs\":",
          show pairs,
          ",\"confidenceLevel\":0.95,\"bootstrapIterations\":",
          show iterations,
          ",\"resamplingSeed\":1,\"requireInterleaving\":false,\"requireGrade\":\"benchmark\",\"maxCiRelativeWidth\":0.5,\"maxCheckpointAsymmetry\":1,\"metrics\":[]}"
        ]
    )

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isRight :: Either left right -> Bool
isRight = not . isLeft
