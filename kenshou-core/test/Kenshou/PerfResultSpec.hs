module Kenshou.PerfResultSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Text (Text)
import Kenshou.Perf.Plan
import Kenshou.Perf.Plan qualified as Plan
import Kenshou.Perf.Result
import Kenshou.Perf.Result qualified as Result
import Test.Hspec

spec :: Spec
spec = describe "performance aggregate results" do
  it "decodes the synthetic outcome fixtures with their distinct exit meanings" do
    let cases = [("pass", 0), ("incomplete", 3), ("runtime-failure", 1), ("regression", 1), ("inconclusive", 3), ("infrastructure-failure", 4), ("not-applicable", 0)]
    mapM_
      ( \(name, code) -> do
          result <- eitherDecodeFileStrict' ("test/golden/perf-result." <> name <> ".fixture.json") >>= either fail pure
          (result :: PerfResult).exitCode `shouldBe` code
      )
      cases
  it "keeps calibration passes non-gating and distinguishes requested from change scope" do
    plan <- fixture
    result <- accepted (aggregateResult plan digest True (map (configuration "pass") plan.selected))
    result.exitCode `shouldBe` 0
    result.gatingEligible `shouldBe` False
    result.purpose `shouldBe` "calibration"
    result.changeCoverage `shouldBe` plan.changeCoverage
    (eitherDecode (encode result) :: Either String PerfResult) `shouldBe` Right result
  it "uses 4 before 1 before 3 while preserving blockers and omissions" do
    plan <- fixture
    let (first, second) = twoProfiles plan
        blocker = (configuration "inconclusive" first) {runtimeFailures = ["known defect reproduced with exit zero"], comparison = Nothing}
        failure = (configuration "inconclusive" second) {infrastructureState = "failed", validPairs = 0, comparison = Nothing}
    result <- accepted (aggregateResult plan digest True [blocker, failure])
    result.exitCode `shouldBe` 4
    result.blockingRuntimeFailures `shouldBe` ["known defect reproduced with exit zero"]
    regression <- accepted (aggregateResult plan {Plan.coverage = "incomplete"} digest True [configuration "regression" first])
    regression.exitCode `shouldBe` 1
    regression.coverage `shouldBe` "incomplete"
    incomplete <- accepted (aggregateResult plan digest True [configuration "pass" first])
    incomplete.exitCode `shouldBe` 3
  it "does not turn an unresolved publication failure into success" do
    plan <- fixture
    result <- accepted (aggregateResult plan digest False (map (configuration "pass") plan.selected))
    result.exitCode `shouldBe` 4
    result.performanceVerdict `shouldBe` "inconclusive"
  it "keeps a statistical pass separate from a blocking runtime defect" do
    plan <- fixture
    let (first, second) = twoProfiles plan
        blocked = (configuration "pass" first) {runtimeFailures = ["known-defect-reproduced"]}
    result <- accepted (aggregateResult plan digest True [blocked, configuration "pass" second])
    result.performanceVerdict `shouldBe` "pass"
    result.exitCode `shouldBe` 1
    result.gatingEligible `shouldBe` False
  it "retains recovered invalid attempts without making healthy evidence fail" do
    plan <- fixture
    let results = [(configuration "pass" entry) {attempts = [object ["state" .= ("infrastructure-invalid" :: Text), "reason" .= ("reset failed" :: Text)]]} | entry <- plan.selected]
    result <- accepted (aggregateResult plan digest True results)
    result.exitCode `shouldBe` 0
  it "rejects a forged gate, missing pairs and inconsistent retained verdict" do
    plan <- fixture
    result <- accepted (aggregateResult plan digest True (map (configuration "pass") plan.selected))
    let first = fst (twoProfiles plan)
    validateResult result {Result.gatingEligible = True} `shouldSatisfy` isLeft
    aggregateResult plan digest True [(configuration "pass" first) {validPairs = 4}] `shouldSatisfy` isLeft
    aggregateResult plan digest True [(configuration "pass" first) {comparison = Just (comparisonValue "regression" 5)}] `shouldSatisfy` isLeft
  it "requires workload and pair counts from the pinned selection" do
    plan <- fixture
    let first = fst (twoProfiles plan)
    aggregateResult plan digest True [(configuration "pass" first) {Result.workloadSha256 = "sha256:" <> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}] `shouldSatisfy` isLeft
    aggregateResult plan digest True [(configuration "pass" first) {requiredPairs = 6, validPairs = 6, comparison = Just (comparisonValue "pass" 6)}] `shouldSatisfy` isLeft
  it "uses not-applicable only for a proved unexecuted scope" do
    plan <- fixture
    let noWork = plan {selected = [], coverage = "not-applicable", changeCoverage = "not-applicable", gatingEligible = False}
    result <- accepted (aggregateResult noWork digest True [])
    result.performanceVerdict `shouldBe` "not-applicable"
    result.exitCode `shouldBe` 0
    result.gatingEligible `shouldBe` False
  it "replays across analysis IDs, clocks and hosts but retains metric and evidence identity" do
    let core = object ["schema" .= ("kenshou.comparison/v1" :: Text), "design" .= ("abba" :: Text), "baselineRuns" .= ["run-a" :: Text], "candidateRuns" .= ["run-b" :: Text], "algorithm" .= object [], "policy" .= object [], "variedFactors" .= ["control" :: Text], "pairCount" .= (5 :: Int), "metrics" .= object ["latency" .= (10 :: Int)], "reasons" .= ([] :: [Text]), "verdict" .= ("pass" :: Text), "exitCode" .= (0 :: Int)]
        change key value (Object fields) = Object (KeyMap.insert key value fields)
        change _ _ value = value
        original = change "comparisonId" (String "original") (change "harnessRevision" (String "host-a") core)
        replay = change "comparisonId" (String "replay") (change "finishedAt" (String "later") (change "harnessRevision" (String "host-b") core))
    semanticComparison original `shouldBe` semanticComparison replay
    semanticComparison (change "metrics" (object ["latency" .= (11 :: Int)]) replay) `shouldNotBe` semanticComparison original

twoProfiles :: PerfPlan -> (PlannedProfile, PlannedProfile)
twoProfiles plan = case plan.selected of
  [first, second] -> (first, second)
  _ -> error "synthetic plan fixture must contain exactly two profiles"

fixture :: IO PerfPlan
fixture = eitherDecodeFileStrict' "test/golden/perf-plan.json" >>= either (fail . show) pure

digest :: Text
digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

configuration :: Text -> PlannedProfile -> ConfigurationResult
configuration verdict entry = ConfigurationResult entry.profile.name entry.workloadSha256 verdict "healthy" [] entry.profile.minimumPairs entry.profile.minimumPairs [] (Just (comparisonValue verdict entry.profile.minimumPairs))

comparisonValue :: Text -> Int -> Value
comparisonValue verdict count = object ["schema" .= ("kenshou.comparison/v1" :: Text), "verdict" .= verdict, "pairCount" .= count]

accepted :: Either Text a -> IO a
accepted = either (fail . show) pure
