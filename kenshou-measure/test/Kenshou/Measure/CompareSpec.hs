module Kenshou.Measure.CompareSpec (spec) where

import Data.Aeson (Value (Null), encode, object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Measure.Compare
import Kenshou.Measure.Compare.Compatibility
import Kenshou.Measure.Compare.Ordering
import Kenshou.Measure.Compare.Policy
import Kenshou.Measure.Health
import Kenshou.Measure.Stats
import Kenshou.Measure.Summary (MeasurementSummary (..), SummaryWindow (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "comparison source references" do
    it "retains the baseline and candidate run IDs in pair order" do
      withSystemTempDirectory "kenshou-comparison-arms" $ \root -> do
        let baselineIds = ["baseline-1", "baseline-2", "baseline-3"] :: [Text]
            candidateIds = ["candidate-1", "candidate-2", "candidate-3"] :: [Text]
            baselineDirs = [root </> show index </> "baseline" | index <- [1 :: Int .. 3]]
            candidateDirs = [root </> show index </> "candidate" | index <- [1 :: Int .. 3]]
        sequence_ [writeRun dir runId "released" | (dir, runId) <- zip baselineDirs baselineIds]
        sequence_ [writeRun dir runId "head" | (dir, runId) <- zip candidateDirs candidateIds]
        compared <- compareRuns testPolicy (VaryCohort :| []) baselineDirs candidateDirs
        case compared of
          Left err -> expectationFailure (show err)
          Right result -> do
            result.baselineRuns `shouldBe` baselineIds
            result.candidateRuns `shouldBe` candidateIds

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
    it "parses the explicit A/A control axis" do
      parseVaryingAxis "control" `shouldBe` Right VaryControl

    it "rejects fewer than three pairs" do
      decodePolicy (policyJson 2 1_000) `shouldSatisfy` isLeft

    it "rejects fewer than one thousand bootstrap iterations" do
      decodePolicy (policyJson 3 999) `shouldSatisfy` isLeft

    it "accepts the minimum supported policy" do
      decodePolicy (policyJson 3 1_000) `shouldSatisfy` isRight

  describe "paired metric classification" do
    it "keeps a clear regression when another metric is inconclusive" do
      decideVerdict False [] [MetricRegression, MetricInconclusive] `shouldBe` VerdictRegression

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

writeRun :: FilePath -> Text -> Text -> IO ()
writeRun directory runId cohort = do
  createDirectoryIfMissing True directory
  let summary = MeasurementSummary "benchmark" [] (SummaryWindow 0 1 1) Map.empty Map.empty []
      document =
        object
          [ "runId" .= runId,
            "outcome" .= ("passed" :: Text),
            "compatibility" .= object ["inputs" .= object ["cohortPlanHash" .= cohort]],
            "fingerprint" .= object ["host" .= object ["os" .= ("darwin" :: Text)]],
            "summaries" .= object ["measurements" .= object ["measurements" .= summary]]
          ]
  LazyByteString.writeFile (directory </> "run-result.json") (encode document)

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isRight :: Either left right -> Bool
isRight = not . isLeft
