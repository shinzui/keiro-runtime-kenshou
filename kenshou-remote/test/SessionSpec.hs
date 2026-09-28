module SessionSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import FetchSpec (completeTreeWith)
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (..), CellPhase (..), CellStatus (..), LogChunks (..), Rejected (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Index (CellRunIndex (..))
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseHandle, LeaseRequest (..), acquireLease, leaseSnapshot, requestCancel)
import Kenshou.Remote.Cell.Session (SessionError (..), runSubmission)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "one leased cell submission" do
  it "stops before publication when the lease was cancelled" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    requestCancel store cellRef (Just submission.leaseId) False `shouldReturn` True
    runSubmission store cellRef (Bucket "results") handle submission workBytes (root <> "/out") (const (pure ())) `shouldReturn` Left LeaseLost
    store.listObjects cellRef.controlBucket (submissionPrefix submission) `shouldReturn` []

  it "returns the cell's rejection reason after publishing the marker" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    _ <- forkIO do
      let marker = ObjectName (submissionPrefix submission <> "submission.json")
      let awaitMarker = do
            visible <- store.statObject cellRef.controlBucket marker
            case visible of
              Nothing -> threadDelay 10000 >> awaitMarker
              Just _ -> pure ()
      awaitMarker
      now <- getCurrentTime
      _ <- store.putObject cellRef.controlBucket (ObjectName (submissionPrefix submission <> "rejected.json")) "application/json" DoesNotExist (encode (Rejected submission.runId "unsafe-command" now))
      pure ()
    runSubmission store cellRef (Bucket "results") handle submission workBytes (root <> "/out") (const (pure ())) `shouldReturn` Left (SubmissionRejected "unsafe-command")

  it "takes one submission through a sealed local protocol agent and writes the index" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    workerResult <- newEmptyMVar
    _ <- forkIO do
      completed <- try (publishSealedFixture store root submission) :: IO (Either SomeException ())
      putMVar workerResult completed
    result <- timeout 10000000 (runSubmission store cellRef (Bucket "results") handle submission workBytes (root </> "out") (const (pure ())))
    case result of
      Nothing -> expectationFailure "session did not observe the sealed result within ten seconds"
      Just (Left failure) -> expectationFailure (show failure)
      Just (Right index) -> do
        index.cellRun `shouldBe` submission.runId
        indexed <- doesFileExist (root </> "out" </> Text.unpack (renderRunId submission.runId) </> "cell-run.json")
        indexed `shouldBe` True
        worker <- takeMVar workerResult
        case worker of
          Left failure -> expectationFailure (show failure)
          Right () -> pure ()

publishSealedFixture :: ObjectStore -> FilePath -> Submission -> IO ()
publishSealedFixture store root submission = do
  let marker = ObjectName (submissionPrefix submission <> "submission.json")
      results = Bucket "results"
      resultPrefix = "runs/" <> renderRunId submission.runId <> "/"
      awaitMarker = do
        visible <- store.statObject cellRef.controlBucket marker
        case visible of
          Nothing -> threadDelay 10000 >> awaitMarker
          Just _ -> pure ()
  awaitMarker
  (sourceTree, manifest) <- completeTreeWith (root </> "fixture") submission.runId submission.leaseId False False False
  forM_ manifest.artifacts \artifact -> do
    bytes <- LazyByteString.readFile (sourceTree </> Text.unpack artifact.path)
    _ <- store.putObject results (ObjectName (resultPrefix <> artifact.path)) artifact.mediaType DoesNotExist bytes
    pure ()
  bytes <- LazyByteString.readFile (sourceTree </> "manifest.json")
  _ <- store.putObject results (ObjectName (resultPrefix <> "manifest.json")) "application/json" DoesNotExist bytes
  now <- getCurrentTime
  let digest = (workObjectFor "application/json" bytes).sha256
      status = CellStatus submission.runId Sealed (Just manifest.leaseSequence) now Nothing (LogChunks 0 0) (Just Completed) (Just digest) (Just [])
  _ <- store.putObject cellRef.controlBucket (ObjectName (submissionPrefix submission <> "status.json")) "application/json" DoesNotExist (encode status)
  pure ()

fixtureFor :: LeaseHandle -> IO Submission
fixtureFor handle = do
  bytes <- LazyByteString.readFile "test/golden/cell/cell.submission.v1.json"
  fixture <- either (ioError . userError) pure (eitherDecode bytes :: Either String Submission)
  identifier <- newRunId
  lease <- leaseSnapshot handle
  let bundle = fixture.payload.bundle
      payload = fixture.payload {bundle = bundle {uri = "gs://control/payloads/sha256/" <> bundle.sha256 <> ".nar.zst"}}
  pure (Submission identifier lease.leaseId payload (workObjectFor "application/json" workBytes) fixture.env fixture.reset fixture.limits fixture.requires fixture.labels)

submissionPrefix :: Submission -> Text
submissionPrefix submission = "cells/alpha/submissions/" <> renderRunId submission.runId <> "/"

workBytes :: LazyByteString.ByteString
workBytes = "{}"

cellRef :: CellRef
cellRef = CellRef "alpha" (Bucket "control")

request :: LeaseRequest
request = LeaseRequest "tester@workstation" "verification" 120

expectAcquired :: AcquireOutcome -> IO LeaseHandle
expectAcquired (Acquired handle) = pure handle
expectAcquired _ = expectationFailure "expected acquired lease" >> error "unreachable"
