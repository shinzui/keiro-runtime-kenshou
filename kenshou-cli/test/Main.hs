module Main (main) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, finally)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Cli (runWithArgs)
import Kenshou.Cli.Attest (FencingFacts (..), fencingFacts)
import Kenshou.Cli.Version (appVersionWithGit)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Remote.Cell.Docs (CellBuckets (..), CellDescriptor (..), Rejected (..), Submission (..))
import Kenshou.Remote.Cell.Lease (Lease (..))
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..), SliceState (..), readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (describe, expectationFailure, hspec, it, shouldBe, shouldReturn, shouldSatisfy)

main :: IO ()
main = hspec do
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
    it "returns success for help" do
      runWithArgs ["--help"] `shouldReturnCode` ExitSuccess

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
      runWithArgs ["cell", "resume", "--help"] `shouldReturnCode` ExitSuccess

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
