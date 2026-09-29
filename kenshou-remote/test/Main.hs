module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import DebugSpec qualified
import DocsSpec qualified
import ExecSpec qualified
import FetchSpec qualified
import GcsSpec qualified
import HealthSpec qualified
import Kenshou.Core.Cohort (CohortIdentity (..), CohortName (..), PlanHash (..))
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), CohortCheck (..), Harness (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import Kenshou.Remote.Store.File (newFileStore)
import LeaseSpec qualified
import PairSpec qualified
import ParitySpec qualified
import PayloadSpec qualified
import PrepareSpec qualified
import SessionSpec qualified
import SubmitSpec qualified
import System.Directory (getFileSize)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import WatchSpec qualified

main :: IO ()
main =
  getArgs >>= \case
    ["--claim", root] -> do
      store <- newFileStore root
      result <- store.putObject (Bucket "control") (ObjectName "cells/alpha/lease.json") "application/json" DoesNotExist "claim"
      putStrLn case result of
        Written _ -> "written"
        PreconditionFailed -> "precondition-failed"
    _ -> hspec tests

tests :: Spec
tests = do
  DebugSpec.spec
  DocsSpec.spec
  ExecSpec.execSpec
  FetchSpec.spec
  GcsSpec.spec
  HealthSpec.spec
  LeaseSpec.spec
  PairSpec.pairSpec
  ParitySpec.spec
  PayloadSpec.spec
  PrepareSpec.spec
  SessionSpec.spec
  SubmitSpec.spec
  WatchSpec.spec
  describe "Kenshou payload descriptor" do
    it "round-trips the complete cell payload and Nix cohort identity" do
      eitherDecode (encode examplePayload) `shouldBe` Right examplePayload

    it "rejects a bundle URI that disagrees with its content digest" do
      let badBundle = examplePayload.cell.bundle {uri = "gs://control/payloads/sha256/other.nar.zst"}
          bad = examplePayload {cell = examplePayload.cell {bundle = badBundle}}
      (eitherDecode (encode bad) :: Either String PayloadDescriptor) `shouldSatisfy` isLeft

    it "requires the Kenshou entry point even though the cell protocol accepts other commands" do
      let generic = examplePayload {cell = examplePayload.cell {command = ["bin/cell-fixture-hello"]}}
      (eitherDecode (encode generic) :: Either String PayloadDescriptor) `shouldSatisfy` isLeft

  describe "file cell object store" do
    it "fences stale generations and preserves tombstones" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      store <- newFileStore root
      let bucket = Bucket "control"
          object = ObjectName "cells/alpha/lease.json"
      first <- store.putObject bucket object "application/json" DoesNotExist "first"
      firstMeta <- expectWritten first
      firstMeta.generation `shouldBe` 1
      stale <- store.putObject bucket object "application/json" DoesNotExist "stale"
      stale `shouldBe` PreconditionFailed
      next <- store.putObject bucket object "application/json" (GenerationIs firstMeta.generation) "second"
      secondMeta <- expectWritten next
      secondMeta.generation `shouldBe` 2
      store.deleteObject bucket object (GenerationIs firstMeta.generation) `shouldReturn` False
      store.deleteObject bucket object (GenerationIs secondMeta.generation) `shouldReturn` True
      store.statObject bucket object `shouldReturn` Nothing
      afterDelete <- store.putObject bucket object "application/json" DoesNotExist "third"
      thirdMeta <- expectWritten afterDelete
      thirdMeta.generation `shouldBe` 4
      stored <- store.getObject bucket object
      fmap fst stored `shouldBe` Just "third"
      store.listObjects bucket "cells/alpha/" `shouldReturn` [(object, thirdMeta)]

    it "admits exactly one concurrent create-only claim" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      store <- newFileStore root
      let bucket = Bucket "control"
          object = ObjectName "cells/alpha/lease.json"
      outcomes <- replicateM 20 newEmptyMVar
      mapM_ (\reply -> forkIO (store.putObject bucket object "application/json" DoesNotExist "claim" >>= putMVar reply)) outcomes
      results <- mapM takeMVar outcomes
      length [() | Written _ <- results] `shouldBe` 1
      length [() | PreconditionFailed <- results] `shouldBe` 19

    it "fences independent store handles in one process" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      stores <- replicateM 12 (newFileStore root)
      replies <- replicateM 12 newEmptyMVar
      let bucket = Bucket "control"
          object = ObjectName "cells/alpha/lease.json"
      mapM_ (\(store, reply) -> forkIO (store.putObject bucket object "application/json" DoesNotExist "claim" >>= putMVar reply)) (zip stores replies)
      results <- mapM takeMVar replies
      length [() | Written _ <- results] `shouldBe` 1
      length [() | PreconditionFailed <- results] `shouldBe` 11

    it "fences claims made by separate processes" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      executable <- getExecutablePath
      replies <- replicateM 4 newEmptyMVar
      mapM_ (\reply -> forkIO (readCreateProcessWithExitCode (proc executable ["--claim", root]) "" >>= putMVar reply)) replies
      results <- mapM takeMVar replies
      [exit | (exit, _, _) <- results] `shouldBe` replicate 4 ExitSuccess
      length [() | (_, output, _) <- results, output == "written\n"] `shouldBe` 1
      length [() | (_, output, _) <- results, output == "precondition-failed\n"] `shouldBe` 3

    it "streams file publication and download under one object name" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      store <- newFileStore (root </> "store")
      let bucket = Bucket "control"
          object = ObjectName "payloads/sha256/abc.nar.zst"
          source = root </> "source"
          fetched = root </> "fetched"
          bytes = LazyByteString.replicate (2 * 1024 * 1024) 'a'
      LazyByteString.writeFile source bytes
      result <- store.putFile bucket object "application/zstd" DoesNotExist source
      meta <- expectWritten result
      meta.size `shouldBe` LazyByteString.length bytes
      store.downloadTo bucket object fetched `shouldReturn` Just meta
      getFileSize fetched `shouldReturn` fromIntegral (LazyByteString.length bytes)

    it "rejects names that could escape a bucket" $ withSystemTempDirectory "kenshou-cell-store" \root -> do
      store <- newFileStore root
      store.putObject (Bucket "control") (ObjectName "../lease") "application/json" DoesNotExist "bad" `shouldThrow` anyIOException

expectWritten :: PutOutcome -> IO ObjectMeta
expectWritten (Written meta) = pure meta
expectWritten PreconditionFailed = expectationFailure "write was unexpectedly rejected" >> error "unreachable"

examplePayload :: PayloadDescriptor
examplePayload =
  PayloadDescriptor
    { cohort = "released",
      variant = "default",
      flakeAttr = "packages.x86_64-linux.kenshou-released",
      harness = Harness (Text.replicate 40 "a") False,
      cohortIdentity =
        CohortIdentity
          { identityCohort = CohortName "released",
            identityCompiler = "ghc-9.12.4",
            identityCabalVersion = "nix",
            identityOs = "linux",
            identityArch = "x86_64",
            identityIndexState = Nothing,
            identityPlanHash = PlanHash "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            identityDescriptorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            identityComponents = [],
            identityResolver = Just "nix"
          },
      cohortCheck = CohortCheck 0,
      cell =
        CellPayload
          { bundle = Bundle "gs://control/payloads/sha256/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.nar.zst" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 1,
            storePath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kenshou-released",
            narHash = "sha256-example",
            closurePaths = ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kenshou-released"],
            system = "x86_64-linux",
            command = ["bin/kenshou", "cell", "exec"]
          },
      createdAt = UTCTime (fromGregorian 2026 9 27) (secondsToDiffTime 0)
    }
