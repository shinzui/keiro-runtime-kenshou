module PerfSessionSpec (PerfSessionSpec.spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, finally)
import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Kenshou.Cli (runWithArgs)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Measure.Clock (Origin (..))
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (encodeHistogram)
import Kenshou.Measure.Samples
import Kenshou.Measure.Summary (summarizeRunDir)
import Kenshou.Perf.Artifacts (sealPerfDirectory)
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Result qualified as Result
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs
import Kenshou.Remote.Cell.Lease qualified as Lease
import Kenshou.Remote.Cell.Prepare (cellMachineProfile)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Payload (Bundle (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload qualified as Payload
import Kenshou.Remote.Perf.Journal qualified as Journal
import Kenshou.Remote.Store
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeFile, withCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "file-backed performance CLI integration" do
  forM_ [(False, "executes two profiles under one lease and replays the full sealed graph without redispatch"), (True, "retains an exit-zero known defect through complete report replay and resume")] \(knownFault, title) -> it title $
    withSystemTempDirectory "perf-cli-healthy" \root -> projectRoot do
      let preparation = root </> "preparation"
          output = root </> "session"
          storeRoot = root </> "store"
          payloadBytes = "synthetic protocol payload; no runtime calibration is claimed"
          digest = Text.drop 7 (sha256Hex (Lazy.toStrict payloadBytes))
          bundle = Bundle ("gs://tan-nb-exp-cells-control/payloads/sha256/" <> digest <> ".nar.zst") digest (Lazy.length payloadBytes)
          replacePayload arm = case fromJSON arm.payload of
            Error problem -> fail problem
            Success payload -> pure arm {Prepared.payload = toJSON (payload {Payload.cell = payload.cell {Payload.bundle = bundle}} :: PayloadDescriptor)}
      original <- readJSON "kenshou-core/test/golden/perf-prepared.fixture.json"
      baseline <- replacePayload (original :: Prepared.PerfPrepared).baseline
      candidate <- replacePayload original.candidate
      let prepared = original {Prepared.baseline = baseline, Prepared.candidate = candidate}
      createDirectoryIfMissing True preparation
      encodeFile (preparation </> "prepared.json") prepared
      sealPerfDirectory preparation >>= either (fail . Text.unpack) pure
      descriptor <- readJSON "kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
      policy <- Lazy.readFile "kenshou-remote/test/golden/cell/cell.policy.v1.json"
      store <- newFileStore storeRoot
      let control = Bucket descriptor.buckets.control
          put bucket name bytes = store.putObject bucket (ObjectName name) "application/json" DoesNotExist bytes >>= requireWritten
      put control ("payloads/sha256/" <> digest <> ".nar.zst") payloadBytes
      put control "cells/alpha/descriptor.json" (encode descriptor)
      put control "cells/alpha/policy.json" policy
      agent <- forkIO (sealMarkers knownFault store descriptor root Set.empty)
      ( withSetting "KENSHOU_CELL_STORE" ("file:" <> storeRoot) $
          withSetting "KENSHOU_CELL_CAPABILITIES_DIR" (root </> "capabilities") do
            execution <- timeout 90000000 (runWithArgs ["perf", "run", "--prepared", preparation </> "prepared.json", "--out", output, "--evidence-base-uri", "gs://fixture-evidence/performance"])
            let expectedExit = if knownFault then ExitFailure 1 else ExitSuccess
            execution `shouldBe` Just expectedExit
            result <- readJSON (output </> "result.json")
            (result :: Result.PerfResult).performanceVerdict `shouldBe` "pass"
            result.gatingEligible `shouldBe` False
            length result.configurations `shouldBe` 2
            map (.validPairs) result.configurations `shouldBe` [5, 5]
            null result.blockingRuntimeFailures `shouldBe` not knownFault
            store.getObject control (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing
            initialMarkers <- store.listObjects control "cells/alpha/submissions/"
            let markers = filter (Text.isSuffixOf "/submission.json" . (.unObjectName) . fst) initialMarkers
            length markers `shouldBe` 20
            submissions <- forM markers \(name, _) -> do
              retained <- store.getObject control name
              maybe (fail "marker vanished") (either fail pure . eitherDecode . fst) retained
            Set.size (Set.fromList [submission.leaseId | submission :: Submission <- submissions]) `shouldBe` 1
            retainedResult <- Lazy.readFile (output </> "result.json")
            forM_ [[], ["--offline"]] \flags -> runWithArgs (["perf", "verify", "--session", output] <> flags) `shouldReturn` expectedExit
            runWithArgs ["perf", "resume", "--session", output] `shouldReturn` expectedExit
            Lazy.readFile (output </> "result.json") `shouldReturn` retainedResult
            store.listObjects control "cells/alpha/submissions/" `shouldReturn` initialMarkers
            -- A second snapshot is forbidden when completed evidence is reused.
            snapshots <- listDirectory (output </> "snapshots")
            length snapshots `shouldBe` 1
            report <- Bytes.readFile (output </> "report.md")
            report `shouldSatisfy` Bytes.isInfixOf "within policy limits"
            report `shouldSatisfy` Bytes.isInfixOf "Comparison reasons: none"
            -- Reconstruct an interruption after the last comparison file was
            -- saved, before its attempt result and root completion checkpoint.
            -- Every sealed cell object and paired schedule stays unchanged.
            saved <- Journal.readPerfSession (output </> "session.json") >>= either (fail . Text.unpack) pure
            let beforeCompletion = takeWhile (\event -> case event.action of Journal.ComparisonCompleted item -> item.profile /= "shibuya-pgmq-quick"; _ -> True) saved.events
                attempt = output </> "configurations/shibuya-pgmq-quick/attempt-0"
            identity <- case [one | event <- beforeCompletion, Journal.LeaseAcquired one <- [event.action]] of
              [one] -> pure one
              _ -> fail "expected exactly one original lease"
            beforeComparison <- Lazy.readFile (attempt </> "comparison.json")
            -- Fixture construction only: the production writer correctly
            -- refuses to rewind an already committed append-only history.
            encodeFile (output </> "session.json") saved {Journal.events = beforeCompletion}
            removeFile (output </> "receipt.json")
            removeFile (attempt </> "result.json")
            Lazy.writeFile (attempt </> "result.json.next") "interrupted JSON write"
            now <- getCurrentTime
            let activeLease = Lease.Lease identity.leaseId identity.cell "kenshou-perf" "pinned runtime performance validation" 180 now now False 20
            put control "cells/alpha/lease.json" (encode activeLease)
            runWithArgs ["perf", "resume", "--session", output] `shouldReturn` expectedExit
            Lazy.readFile (attempt </> "comparison.json") `shouldReturn` beforeComparison
            store.listObjects control "cells/alpha/submissions/" `shouldReturn` initialMarkers
            forM_ [[], ["--offline"]] \flags -> runWithArgs (["perf", "verify", "--session", output] <> flags) `shouldReturn` expectedExit
            -- Even a locally resealed inventory and matching receipt cannot
            -- make an unlinked cell tree part of the interpreted evidence.
            receipt <- readJSON (output </> "receipt.json")
            fields <- case receipt of Object value -> pure value; _ -> fail "invalid receipt"
            relative <- case KeyMap.lookup "snapshot" fields of Just (String value) -> pure value; _ -> fail "receipt omits snapshot"
            let snapshot = output </> Text.unpack relative
                orphan = snapshot </> "configurations/shibuya-core-quick/attempt-0/trials/unlinked-cell/tree"
            createDirectoryIfMissing True orphan
            encodeFile (orphan </> "run-result.json") (object ["outcome" .= ("passed" :: Text)])
            sealPerfDirectory snapshot >>= either (fail . Text.unpack) pure
            changedManifest <- Bytes.readFile (snapshot </> "manifest.json")
            encodeFile (output </> "receipt.json") (Object (KeyMap.insert "manifestSha256" (String (sha256Hex changedManifest)) fields))
            runWithArgs ["perf", "verify", "--session", output, "--offline"] `shouldReturn` ExitFailure 4
        )
        `finally` killThread agent

-- Implements only the immutable protocol in a file store. Its measurements and
-- machine samples are synthetic controls, never acceptance calibration evidence.
sealMarkers :: Bool -> ObjectStore -> CellDescriptor -> FilePath -> Set.Set ObjectName -> IO ()
sealMarkers knownFault store descriptor root seen = do
  let control = Bucket descriptor.buckets.control
  objects <- store.listObjects control "cells/alpha/submissions/"
  let fresh = [name | (name, _) <- objects, "/submission.json" `Text.isSuffixOf` name.unObjectName, name `Set.notMember` seen]
  forM_ fresh \name -> do
    (markerBytes, _) <- store.getObject control name >>= maybe (fail "missing marker") pure
    submission <- either fail pure (eitherDecode markerBytes)
    let prefix = Text.dropEnd (Text.length "submission.json") name.unObjectName
    (workBytes, _) <- store.getObject control (ObjectName (prefix <> "work")) >>= maybe (fail "missing work") pure
    document <- either fail pure (eitherDecode workBytes)
    plan <- either (fail . Text.unpack) pure (decodeWorkPlan document)
    run <- case plan.runs of [one] -> pure one; _ -> fail "expected exactly one paired trial"
    let local = root </> "agent-output" </> Text.unpack (renderRunId submission.runId)
        nested = local </> "output" </> Text.unpack (renderRunId run.runId)
    writeRawRun (knownFault && Set.null seen) descriptor submission run nested
    nestedFiles <- readTree (local </> "output")
    now <- getCurrentTime
    let sequenceNumber = Set.size seen + length (takeWhile (/= name) fresh) + 1
        files =
          [("submission/work", workBytes), ("submission/submission.json", markerBytes), ("cell/result.json", encode (CellRunResult submission.runId "alpha" submission.leaseId sequenceNumber Completed (Just 0) Nothing []))]
            <> healthFiles descriptor submission
            <> [("output/" <> path, bytes) | (path, bytes) <- nestedFiles]
        artifactFor (path, bytes) = let info = workObjectFor "application/json" bytes in Artifact path info.sha256 info.bytes "application/json"
        manifest = CellManifest submission.runId "alpha" submission.leaseId sequenceNumber now "0.1.0" (ManifestPayload submission.payload.bundle.sha256 submission.payload.storePath) Completed 3600 (map artifactFor files)
        manifestBytes = encode manifest
        put bucket path bytes = store.putObject bucket (ObjectName path) "application/json" DoesNotExist bytes >>= requireWritten
        resultPrefix = "runs/" <> renderRunId submission.runId <> "/"
    forM_ files \(path, bytes) -> put (Bucket descriptor.buckets.results) (resultPrefix <> path) bytes
    put (Bucket descriptor.buckets.results) (resultPrefix <> "manifest.json") manifestBytes
    put control (prefix <> "status.json") (encode (CellStatus submission.runId Sealed (Just sequenceNumber) now Nothing (LogChunks 0 0) (Just Completed) (Just (workObjectFor "application/json" manifestBytes).sha256) (Just [])))
  threadDelay 10000
  sealMarkers knownFault store descriptor root (Set.union seen (Set.fromList fresh))

writeRawRun :: Bool -> CellDescriptor -> Submission -> PlannedRun -> FilePath -> IO ()
writeRawRun knownFault descriptor submission run directory = do
  createDirectoryIfMissing True (directory </> "samples")
  createDirectoryIfMissing True (directory </> "series")
  Bytes.writeFile (directory </> "series/load.csv") "mono_ns,wall,phase\n1000,0,steady\n5000001000,0,drain\n"
  encodeFile (directory </> "run-spec.json") run.spec
  mutable <- Histogram.newHistogram Histogram.defaultHistogramConfig
  forM_ [1 :: Int .. 1000] (const (Histogram.recordValue mutable 1000000))
  histogram <- Histogram.freeze mutable
  let operation = "publish-to-finalize"
      base = directory </> "samples" </> Text.unpack operation
  Bytes.writeFile (base <> ".hist") (encodeHistogram histogram)
  Bytes.writeFile (base <> ".service.hist") (encodeHistogram histogram)
  writer <- openSampleWriter (base <> ".raw") (SampleHeader (Origin 0 0) MonotonicClock operation "synthetic")
  writeSampleBlock writer 0 [SampleRecord start start (start + 1000000) 0 1 | index <- [0 .. 999], let start = 1000 + index * 5000000]
  closeSampleWriter writer
  encodeFile (base <> ".meta.json") (object ["operation" .= operation, "latencyBasis" .= ("intended-start" :: Text), "rawSamples" .= ("full" :: Text), "phaseCounts" .= object ["steady" .= object ["successes" .= (1000 :: Int), "failures" .= (0 :: Int), "units" .= (1000 :: Int)]]])
  measurements <- summarizeRunDir directory >>= either (fail . show) pure
  encodeFile (directory </> "run-result.json") (object ["runId" .= run.runId, "scenario" .= run.spec.scenario, "outcome" .= (if knownFault then "failed" else "passed" :: Text), "exitCode" .= (0 :: Int), "blocking" .= False, "compatibility" .= object ["inputs" .= object ["cohortPlanHash" .= ("synthetic-control" :: Text)]], "fingerprint" .= object ["machineProfile" .= cellMachineProfile descriptor, "cell" .= object ["payload" .= object ["bundleSha256" .= submission.payload.bundle.sha256]]], "timings" .= object ["startedAt" .= addUTCTime (fromIntegral run.ordinal) (at 0)], "summaries" .= object ["measurements" .= object ["measurements" .= measurements]]])
  writeManifest directory run.runId Map.empty >>= encodeFile (directory </> "manifest.json")

healthFiles :: CellDescriptor -> Submission -> [(Text, Lazy.ByteString)]
healthFiles descriptor submission =
  [ ("cell/execution-window.json", encode (object ["schema" .= ("cell.execution-window/v1" :: Text), "runId" .= submission.runId, "resetStarted" .= at 0, "runStarted" .= at 10, "runFinished" .= at 60])),
    ("cell/health.json", encode (object ["schema" .= ("cell.health/v1" :: Text), "runId" .= submission.runId, "passed" .= True, "windowStart" .= at 0, "windowEnd" .= at 60, "gates" .= concatMap gates roles])),
    ("cell/reset-evidence.json", encode (object ["schema" .= ("cell.reset-evidence/v1" :: Text), "runId" .= submission.runId, "cell" .= ("alpha" :: Text), "cachePolicy" .= ("cold" :: Text), "verified" .= True, "startedAt" .= at 0, "finishedAt" .= at 5, "steps" .= [object ["name" .= ("stop-driver-processes" :: Text), "status" .= ("ok" :: Text), "startedAt" .= at 0, "finishedAt" .= at 5]]]))
  ]
    <> [("cell/observations/" <> role <> ".json", encode (object ["schema" .= ("cell.observations/v1" :: Text), "machine" .= machine, "image" .= image, "agentVersion" .= ("0.1.0" :: Text), "systemClosure" .= ("/nix/store/synthetic-system-identity" :: Text), "from" .= at 0, "to" .= at 60, "samples" .= [sample i | i <- [0 .. 60]], "maintenanceEvents" .= ([] :: [Value]), "samplingErrors" .= ([] :: [Value])])) | (role, machine, image) <- roles]
  where
    roles = [("driver", machine, descriptor.images.driver) | machine <- take 1 descriptor.instances.drivers] <> [("postgres", descriptor.instances.postgres, descriptor.images.postgres), ("monitoring", descriptor.instances.monitoring, descriptor.images.monitoring)]
    sample i = object ["at" .= at i, "cpuTotalTicks" .= (1000 + i * 100), "cpuIdleTicks" .= (990 + i * 99), "cpuStealTicks" .= (0 :: Int), "diskFreePercent" .= (if i <= 10 then 80 else 75 :: Int)]
    gates (role, machine, _) =
      [ gate "host-maintenance" (String "NONE") (String "NONE"),
        gate "background-load" (object ["settleCpuPercent" .= (if role == "monitoring" then 0 else 1 :: Int), "runStealCpuPercent" .= (0 :: Int)]) (object ["settleCpuMaxPercent" .= (5 :: Int), "runStealCpuMaxPercent" .= (2 :: Int)]),
        gate "storage-pressure" (object ["startFreePercent" .= (80 :: Int), "runFreePercent" .= (75 :: Int), "outputExceeded" .= False]) (object ["startFreeMinPercent" .= (20 :: Int), "runFreeMinPercent" .= (5 :: Int), "outputExceeded" .= False]),
        gate "incomplete-reset" (Bool True) (Bool True),
        gate "version-mismatch" (Bool True) (Bool True)
      ]
      where
        gate name observed threshold = object ["name" .= (name :: Text), "machine" .= machine, "status" .= ("ok" :: Text), "at" .= at 60, "observed" .= observed, "threshold" .= threshold]

at :: Int -> UTCTime
at seconds = addUTCTime (fromIntegral seconds) (read "2026-10-11 00:00:00 UTC")

readTree :: FilePath -> IO [(Text, Lazy.ByteString)]
readTree directory = do
  names <- listDirectory directory
  concat <$> forM names \name -> do
    let path = directory </> name
    regular <- doesFileExist path
    if regular
      then do bytes <- Lazy.readFile path; pure [(Text.pack name, bytes)]
      else map (\(relative, bytes) -> (Text.pack name <> "/" <> relative, bytes)) <$> readTree path

readJSON :: (FromJSON a) => FilePath -> IO a
readJSON path = eitherDecodeFileStrict' path >>= either fail pure

requireWritten :: PutOutcome -> IO ()
requireWritten (Written _) = pure ()
requireWritten PreconditionFailed = fail "synthetic protocol object already exists"

projectRoot :: IO a -> IO a
projectRoot action = do
  root <- doesFileExist "cohort/released.json"
  withCurrentDirectory (if root then "." else "..") action

withSetting :: String -> String -> IO a -> IO a
withSetting name value action = bracket (lookupEnv name) restore \_ -> setEnv name value >> action
  where
    restore Nothing = unsetEnv name
    restore (Just previous) = setEnv name previous
