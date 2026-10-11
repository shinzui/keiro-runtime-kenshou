module Kenshou.Measure.PerfSpec (spec) where

import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kenshou.Core.Id (newRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Measure.Clock (Origin (..))
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (encodeHistogram)
import Kenshou.Measure.Metrics (Metric (..))
import Kenshou.Measure.Perf
import Kenshou.Measure.Samples
import Kenshou.Measure.Summary
import Kenshou.Perf.Plan (PerfProfile (..), ProfileCatalog (..), RequiredMetric (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance metric admission" do
  it "cannot accept missing p99 while throughput remains present" do
    requiredMetricProblems required summary {metrics = Map.delete p99 summary.metrics}
      `shouldBe` [MissingRequiredMetric p99]
  it "classifies a changed metric unit as invalid evidence" do
    requiredMetricProblems required summary {metrics = Map.insert p99 (Metric 10 "us") summary.metrics}
      `shouldBe` [InvalidPerformanceEvidence ("metric unit mismatch: " <> p99)]
  it "keeps an undersampled required metric inconclusive" do
    let under = summary {ops = Map.singleton "publish-to-finalize" (object ["count" .= (999 :: Int)])}
    requiredMetricProblems required under `shouldBe` [InsufficientSteadySamples p99 1000 999]
  it "requires a policy rule for every required metric" do
    profile <- loadProfile
    policy <- loadPolicy
    validateProfilePolicy profile policy {Policy.metricRules = filter (not . (\rule -> Policy.matchesRule rule.match p99)) policy.metricRules}
      `shouldBe` Left ("required metric has no policy rule: " <> p99)
  it "accepts a sealed run only after raw histogram and summary reconstruction" do
    withSystemTempDirectory "kenshou-perf-admission" \directory -> do
      profile <- loadProfile
      writeRun directory
      admitted <- verifyPerformanceRun profile directory
      admitted `shouldSatisfy` isRight
  it "detects storage tampering before using a retained summary" do
    withSystemTempDirectory "kenshou-perf-tamper" \directory -> do
      profile <- loadProfile
      writeRun directory
      ByteString.appendFile (directory </> "samples/publish-to-finalize.raw") "tampered"
      admitted <- verifyPerformanceRun profile directory
      admitted `shouldSatisfy` isInvalid
  it "rejects a corrupt histogram even if someone reseals its digest" do
    withSystemTempDirectory "kenshou-perf-histogram" \directory -> do
      profile <- loadProfile
      writeRun directory
      changed <- Histogram.newHistogram Histogram.defaultHistogramConfig
      mapM_ (const (Histogram.recordValue changed 20)) [1 :: Int .. 1000]
      histogram <- Histogram.freeze changed
      ByteString.writeFile (directory </> "samples/publish-to-finalize.hist") (encodeHistogram histogram)
      seal directory
      admitted <- verifyPerformanceRun profile directory
      admitted `shouldSatisfy` isInvalid
  it "rejects a missing retained required metric even with a resealed summary" do
    withSystemTempDirectory "kenshou-perf-summary" \directory -> do
      profile <- loadProfile
      writeRun directory
      recomputed <- summarizeRunDir directory >>= either (fail . show) pure
      let incomplete = recomputed {metrics = Map.delete p99 recomputed.metrics}
      writeResult directory incomplete
      seal directory
      admitted <- verifyPerformanceRun profile directory
      admitted `shouldSatisfy` isInvalid
  where
    isRight (Right _) = True
    isRight _ = False
    isInvalid (Left problems) = any invalid problems
    isInvalid _ = False
    invalid (InvalidPerformanceEvidence _) = True
    invalid _ = False

p99 :: Text
p99 = "op.publish-to-finalize.latency.p99"

required :: [RequiredMetric]
required = [RequiredMetric p99 "ns" 1000]

summary :: MeasurementSummary
summary =
  MeasurementSummary
    "benchmark"
    []
    (SummaryWindow 1000 4000 0.000003)
    (Map.singleton "publish-to-finalize" (object ["count" .= (1000 :: Int)]))
    (Map.fromList [(p99, Metric 10 "ns"), ("op.publish-to-finalize.throughput", Metric 200 "ops/s")])
    []

writeRun :: FilePath -> IO ()
writeRun directory = do
  createDirectoryIfMissing True (directory </> "samples")
  createDirectoryIfMissing True (directory </> "series")
  ByteString.writeFile (directory </> "series/load.csv") "mono_ns,wall,phase\n1000,0,steady\n4000,0,drain\n"
  encodeFile (directory </> "run-spec.json") (object ["dimensions" .= object []])
  mutable <- Histogram.newHistogram Histogram.defaultHistogramConfig
  mapM_ (const (Histogram.recordValue mutable 10)) [1 :: Int .. 1000]
  histogram <- Histogram.freeze mutable
  let base = directory </> "samples/publish-to-finalize"
  ByteString.writeFile (base <> ".hist") (encodeHistogram histogram)
  ByteString.writeFile (base <> ".service.hist") (encodeHistogram histogram)
  writer <- openSampleWriter (base <> ".raw") (SampleHeader (Origin 0 0) MonotonicClock "publish-to-finalize" "fixture")
  writeSampleBlock writer 0 [SampleRecord (1000 + index) (1000 + index) (1010 + index) 0 1 | index <- [0 .. 999]]
  closeSampleWriter writer
  encodeFile
    (base <> ".meta.json")
    ( object
        [ "operation" .= ("publish-to-finalize" :: Text),
          "latencyBasis" .= ("intended-start" :: Text),
          "rawSamples" .= ("full" :: Text),
          "phaseCounts" .= object ["steady" .= object ["successes" .= (1000 :: Int), "failures" .= (0 :: Int), "units" .= (1000 :: Int)]]
        ]
    )
  recomputed <- summarizeRunDir directory >>= either (fail . show) pure
  writeResult directory recomputed
  seal directory

writeResult :: FilePath -> MeasurementSummary -> IO ()
writeResult directory measurements =
  encodeFile
    (directory </> "run-result.json")
    (object ["summaries" .= object ["measurements" .= object ["measurements" .= measurements]]])

seal :: FilePath -> IO ()
seal directory = do
  runId <- newRunId
  manifest <- writeManifest directory runId Map.empty
  encodeFile (directory </> "manifest.json") manifest

loadProfile :: IO PerfProfile
loadProfile = do
  path <- repositoryFile "policies/performance/catalog.v1.json"
  catalog <- eitherDecodeFileStrict' path >>= either fail pure
  case (catalog :: ProfileCatalog).profiles of
    profile : _ -> pure profile
    [] -> fail "empty profile catalog"

loadPolicy :: IO Policy.Policy
loadPolicy = do
  path <- repositoryFile "policies/default.json"
  ByteString.readFile path >>= either (fail . show) pure . Policy.decodePolicy

repositoryFile :: FilePath -> IO FilePath
repositoryFile path = do
  exists <- doesFileExist path
  pure (if exists then path else "../" <> path)
