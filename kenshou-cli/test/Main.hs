module Main (main) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, finally)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List (find)
import Data.List qualified as List
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Kenshou.Cli (runWithArgs)
import Kenshou.Cli.Attest (FencingFacts (..), fencingFacts)
import Kenshou.Cli.Attest.KeiroLease (replayLeaseCells)
import Kenshou.Cli.Cohort (resolveDefaultCohortIdentity)
import Kenshou.Cli.Version (appVersionWithGit)
import Kenshou.Core.Cohort (CohortIdentity (..), CohortName (..))
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Core.Outcome qualified as Outcome
import Kenshou.Remote.Cell.Docs (Artifact (..), CellBuckets (..), CellDescriptor (..), CellManifest (..), CellOutcome (..), CellPhase (..), CellRunResult (..), CellStatus (..), Limits (..), LogChunks (..), ManifestPayload (..), Rejected (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (Lease (..))
import Kenshou.Remote.Cell.RouteRules (descriptorDigest)
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), SessionJournal (..), SliceJournal (..), SliceState (..), readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Telemetry.Overhead (OverheadState (..), SlotRun (..), loadOverheadState)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, listDirectory, makeAbsolute, withCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (describe, expectationFailure, hspec, it, shouldBe, shouldReturn, shouldSatisfy)

main :: IO ()
main = hspec do
  describe "independent queue lease replay" do
    it "rechecks SQL leases, handler attempts, effects and drain state" do
      now <- getCurrentTime
      let lease readCount readSeconds vtSeconds observedSeconds = object ["messageId" .= (1 :: Int), "readCount" .= (readCount :: Int), "lastReadAt" .= addUTCTime readSeconds now, "visibleAt" .= addUTCTime vtSeconds now, "observedAt" .= addUTCTime observedSeconds now]
          delivery attempt payload = object ["attempt" .= (attempt :: Int), "payload" .= (payload :: Text)]
          arm initial contested deliveries effects = object ["schema" .= ("kenshou.queue-lease-observations/v1" :: Text), "initial" .= initial, "contested" .= contested, "deliveries" .= (deliveries :: [Value]), "completionObserved" .= True, "effects" .= (effects :: [Text]), "remainingRows" .= ([] :: [Value])]
          unextended = arm (lease 1 0 2 0) (lease 2 3 5 6) [delivery 0 "unextended", delivery 1 "unextended"] ["unextended", "unextended"]
          extended = arm (lease 1 0 10 0) (lease 1 0 10 6) [delivery 0 "extended", Aeson.Null] ["extended"]
          replace key value (Aeson.Object fields) = Aeson.Object (KeyMap.insert key value fields)
          replace _ _ value = value
          failures value = fmap (map fst . filter (not . snd)) (replayLeaseCells unextended value)
      failures extended `shouldBe` Right []
      failures (replace "contested" (lease 2 3 13 6) extended) `shouldBe` Right ["extended-read-count-one"]
      failures (replace "contested" (lease 1 0 10 11) extended) `shouldBe` Right ["extended-read-count-one"]
      failures (replace "contested" (lease 1 0 10 1) extended) `shouldBe` Right ["extended-read-count-one"]
      failures (replace "effects" (Aeson.toJSON (["extended", "extended"] :: [Text])) extended) `shouldBe` Right ["extension-prevents-duplicate"]
      failures (replace "effects" (Aeson.toJSON (["substituted"] :: [Text])) extended) `shouldBe` Right ["extension-prevents-duplicate"]
      failures (replace "deliveries" (Aeson.toJSON ([Aeson.Null, Aeson.Null] :: [Value])) extended) `shouldBe` Right ["extended-read-count-one"]
      failures (replace "remainingRows" (Aeson.toJSON [lease 1 0 10 6]) extended) `shouldBe` Right ["both-queues-drained"]
      fmap (map fst . filter (not . snd)) (replayLeaseCells (replace "contested" (lease 2 1 3 6) unextended) extended) `shouldBe` Right ["unextended-read-count-and-cadence"]
      replayLeaseCells (object []) extended `shouldSatisfy` either (const True) (const False)
  describe "Kafka fencing outcome oracle" do
    it "derives the released idle-member failure from separate worker logs" do
      fencingFacts [] [okEvent 10]
        `shouldBe` Right (FencingFacts True False False [] ["fenced-member-still-alive-and-idle"])

    it "derives a passing fatal exit from separate worker logs" do
      fencingFacts [errorEvent "KafkaResponseError RdKafkaRespErrFatal", doneEvent] [okEvent 10]
        `shouldBe` Right (FencingFacts True True True ["KafkaResponseError RdKafkaRespErrFatal"] [])

    it "keeps an unrelated consumer error blocking" do
      fencingFacts [errorEvent "unexpected Kafka error"] [okEvent 10]
        `shouldBe` Right (FencingFacts True False False ["unexpected Kafka error"] ["fencing-unexpected-error", "fencing-fatal-not-observable"])

    it "rejects malformed error evidence" do
      fencingFacts [object ["type" .= ("error" :: Text)]] [okEvent 10]
        `shouldBe` Left "an original-consumer error event has no message"

  describe "CLI exit contract" do
    it "resolves the wrapped cohort identity outside a source checkout" $
      withSystemTempDirectory "kenshou-wrapped-cohort" \root -> do
        fixture <- makeAbsolute "../kenshou-core/test/fixtures/cohort-identity.golden.json"
        withEnvVariable "KENSHOU_COHORT_IDENTITY" fixture $
          withCurrentDirectory root do
            resolved <- resolveDefaultCohortIdentity
            case resolved of
              Left problem -> expectationFailure (show problem)
              Right identity -> identity.identityCohort `shouldBe` CohortName "released"

    it "returns success for help" do
      runWithArgs ["--help"] `shouldReturnCode` ExitSuccess

    it "rejects a pinned knob absent from every selected scenario" $
      withSystemTempDirectory "kenshou-plan-pin" \root -> do
        let output = root </> "run-plan.json"
        runWithArgs
          [ "plan",
            "--all",
            "--select",
            "keiro/outbox/soak/table-growth-reduced",
            "--set",
            "diagnose.major-gc-interval-ms=5000",
            "--out",
            output
          ]
          `shouldReturnCode` ExitFailure 2
        doesFileExist output `shouldReturn` False

    it "returns success for command-specific help" do
      runWithArgs ["record", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["attest", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["history", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["run", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "fetch", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "verify", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "status", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "lease", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "release", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "watch", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "route", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "submit", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "run", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "probe", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "pair", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "overhead", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "resume", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "payload", "publish", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["cell", "payload", "show", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["help", "cells"] `shouldReturnCode` ExitSuccess

    it "shows a payload only when its bundle exists at the recorded size" $
      withSystemTempDirectory "kenshou-cell-payload" \root -> do
        store <- newFileStore root
        let descriptor = "../kenshou-remote/test/golden/payload.json"
            bundle = ObjectName "payloads/sha256/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.nar.zst"
            showPayload = ["cell", "payload", "show", descriptor]
        withCellStore root do
          runWithArgs showPayload `shouldReturnCode` ExitFailure 1
          _ <- store.putObject (Bucket "control") bundle "application/octet-stream" DoesNotExist "xx"
          runWithArgs showPayload `shouldReturnCode` ExitFailure 1
          _ <- store.putObject (Bucket "control") bundle "application/octet-stream" NoPrecondition "x"
          runWithArgs showPayload `shouldReturnCode` ExitSuccess

    it "rejects malformed cell result identifiers and URIs" do
      runWithArgs ["cell", "fetch", "--results-bucket", "test-results", "not-a-run-id", "--out", "test-output"] `shouldReturnCode` ExitFailure 2
      runWithArgs ["cell", "verify", "gs://test-results/runs/not-a-run-id"] `shouldReturnCode` ExitFailure 2

    it "distinguishes an unavailable cell tree from invalid evidence" do
      runWithArgs ["cell", "verify", "test/fixtures/does-not-exist"] `shouldReturnCode` ExitFailure 4
      runWithArgs ["cell", "verify", leakingRun] `shouldReturnCode` ExitFailure 1

    it "acquires, reports and releases a lease through the file-backed cell CLI" $
      withSystemTempDirectory "kenshou-cell-cli" \root -> do
        store <- newFileStore root
        descriptor <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        let control = Bucket "tan-nb-exp-cells-control"
            leaseObject = ObjectName "cells/alpha/lease.json"
            common = ["--cell", "alpha", "--control-bucket", "tan-nb-exp-cells-control"]
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist descriptor
        withCellStore root do
          runWithArgs (["cell", "status"] <> common <> ["--json"]) `shouldReturnCode` ExitSuccess
          runWithArgs (["cell", "lease"] <> common <> ["--purpose", "cli-test"]) `shouldReturnCode` ExitSuccess
          stored <- store.getObject control leaseObject
          record <- case stored of
            Just (bytes, _) -> case Aeson.eitherDecode bytes of
              Right lease -> pure (lease :: Lease)
              Left problem -> expectationFailure problem >> error "unreachable"
            Nothing -> expectationFailure "lease was not published" >> error "unreachable"
          runWithArgs (["cell", "status"] <> common) `shouldReturnCode` ExitSuccess
          runWithArgs (["cell", "release"] <> common <> ["--lease-id", Text.unpack (renderRunId record.leaseId)]) `shouldReturnCode` ExitSuccess
          store.statObject control leaseObject `shouldReturn` Nothing

    it "routes a public plan through file-backed cell descriptors" $
      withSystemTempDirectory "kenshou-cell-route" \root -> do
        store <- newFileStore root
        descriptor <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptor :: Either String CellDescriptor)
        let control = Bucket "tan-nb-exp-cells-control"
            outDir = root </> "routed"
            common = ["cell", "route", "--cell", "beta", "--cell", "alpha", "--control-bucket", "tan-nb-exp-cells-control", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json"]
        _ <- store.putObject control (ObjectName "cells/beta/descriptor.json") "application/json" DoesNotExist (Aeson.encode (observed {name = "beta", postgresMajor = 17}))
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist descriptor
        withCellStore root do
          runWithArgs (common <> ["--out", outDir, "--coerce-durable"]) `shouldReturnCode` ExitSuccess
          doesFileExist (outDir </> "plan.alpha.json") `shouldReturn` True
          doesFileExist (outDir </> "plan.beta.json") `shouldReturn` False
          report <- Aeson.eitherDecodeFileStrict' (outDir </> "unroutable.json") >>= either fail pure
          case report of
            Aeson.Object fields -> KeyMap.lookup "schema" fields `shouldBe` Just (Aeson.String "kenshou.cell-route/v1")
            _ -> expectationFailure "expected route report"
          runWithArgs (common <> ["--out", outDir, "--coerce-durable"]) `shouldReturnCode` ExitFailure 2
          runWithArgs (common <> ["--out", root </> "refused"]) `shouldReturnCode` ExitFailure 2
          doesFileExist (root </> "refused" </> "unroutable.json") `shouldReturn` True

    it "uses a matching capability cache and ignores one from an old descriptor" $
      withSystemTempDirectory "kenshou-cell-capability-route" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        descriptor <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        probeId <- newRunId
        now <- getCurrentTime
        let control = Bucket "tan-nb-exp-cells-control"
            directory = root </> "capabilities"
            rulesPath = root </> "rules.json"
            cachePath = directory </> "alpha.capabilities.json"
            command outDir = ["cell", "route", "--cell", "alpha", "--control-bucket", "tan-nb-exp-cells-control", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--routing-rules", rulesPath, "--out", outDir, "--coerce-durable"]
            cache digest = object ["schema" .= ("kenshou.cell-capabilities/v1" :: Text), "cell" .= ("alpha" :: Text), "descriptorSha256" .= digest, "probedBy" .= renderRunId probeId, "probedAt" .= now, "capabilities" .= object ["postgres.pg_partman" .= False]]
            rule = object ["when" .= object ["scenario" .= ("selftest/kernel/**" :: Text)], "requires" .= ("postgres.pg_partman" :: Text), "why" .= ("requires extension" :: Text)]
        createDirectoryIfMissing True directory
        LazyByteString.writeFile rulesPath (Aeson.encode [rule])
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist descriptorBytes
        withCellStore root $ withCapabilityDir directory do
          LazyByteString.writeFile cachePath (Aeson.encode (cache (descriptorDigest descriptor)))
          runWithArgs (command (root </> "denied")) `shouldReturnCode` ExitFailure 2
          doesFileExist (root </> "denied" </> "plan.alpha.json") `shouldReturn` False
          LazyByteString.writeFile cachePath (Aeson.encode (cache (Text.replicate 64 "0")))
          runWithArgs (command (root </> "unprobed")) `shouldReturnCode` ExitSuccess
          doesFileExist (root </> "unprobed" </> "plan.alpha.json") `shouldReturn` True

    it "prepares a dry-run submission under an existing file-backed lease" $
      withSystemTempDirectory "kenshou-cell-submit" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            location = ["--cell", "alpha", "--control-bucket", "control"]
            outDir = root </> "session"
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        withCellStore root do
          runWithArgs (["cell", "lease"] <> location <> ["--purpose", "submit-test"]) `shouldReturnCode` ExitSuccess
          stored <- store.getObject control (ObjectName "cells/alpha/lease.json")
          lease <- case stored of
            Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Lease)
            Nothing -> expectationFailure "lease was not published" >> error "unreachable"
          let common = ["cell", "submit"] <> location <> ["--lease-id", Text.unpack (renderRunId lease.leaseId), "--payload", "../kenshou-remote/test/golden/payload.json", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--out", outDir, "--dry-run"]
          runWithArgs (common <> ["--coerce-durable"]) `shouldReturnCode` ExitSuccess
          doesPathExist outDir `shouldReturn` False
          runWithArgs common `shouldReturnCode` ExitFailure 2
          template <- Aeson.eitherDecodeFileStrict' "../kenshou-remote/test/golden/cell-session.json" >>= either fail pure
          let complete = (template :: SessionJournal) {store = Text.pack ("file:" <> root), controlBucket = "control", resultsBucket = descriptor.buckets.results, leaseId = lease.leaseId, slices = []}
          createDirectoryIfMissing True outDir
          writeSessionJournal (outDir </> "session.json") complete
          runWithArgs ["cell", "resume", "--session", outDir] `shouldReturnCode` ExitSuccess

    it "releases a one-command lease when plan preparation fails" $
      withSystemTempDirectory "kenshou-cell-run" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outDir = root </> "run-session"
            command = ["cell", "run", "--cell", "alpha", "--control-bucket", "control", "--payload", "../kenshou-remote/test/golden/payload.json", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--out", outDir]
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        withCellStore root do
          runWithArgs command `shouldReturnCode` ExitFailure 2
          store.statObject control (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing
          doesPathExist outDir `shouldReturn` False

    it "checkpoints a rejected one-command submission and releases its lease" $
      withSystemTempDirectory "kenshou-cell-run-rejected" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outDir = root </> "run-session"
            command = ["cell", "run", "--cell", "alpha", "--control-bucket", "control", "--payload", "../kenshou-remote/test/golden/payload.json", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--out", outDir, "--coerce-durable"]
            awaitMarker = do
              objects <- store.listObjects control "cells/alpha/submissions/"
              case find (Text.isSuffixOf "/submission.json" . (.unObjectName) . fst) objects of
                Nothing -> threadDelay 10000 >> awaitMarker
                Just (name, _) -> do
                  stored <- store.getObject control name
                  case stored of
                    Nothing -> expectationFailure "submission marker disappeared"
                    Just (bytes, _) -> do
                      submission <- either fail pure (Aeson.eitherDecode bytes :: Either String Submission)
                      now <- getCurrentTime
                      let prefix = "cells/alpha/submissions/" <> renderRunId submission.runId <> "/rejected.json"
                      _ <- store.putObject control (ObjectName prefix) "application/json" DoesNotExist (Aeson.encode (Rejected submission.runId "fixture-rejected" now))
                      pure ()
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        worker <- forkIO awaitMarker
        ( withCellStore root do
            result <- timeout 15000000 (runWithArgs command)
            result `shouldBe` Just (ExitFailure 4)
            store.statObject control (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing
            journal <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
            fmap (.state) journal.slices `shouldBe` [SliceRejected]
          )
          `finally` killThread worker

    it "fetches and verifies a sealed one-command submission" $
      withSystemTempDirectory "kenshou-cell-run-sealed" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            results = Bucket observed.buckets.results
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outDir = root </> "run-session"
            command = ["cell", "run", "--cell", "alpha", "--control-bucket", "control", "--payload", "../kenshou-remote/test/golden/payload.json", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--out", outDir, "--coerce-durable"]
            awaitMarker = do
              objects <- store.listObjects control "cells/alpha/submissions/"
              case find (Text.isSuffixOf "/submission.json" . (.unObjectName) . fst) objects of
                Nothing -> threadDelay 10000 >> awaitMarker
                Just (name, _) -> do
                  marker <- store.getObject control name
                  submission <- case marker of
                    Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Submission)
                    Nothing -> fail "submission marker disappeared"
                  journal <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
                  nestedId <- case journal.slices of
                    [slice] -> case slice.runIds of
                      [identifier] -> pure identifier
                      _ -> fail "expected one nested run"
                    _ -> fail "expected one cell slice"
                  let prefix = "cells/alpha/submissions/" <> renderRunId submission.runId <> "/"
                  work <- store.getObject control (ObjectName (prefix <> "work"))
                  workBytes <- case work of
                    Just (bytes, _) -> pure bytes
                    Nothing -> fail "submission work disappeared"
                  now <- getCurrentTime
                  let payloadDigest = submission.payload.bundle.sha256
                      nestedBytes = Aeson.encode (object ["schema" .= ("kenshou.run-result/v1" :: Text), "runId" .= nestedId, "scenario" .= ("selftest/kernel/correctness/postgres-roundtrip" :: Text), "outcome" .= Outcome.Passed, "fingerprint" .= object ["cell" .= object ["payload" .= object ["bundleSha256" .= payloadDigest]]]])
                      nestedInfo = workObjectFor "application/json" nestedBytes
                      nestedManifest = Manifest nestedId now [ManifestFile "run-result.json" ("sha256:" <> nestedInfo.sha256) (fromIntegral nestedInfo.bytes) "application/json"]
                      files =
                        [ ("submission/work", workBytes),
                          ("submission/submission.json", Aeson.encode submission),
                          ("cell/result.json", Aeson.encode (CellRunResult submission.runId "alpha" submission.leaseId 1 Completed (Just 0) Nothing [])),
                          ("output/" <> renderRunId nestedId <> "/run-result.json", nestedBytes),
                          ("output/" <> renderRunId nestedId <> "/manifest.json", Aeson.encode nestedManifest)
                        ]
                      artifactFor (path, bytes) = let info = workObjectFor "application/json" bytes in Artifact path info.sha256 info.bytes "application/json"
                      manifest = CellManifest submission.runId "alpha" submission.leaseId 1 now "0.1.0" (ManifestPayload payloadDigest submission.payload.storePath) Completed 3600 (map artifactFor files)
                      manifestBytes = Aeson.encode manifest
                      manifestDigest = (workObjectFor "application/json" manifestBytes).sha256
                  mapM_
                    ( \(path, bytes) -> do
                        _ <- store.putObject results (ObjectName ("runs/" <> renderRunId submission.runId <> "/" <> path)) "application/json" DoesNotExist bytes
                        pure ()
                    )
                    files
                  _ <- store.putObject results (ObjectName ("runs/" <> renderRunId submission.runId <> "/manifest.json")) "application/json" DoesNotExist manifestBytes
                  _ <- store.putObject control (ObjectName (prefix <> "status.json")) "application/json" DoesNotExist (Aeson.encode (CellStatus submission.runId Sealed (Just 1) now Nothing (LogChunks 0 0) (Just Completed) (Just manifestDigest) (Just [])))
                  pure ()
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        worker <- forkIO awaitMarker
        ( withCellStore root do
            result <- timeout 15000000 (runWithArgs command)
            result `shouldBe` Just ExitSuccess
            store.statObject control (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing
            journal <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
            fmap (.state) journal.slices `shouldBe` [SliceVerified]
            case journal.slices of
              [slice] -> doesFileExist (root </> Text.unpack (renderRunId slice.cellRun) </> "cell-run.json") `shouldReturn` True
              _ -> expectationFailure "expected one verified cell slice"
          )
          `finally` killThread worker

    it "runs overhead slots behind one cell lease and links their verified run directories" $
      withSystemTempDirectory "kenshou-cell-overhead" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            results = Bucket observed.buckets.results
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outRoot = root </> "overhead-output"
            command =
              [ "cell",
                "overhead",
                "keiro/command/benchmark/throughput-latency",
                "--cell",
                "alpha",
                "--control-bucket",
                "control",
                "--payload",
                "../kenshou-remote/test/golden/payload.json",
                "--arms",
                "tracing=off,noop",
                "--trials",
                "3",
                "--settle-seconds",
                "0",
                "--retries",
                "0",
                "--policy",
                "../policies/telemetry-overhead.json",
                "--out",
                outRoot
              ]
            awaitMarkers seen = do
              objects <- store.listObjects control "cells/alpha/submissions/"
              case find (\(name, _) -> Text.isSuffixOf "/submission.json" name.unObjectName && name `Set.notMember` seen) objects of
                Nothing -> threadDelay 10000 >> awaitMarkers seen
                Just (name, _) -> do
                  marker <- store.getObject control name
                  submission <- case marker of
                    Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Submission)
                    Nothing -> fail "overhead submission marker disappeared"
                  let prefix = "cells/alpha/submissions/" <> renderRunId submission.runId <> "/"
                  work <- store.getObject control (ObjectName (prefix <> "work"))
                  workBytes <- case work of
                    Just (bytes, _) -> pure bytes
                    Nothing -> fail "overhead work disappeared"
                  workValue <- either fail pure (Aeson.eitherDecode workBytes :: Either String Value)
                  nestedId <- case workValue of
                    Aeson.Object fields -> case KeyMap.lookup "runs" fields of
                      Just (Aeson.Array entries) -> case toList entries of
                        [Aeson.Object entry] -> case KeyMap.lookup "runId" entry of
                          Just value -> case Aeson.fromJSON value of Aeson.Success identifier -> pure identifier; Aeson.Error problem -> fail problem
                          Nothing -> fail "overhead work has no nested run ID"
                        _ -> fail "overhead work must contain one valid run entry"
                      _ -> fail "overhead work has no runs"
                    _ -> fail "overhead work is invalid"
                  now <- getCurrentTime
                  let sequenceNumber = Set.size seen + 1
                      payloadDigest = submission.payload.bundle.sha256
                      nestedBytes = Aeson.encode (object ["schema" .= ("kenshou.run-result/v1" :: Text), "runId" .= nestedId, "scenario" .= ("keiro/command/benchmark/throughput-latency" :: Text), "outcome" .= Outcome.Passed, "fingerprint" .= object ["cell" .= object ["payload" .= object ["bundleSha256" .= payloadDigest]]]])
                      nestedInfo = workObjectFor "application/json" nestedBytes
                      nestedManifest = Manifest nestedId now [ManifestFile "run-result.json" ("sha256:" <> nestedInfo.sha256) (fromIntegral nestedInfo.bytes) "application/json"]
                      files =
                        [ ("submission/work", workBytes),
                          ("submission/submission.json", Aeson.encode submission),
                          ("cell/result.json", Aeson.encode (CellRunResult submission.runId "alpha" submission.leaseId sequenceNumber Completed (Just 0) Nothing [])),
                          ("output/" <> renderRunId nestedId <> "/run-result.json", nestedBytes),
                          ("output/" <> renderRunId nestedId <> "/manifest.json", Aeson.encode nestedManifest)
                        ]
                      artifactFor (path, bytes) = let info = workObjectFor "application/json" bytes in Artifact path info.sha256 info.bytes "application/json"
                      manifest = CellManifest submission.runId "alpha" submission.leaseId sequenceNumber now "0.1.0" (ManifestPayload payloadDigest submission.payload.storePath) Completed 3600 (map artifactFor files)
                      manifestBytes = Aeson.encode manifest
                      manifestDigest = (workObjectFor "application/json" manifestBytes).sha256
                  mapM_ (\(path, bytes) -> do _ <- store.putObject results (ObjectName ("runs/" <> renderRunId submission.runId <> "/" <> path)) "application/json" DoesNotExist bytes; pure ()) files
                  _ <- store.putObject results (ObjectName ("runs/" <> renderRunId submission.runId <> "/manifest.json")) "application/json" DoesNotExist manifestBytes
                  _ <- store.putObject control (ObjectName (prefix <> "status.json")) "application/json" DoesNotExist (Aeson.encode (CellStatus submission.runId Sealed (Just sequenceNumber) now Nothing (LogChunks 0 0) (Just Completed) (Just manifestDigest) (Just [])))
                  if sequenceNumber < 6 then awaitMarkers (Set.insert name seen) else pure ()
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        worker <- forkIO (awaitMarkers Set.empty)
        ( withCellStore root do
            result <- timeout 30000000 (runWithArgs command)
            result `shouldBe` Just (ExitFailure 4)
            store.statObject control (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing
            [invocation] <- listDirectory outRoot
            state <- loadOverheadState (outRoot </> invocation) >>= either fail pure
            length state.slots `shouldBe` 6
            all (.complete) state.slots `shouldBe` True
            observations <-
              traverse
                ( \slot -> do
                    runId <- case reverse slot.runIds of identifier : _ -> pure identifier; [] -> fail "overhead slot has no run"
                    doesFileExist (outRoot </> invocation </> "runs" </> Text.unpack (renderRunId runId) </> "manifest.json") `shouldReturn` True
                    journal <- readSessionJournal (outRoot </> invocation </> "cell-sessions" </> Text.unpack (renderRunId runId) </> "session.json") >>= either (fail . Text.unpack) pure
                    slice <- case journal.slices of [one] -> pure one; _ -> fail "overhead child must have one slice"
                    sealed <- store.getObject results (ObjectName ("runs/" <> renderRunId slice.cellRun <> "/manifest.json"))
                    manifest <- case sealed of
                      Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String CellManifest)
                      Nothing -> fail "overhead child has no cell manifest"
                    pure (journal.leaseId, manifest.leaseSequence)
                )
                state.slots
            length (Set.fromList (fmap fst observations)) `shouldBe` 1
            List.sort (fmap snd observations) `shouldBe` [1 .. 6]
            resumed <- timeout 15000000 (runWithArgs (command <> ["--resume"]))
            resumed `shouldBe` Just (ExitFailure 4)
            markers <- store.listObjects control "cells/alpha/submissions/"
            length (filter (Text.isSuffixOf "/submission.json" . (.unObjectName) . fst) markers) `shouldBe` 6
          )
          `finally` killThread worker

    it "leaves a detached single-slice lease alive and collects its rejection later" $
      withSystemTempDirectory "kenshou-cell-run-detached" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        let control = Bucket "control"
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outDir = root </> "run-session"
            leaseObject = ObjectName "cells/alpha/lease.json"
            command = ["cell", "run", "--cell", "alpha", "--control-bucket", "control", "--payload", "../kenshou-remote/test/golden/payload.json", "--plan", "../kenshou-core/test/golden/run-plan.minimal.json", "--out", outDir, "--coerce-durable", "--detach"]
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        withCellStore root do
          runWithArgs command `shouldReturnCode` ExitSuccess
          journal <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
          journal.leaseMode `shouldBe` Detached
          fmap (.state) journal.slices `shouldBe` [SliceSubmitted]
          leaseStored <- store.getObject control leaseObject
          lease <- case leaseStored of
            Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Lease)
            Nothing -> expectationFailure "detached lease was released" >> error "unreachable"
          slice <- case journal.slices of
            [entry] -> pure entry
            _ -> expectationFailure "expected one detached slice" >> error "unreachable"
          lease.ttlSeconds `shouldSatisfy` (>= fromIntegral slice.submission.limits.wallClockSeconds + 600)
          runWithArgs ["cell", "resume", "--session", outDir] `shouldReturnCode` ExitFailure 4
          store.statObject control leaseObject >>= (`shouldSatisfy` (maybe False (const True)))
          now <- getCurrentTime
          let rejectedObject = ObjectName ("cells/alpha/submissions/" <> renderRunId slice.cellRun <> "/rejected.json")
          _ <- store.putObject control rejectedObject "application/json" DoesNotExist (Aeson.encode (Rejected slice.cellRun "fixture-rejected" now))
          runWithArgs ["cell", "resume", "--session", outDir] `shouldReturnCode` ExitFailure 4
          store.statObject control leaseObject `shouldReturn` Nothing
          finished <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
          fmap (.state) finished.slices `shouldBe` [SliceRejected]
          runWithArgs command `shouldReturnCode` ExitFailure 2
          store.statObject control leaseObject `shouldReturn` Nothing

    it "rebinds a submitted marker that a prior held lease never accepted" $
      withSystemTempDirectory "kenshou-cell-resume-unaccepted" \root -> do
        store <- newFileStore root
        descriptorBytes <- LazyByteString.readFile "../kenshou-remote/test/golden/cell/cell.descriptor.v1.json"
        observed <- either fail pure (Aeson.eitherDecode descriptorBytes :: Either String CellDescriptor)
        template <- Aeson.eitherDecodeFileStrict' "../kenshou-remote/test/golden/cell-session.json" >>= either fail pure
        let control = Bucket "control"
            descriptor = observed {buckets = observed.buckets {control = "control"}}
            outDir = root </> "session"
            leaseObject = ObjectName "cells/alpha/lease.json"
        _ <- store.putObject control (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist (Aeson.encode descriptor)
        withCellStore root do
          runWithArgs ["cell", "lease", "--cell", "alpha", "--control-bucket", "control", "--purpose", "old-session"] `shouldReturnCode` ExitSuccess
          oldStored <- store.getObject control leaseObject
          oldLease <- case oldStored of
            Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Lease)
            Nothing -> expectationFailure "old lease missing" >> error "unreachable"
          fixtureSlice <- case (template :: SessionJournal).slices of
            [entry] -> pure entry
            _ -> expectationFailure "expected one fixture slice" >> error "unreachable"
          let fixtureSubmission = fixtureSlice.submission
              fixturePayload = fixtureSubmission.payload
              fixtureBundle = fixturePayload.bundle
              payload = fixturePayload {bundle = fixtureBundle {uri = "gs://control/payloads/sha256/" <> fixtureBundle.sha256 <> ".nar.zst"}}
              oldSubmission = fixtureSubmission {leaseId = oldLease.leaseId, payload = payload, work = workObjectFor "application/json" "{}"}
              oldSlice = fixtureSlice {submission = oldSubmission, state = SliceSubmitted}
              journal = template {store = Text.pack ("file:" <> root), controlBucket = "control", resultsBucket = descriptor.buckets.results, leaseId = oldLease.leaseId, slices = [oldSlice]}
              oldMarker = ObjectName ("cells/alpha/submissions/" <> renderRunId oldSlice.cellRun <> "/submission.json")
              awaitRetry = do
                objects <- store.listObjects control "cells/alpha/submissions/"
                case find (\(name, _) -> name /= oldMarker && Text.isSuffixOf "/submission.json" name.unObjectName) objects of
                  Nothing -> threadDelay 10000 >> awaitRetry
                  Just (name, _) -> do
                    stored <- store.getObject control name
                    submission <- case stored of
                      Just (bytes, _) -> either fail pure (Aeson.eitherDecode bytes :: Either String Submission)
                      Nothing -> fail "retry marker disappeared"
                    now <- getCurrentTime
                    let rejected = ObjectName ("cells/alpha/submissions/" <> renderRunId submission.runId <> "/rejected.json")
                    _ <- store.putObject control rejected "application/json" DoesNotExist (Aeson.encode (Rejected submission.runId "fixture-rejected" now))
                    pure ()
          createDirectoryIfMissing True (outDir </> "slice-0")
          LazyByteString.writeFile (outDir </> "slice-0/work.json") "{}"
          writeSessionJournal (outDir </> "session.json") journal
          _ <- store.putObject control oldMarker "application/json" DoesNotExist (Aeson.encode oldSubmission)
          runWithArgs ["cell", "release", "--cell", "alpha", "--control-bucket", "control", "--lease-id", Text.unpack (renderRunId oldLease.leaseId)] `shouldReturnCode` ExitSuccess
          worker <- forkIO awaitRetry
          ( do
              result <- timeout 15000000 (runWithArgs ["cell", "resume", "--session", outDir])
              result `shouldBe` Just (ExitFailure 4)
              finished <- readSessionJournal (outDir </> "session.json") >>= either (fail . Text.unpack) pure
              fmap (.state) finished.slices `shouldBe` [SliceRejected]
              fmap (.cellRun) finished.slices `shouldSatisfy` (/= [oldSlice.cellRun])
              store.statObject control leaseObject `shouldReturn` Nothing
            )
            `finally` killThread worker

    it "reads scenario history from a bundle" do
      runWithArgs ["history", "--bundle", "../docs/verification", "--scenario", "selftest/kernel/correctness/always-pass", "--json"] `shouldReturnCode` ExitSuccess

    it "requires one record source" do
      runWithArgs ["record", "--purpose", "release"] `shouldReturnCode` ExitFailure 2
      runWithArgs ["record", "a-run", "--comparison", "comparison.json", "--purpose", "release"] `shouldReturnCode` ExitFailure 2

    it "rejects a human anomaly exception without an interactive terminal" do
      runWithArgs ["attest", "invalid", "--project", "fixture", "--accept-anomaly", "--authority", "human:fixture", "--reason", "fixture"] `shouldReturnCode` ExitFailure 2

    it "returns 2 for an unknown subcommand" do
      runWithArgs ["cohort", "bogus"] `shouldReturnCode` ExitFailure 2

    it "returns 1 when offline leak diagnosis finds growth" do
      runWithArgs ["diagnose", "leak", leakingRun] `shouldReturnCode` ExitFailure 1

    it "returns 1 when an offline stall diagnosis exists" do
      runWithArgs ["diagnose", "stall", stalledRun] `shouldReturnCode` ExitFailure 1

    it "returns 0 when no offline stall diagnosis exists" do
      runWithArgs ["diagnose", "stall", leakingRun] `shouldReturnCode` ExitSuccess

    it "returns 3 when leak evidence is insufficient" do
      runWithArgs ["diagnose", "leak", stalledRun] `shouldReturnCode` ExitFailure 3

    it "returns 4 when diagnosis input is unavailable" do
      runWithArgs ["diagnose", "leak", "test/fixtures/does-not-exist"] `shouldReturnCode` ExitFailure 4

    it "returns 2 for invalid diagnose syntax" do
      runWithArgs ["diagnose", "leak", "--bogus"] `shouldReturnCode` ExitFailure 2

    it "does not mutate a sealed run manifest" do
      before <- Text.readFile (leakingRun <> "/manifest.json")
      _ <- runWithArgs ["diagnose", "leak", leakingRun]
      after <- Text.readFile (leakingRun <> "/manifest.json")
      after `shouldBe` before

  describe "version" do
    it "includes the cabal package version and a short revision" do
      appVersionWithGit `shouldSatisfy` Text.isPrefixOf "kenshou v0.1.0.0 ("
      Text.dropAround (`elem` ['(', ')']) (Text.takeWhileEnd (/= ' ') appVersionWithGit)
        `shouldSatisfy` (\revision -> revision == "dirty" || Text.length revision == 7)

shouldReturnCode :: IO ExitCode -> ExitCode -> IO ()
shouldReturnCode action expected = action >>= (`shouldBe` expected)

leakingRun :: FilePath
leakingRun = "../kenshou-diagnose/test/fixtures/run-leaking"

stalledRun :: FilePath
stalledRun = "../kenshou-diagnose/test/fixtures/run-stalled"

okEvent :: Int -> Value
okEvent value = object ["type" .= ("custom" :: Text), "name" .= ("ok" :: Text), "payload" .= object ["value" .= value]]

errorEvent :: Text -> Value
errorEvent message = object ["type" .= ("error" :: Text), "message" .= message]

doneEvent :: Value
doneEvent = object ["type" .= ("done" :: Text)]

withCellStore :: FilePath -> IO value -> IO value
withCellStore root operation = bracket (lookupEnv "KENSHOU_CELL_STORE") (restore "KENSHOU_CELL_STORE") \_ ->
  bracket (lookupEnv "KENSHOU_GCP_ALLOWED_PROJECTS") (restore "KENSHOU_GCP_ALLOWED_PROJECTS") \_ -> do
    setEnv "KENSHOU_CELL_STORE" ("file:" <> root)
    setEnv "KENSHOU_GCP_ALLOWED_PROJECTS" "tan-nb-exp"
    operation
  where
    restore name Nothing = unsetEnv name
    restore name (Just prior) = setEnv name prior

withCapabilityDir :: FilePath -> IO value -> IO value
withCapabilityDir directory operation = bracket (lookupEnv "KENSHOU_CELL_CAPABILITIES_DIR") restore \_ -> do
  setEnv "KENSHOU_CELL_CAPABILITIES_DIR" directory
  operation
  where
    restore Nothing = unsetEnv "KENSHOU_CELL_CAPABILITIES_DIR"
    restore (Just prior) = setEnv "KENSHOU_CELL_CAPABILITIES_DIR" prior

withEnvVariable :: String -> String -> IO value -> IO value
withEnvVariable name selected operation = bracket (lookupEnv name) restore \_ -> do
  setEnv name selected
  operation
  where
    restore Nothing = unsetEnv name
    restore (Just prior) = setEnv name prior
