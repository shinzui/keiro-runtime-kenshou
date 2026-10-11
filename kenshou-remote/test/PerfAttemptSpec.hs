module PerfAttemptSpec (spec) where

import Data.Aeson
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Data.Word (Word64)
import Kenshou.Core.Id (mkSeed, newRunId, renderRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Measure.Clock (Origin (..))
import Kenshou.Measure.Compare.Compatibility (VaryingAxis (..))
import Kenshou.Measure.Compare.Ordering (PairedOrdering (..))
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (encodeHistogram)
import Kenshou.Measure.Samples
import Kenshou.Measure.Summary (summarizeRunDir)
import Kenshou.Perf.Plan
import Kenshou.Perf.Result
import Kenshou.Perf.Result qualified as Configuration (ConfigurationResult (..))
import Kenshou.Plan.RunPlan (PlannedRun, RunPlan (..), TrialInfo (..))
import Kenshou.Plan.RunPlan qualified as Plan (PlannedRun (..))
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Pair
import Kenshou.Remote.Perf.Attempt
import Kenshou.Remote.Perf.Journal
import Kenshou.Remote.Perf.Runner
import System.Directory (createDirectoryIfMissing, renameDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance paired attempts" do
  it "reconstructs five raw pairs, preserves an exit-zero defect and replays portable paths" $ withSystemTempDirectory "perf-raw-pairs" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    calls <- newIORef (0 :: Int)
    blockers <- newIORef ([] :: [Text.Text])
    let attempt = directory </> "original"
        moved = directory </> "relocated"
        callbacks = ComparisonHooks (\_ -> expectationFailure "stable five-pair control must not replace pairs") (\reason -> modifyIORef' blockers (<> [reason]))
        execute run = do
          modifyIORef' calls (+ 1)
          let path = attempt </> "retained" </> Text.unpack (renderRunId run.runId)
          writeRawRun run (run.ordinal == 2) 1000000 path
          pure (Right path)
    result <- executeAttempt (LeaseIdentity "alpha" identifier) entry schedule policy (VaryControl :| []) attempt callbacks execute
    result.performanceVerdict `shouldBe` "pass"
    result.infrastructureState `shouldBe` "healthy"
    result.validPairs `shouldBe` 5
    result.runtimeFailures `shouldBe` ["runtime assertions failed (including nonblocking known defects)"]
    readIORef calls `shouldReturn` 10
    readIORef blockers `shouldReturn` result.runtimeFailures
    verifyAttempt entry schedule policy (VaryControl :| []) attempt result `shouldReturn` True
    encodeFile (attempt </> "comparison.json") result.comparison
    originalBytes <- Bytes.readFile (attempt </> "comparison.json")
    renameDirectory attempt moved
    verifyAttempt entry schedule policy (VaryControl :| []) moved result `shouldReturn` True
    Bytes.readFile (moved </> "comparison.json") `shouldReturn` originalBytes
    plan <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-plan.json" >>= either fail pure
    aggregate <- either (fail . show) pure (aggregateResult (plan {selected = [entry]} :: PerfPlan) ("sha256:" <> Text.replicate 64 "a") True [result])
    aggregate.exitCode `shouldBe` 1
  it "replaces an invalid raw pair once and detects a genuine retained latency regression" $ withSystemTempDirectory "perf-raw-regression" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    calls <- newIORef (0 :: Int)
    replacements <- newIORef (0 :: Int)
    let callbacks = ComparisonHooks (\_ -> modifyIORef' replacements (+ 1)) (\_ -> pure ())
        execute run = do
          modifyIORef' calls (+ 1)
          let path = directory </> "retained" </> Text.unpack (renderRunId run.runId)
              latency = if maybe False ((== "candidate") . (.arm)) run.trial then 3000000 else 1000000
          writeRawRun run False latency path
          if run.ordinal == 1 then Bytes.appendFile (path </> "samples/publish-to-finalize.raw") "invalid" else pure ()
          pure (Right path)
    result <- executeAttempt (LeaseIdentity "alpha" identifier) entry schedule policy (VaryControl :| []) directory callbacks execute
    result.performanceVerdict `shouldBe` "regression"
    result.infrastructureState `shouldBe` "healthy"
    result.validPairs `shouldBe` 5
    readIORef calls `shouldReturn` 12
    readIORef replacements `shouldReturn` 1
    verifyAttempt entry schedule policy (VaryControl :| []) directory result `shouldReturn` True
  it "bounds replacements and reuses retained invalid paths without resubmitting trials" $ withSystemTempDirectory "perf-attempt" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    calls <- newIORef (0 :: Int)
    replacements <- newIORef (0 :: Int)
    let lease = LeaseIdentity "alpha" identifier
        callbacks = ComparisonHooks (\_ -> modifyIORef' replacements (+ 1)) (\_ -> pure ())
        execute run = do
          modifyIORef' calls (+ 1)
          let path = directory </> "retained" </> Text.unpack (renderRunId run.runId)
          createDirectoryIfMissing True path
          encodeFile (path </> "run-result.json") (object [])
          encodeFile (path </> "run-spec.json") (object [])
          pure (Right path)
    result <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    result.infrastructureState `shouldBe` "failed"
    result.validPairs `shouldBe` 0
    readIORef calls `shouldReturn` 14
    readIORef replacements `shouldReturn` 2
    verifyAttempt entry schedule policy (VaryControl :| []) directory result `shouldReturn` True
    verifyAttempt entry schedule policy (VaryControl :| []) directory result {Configuration.attempts = []} `shouldReturn` False
    _ <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    readIORef calls `shouldReturn` 14
    another <- newRunId
    verifyAttemptInputs lease entry schedule directory
    verifyAttemptInputs (LeaseIdentity "alpha" another) entry schedule directory `shouldThrow` anyIOException
    executeAttempt (LeaseIdentity "alpha" another) entry schedule policy (VaryControl :| []) directory callbacks execute `shouldThrow` anyIOException
  it "checkpoints terminal executor failures and replays them without new work" $ withSystemTempDirectory "perf-attempt-failures" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    calls <- newIORef (0 :: Int)
    let callbacks = ComparisonHooks (\_ -> pure ()) (\_ -> pure ())
        execute _ = modifyIORef' calls (+ 1) >> pure (Left "sealed outer health failed")
        lease = LeaseIdentity "alpha" identifier
    result <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    readIORef calls `shouldReturn` 14
    repeated <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    repeated `shouldBe` result
    readIORef calls `shouldReturn` 14
    verifyAttempt entry schedule policy (VaryControl :| []) directory result `shouldReturn` True
    encodeFile (directory </> "trial-failures.json") (Map.singleton ("unplanned" :: Text.Text) ("invalid" :: Text.Text))
    verifyAttempt entry schedule policy (VaryControl :| []) directory result `shouldThrow` anyIOException
  it "rejects an incomplete schedule and a forged retained path before dispatch" $ withSystemTempDirectory "perf-attempt-rejection" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    let callbacks = ComparisonHooks (\_ -> pure ()) (\_ -> pure ())
        execute _ = expectationFailure "must not dispatch an invalid attempt" >> pure (Left "invalid")
    executeAttempt (LeaseIdentity "alpha" identifier) entry schedule {runs = drop 1 schedule.runs} policy (VaryControl :| []) (directory </> "incomplete") callbacks execute `shouldThrow` anyIOException
    createDirectoryIfMissing True (directory </> "forged")
    encodeFile (directory </> "forged/trial-paths.json") (Map.singleton ("unplanned" :: Text.Text) ("../escape" :: FilePath))
    executeAttempt (LeaseIdentity "alpha" identifier) entry schedule policy (VaryControl :| []) (directory </> "forged") callbacks execute `shouldThrow` anyIOException

fixture :: IO (PlannedProfile, RunPlan, Policy.Policy)
fixture = do
  plan <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-plan.json" >>= either fail pure
  entry <- case (plan :: PerfPlan).selected of value : _ -> pure value; _ -> fail "empty profile fixture"
  identifier <- newRunId
  seed <- either (fail . show) pure (mkSeed 37)
  source <-
    either
      (fail . show)
      pure
      ( decodeWorkPlan
          ( object
              [ "schema" .= ("kenshou.run-plan/v1" :: Text.Text),
                "planId" .= identifier,
                "runs"
                  .= [ object
                         [ "ordinal" .= (0 :: Int),
                           "runId" .= identifier,
                           "estimateMinutes" .= (1 :: Int),
                           "spec"
                             .= object
                               [ "schema" .= ("kenshou.run-spec/v1" :: Text.Text),
                                 "runId" .= identifier,
                                 "scenario" .= entry.profile.scenario,
                                 "scenarioRevision" .= entry.profile.scenarioRevision,
                                 "knobs" .= entry.profile.knobs,
                                 "dimensions" .= entry.profile.dimensions,
                                 "seed" .= seed,
                                 "phases" .= zeroPhases,
                                 "timeoutSeconds" .= entry.profile.timeoutSeconds
                               ]
                         ]
                     ]
              ]
          )
      )
  schedule <- either (fail . show) pure (pairPlan (PairRequest "candidate" "baseline" 5 ABBA 37 2) source)
  policy <- Bytes.readFile "../policies/default.json" >>= either (fail . show) pure . Policy.decodePolicy
  pure (entry, schedule, policy)

-- Synthetic protocol evidence only; this is not workload calibration.
writeRawRun :: PlannedRun -> Bool -> Word64 -> FilePath -> IO ()
writeRawRun run knownFailure latency directory = do
  createDirectoryIfMissing True (directory </> "samples")
  createDirectoryIfMissing True (directory </> "series")
  Bytes.writeFile (directory </> "series/load.csv") "mono_ns,wall,phase\n1000,0,steady\n5000001000,0,drain\n"
  encodeFile (directory </> "run-spec.json") run.spec
  mutable <- Histogram.newHistogram Histogram.defaultHistogramConfig
  mapM_ (const (Histogram.recordValue mutable latency)) [1 :: Int .. 1000]
  histogram <- Histogram.freeze mutable
  let base = directory </> "samples/publish-to-finalize"
  Bytes.writeFile (base <> ".hist") (encodeHistogram histogram)
  Bytes.writeFile (base <> ".service.hist") (encodeHistogram histogram)
  writer <- openSampleWriter (base <> ".raw") (SampleHeader (Origin 0 0) MonotonicClock "publish-to-finalize" "synthetic")
  writeSampleBlock writer 0 [SampleRecord start start (start + latency) 0 1 | index <- [0 .. 999], let start = 1000 + index * 5000000]
  closeSampleWriter writer
  encodeFile (base <> ".meta.json") (object ["operation" .= ("publish-to-finalize" :: Text.Text), "latencyBasis" .= ("intended-start" :: Text.Text), "rawSamples" .= ("full" :: Text.Text), "phaseCounts" .= object ["steady" .= object ["successes" .= (1000 :: Int), "failures" .= (0 :: Int), "units" .= (1000 :: Int)]]])
  measurements <- summarizeRunDir directory >>= either (fail . show) pure
  let origin = UTCTime (fromGregorian 2026 10 10) (secondsToDiffTime 0)
  encodeFile
    (directory </> "run-result.json")
    (object ["runId" .= run.runId, "outcome" .= (if knownFailure then "failed" else "passed" :: Text.Text), "exitCode" .= (0 :: Int), "blocking" .= False, "compatibility" .= object ["inputs" .= object ["cohortPlanHash" .= ("synthetic-control" :: Text.Text)]], "fingerprint" .= object ["machineProfile" .= ("synthetic" :: Text.Text)], "timings" .= object ["startedAt" .= addUTCTime (fromIntegral run.ordinal) origin], "summaries" .= object ["measurements" .= object ["measurements" .= measurements]]])
  manifest <- writeManifest directory run.runId Map.empty
  encodeFile (directory </> "manifest.json") manifest
