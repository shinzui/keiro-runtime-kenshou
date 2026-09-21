module Kenshou.Diagnose.LeakSpec (spec) where

import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Diagnose.Document
import Kenshou.Diagnose.Leak
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Diagnose.Leak" do
  it "round-trips the versioned diagnosis envelope" do
    let encoded = "{\"schema\":\"kenshou.diagnosis/v1\",\"kind\":\"leak\",\"runId\":\"run\",\"scenario\":\"scenario\",\"generatedAt\":\"2026-09-21T00:00:00Z\",\"generator\":{\"package\":\"kenshou-diagnose\",\"version\":\"0.1.0.0\",\"algorithm\":\"test\"},\"body\":{}}"
    fmap encodeDiagnosis (decodeDiagnosis (LazyByteString.pack encoded)) `shouldSatisfy` either (const False) (not . LazyByteString.null)

  it "loads the default policy shape" do
    result <- loadLeakPolicy "../policies/leak-default.json"
    result `shouldSatisfy` either (const False) (not . null . (.probes))

  it "reads series by header name and reports missing columns" do
    result <- readWide "test/fixtures/series/leak.csv" "t_mono_ns" "live_bytes_last_gc"
    fmap Vector.length result `shouldBe` Right 6
    missing <- readWide "test/fixtures/series/leak.csv" "t_mono_ns" "not_present"
    missing `shouldBe` Left (MissingColumn "test/fixtures/series/leak.csv" "not_present")

  it "maps verdicts onto the shared outcome vocabulary" do
    leakOutcome (LeakReport LeakSuspected Nothing 1 "test" []) `shouldNotBe` leakOutcome (LeakReport Stable Nothing 1 "test" [])

  it "distinguishes a flat sawtooth envelope from a rising one" do
    let stable = Vector.fromList [(fromIntegral index, if even index then 100 else 1000) | index <- [0 .. 79 :: Int]]
        rising = Vector.imap (\index (time, value) -> (time, value + fromIntegral (index `div` 2) * 20)) stable
    (judgeSeries testSpec 42 testProbe stable).verdict `shouldBe` Stable
    (judgeSeries testSpec 42 testProbe rising).verdict `shouldBe` LeakSuspected

  it "recognises a plateau after initial growth" do
    let points = Vector.fromList [(fromIntegral index, fromIntegral (min index 30) * 100) | index <- [0 .. 79 :: Int]]
        report = judgeSeries testSpec {envelopeWindowSeconds = 1} 42 testProbe {floorPerHour = 1000} points
    report.verdict `shouldBe` Stable
    report.reason `shouldBe` "plateau-after-growth"

  it "returns insufficient data for a short or threshold-straddling series" do
    let short = Vector.fromList [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4)]
        exactFloor = Vector.fromList [(fromIntegral index, fromIntegral index) | index <- [0 .. 79 :: Int]]
    (judgeSeries testSpec 42 testProbe short).verdict `shouldBe` InsufficientData
    (judgeSeries testSpec {envelopeWindowSeconds = 1} 42 testProbe {floorPerHour = 3600} exactFloor).reason `shouldBe` "interval-straddles-floor"

  it "refuses forced major collections for benchmark scenarios" do
    case parseScenarioId "selftest/diagnose/benchmark/refuses-major-gc" of
      Left err -> expectationFailure (show err)
      Right scenario -> do
        let runContext = RunContext undefined scenario undefined undefined undefined undefined undefined undefined undefined undefined undefined undefined
        withMajorGcProbe runContext 1 (pure ()) `shouldThrow` anyIOException

  it "keeps the actual header contract in the default catalog" do
    case [probe | probe <- defaultLeakSpec.probes, probe.name == ("heap.live-bytes" :: Text)] of
      [heap] -> do
        heap.binding.valueColumn `shouldBe` "live_bytes_last_gc"
        heap.binding.filters `shouldBe` Map.singleton "phase" "steady"
      other -> expectationFailure ("expected one heap probe, got " <> show other)

testProbe :: ProbeSpec
testProbe = ProbeSpec "test" "count" (SeriesBinding "synthetic.csv" "seconds" "value" Map.empty) WindowMin Bounded 3600 1 0 Nothing

testSpec :: LeakSpec
testSpec = LeakSpec [testProbe] 0 20 10 2 200 0.95
