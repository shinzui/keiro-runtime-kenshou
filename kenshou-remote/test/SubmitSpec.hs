module SubmitSpec (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseHandle, LeaseRequest (..), acquireLease, leaseSnapshot, requestCancel)
import Kenshou.Remote.Cell.Submit (PublishOutcome (..), publishSubmission, workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cell submission publication" do
  it "publishes work before the create-only marker without changing the lease sequence" $ withSystemTempDirectory "kenshou-submit" \root -> do
    base <- newFileStore root
    handle <- acquireLease base cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    writes <- newIORef []
    let store =
          base
            { putObject = \bucket name media pre bytes -> do
                modifyIORef' writes (<> [(name, pre)])
                base.putObject bucket name media pre bytes
            }
        prefix = submissionPrefix submission
        workName = ObjectName (prefix <> "work")
        markerName = ObjectName (prefix <> "submission.json")
    publishSubmission store cellRef handle submission workBytes `shouldReturn` Submitted
    readIORef writes `shouldReturn` [(workName, DoesNotExist), (markerName, DoesNotExist)]
    fmap fst <$> base.getObject cellRef.controlBucket workName `shouldReturn` Just workBytes
    marker <- base.getObject cellRef.controlBucket markerName
    fmap (eitherDecode . fst) marker `shouldBe` Just (Right submission)
    lease <- leaseSnapshot handle
    lease.runsStarted `shouldBe` 0
    publishSubmission store cellRef handle submission workBytes `shouldReturn` WorkAlreadyExists
    readIORef writes `shouldReturn` [(workName, DoesNotExist), (markerName, DoesNotExist), (workName, DoesNotExist)]

  it "refuses incorrect work metadata before writing either object" $ withSystemTempDirectory "kenshou-submit" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    let badWork = WorkObject "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" submission.work.bytes submission.work.mediaType
        bad = submission {work = badWork}
    publishSubmission store cellRef handle bad workBytes `shouldThrow` anyIOException
    store.listObjects cellRef.controlBucket (submissionPrefix submission) `shouldReturn` []

  it "refuses a payload bundle from another control bucket" $ withSystemTempDirectory "kenshou-submit" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    let bundle = submission.payload.bundle
        wrongBucket = submission {payload = submission.payload {bundle = bundle {uri = "gs://elsewhere/payloads/sha256/" <> bundle.sha256 <> ".nar.zst"}}}
    publishSubmission store cellRef handle wrongBucket workBytes `shouldThrow` anyIOException
    store.listObjects cellRef.controlBucket (submissionPrefix submission) `shouldReturn` []

  it "leaves an orphan work object if the lease is cancelled during upload" $ withSystemTempDirectory "kenshou-submit" \root -> do
    base <- newFileStore root
    handle <- acquireLease base cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    let store =
          base
            { putObject = \bucket name media pre bytes -> do
                result <- base.putObject bucket name media pre bytes
                if name == ObjectName (submissionPrefix submission <> "work")
                  then do
                    requestCancel base cellRef (Just submission.leaseId) False `shouldReturn` True
                    pure result
                  else pure result
            }
    publishSubmission store cellRef handle submission workBytes `shouldReturn` LostLease
    work <- base.statObject cellRef.controlBucket (ObjectName (submissionPrefix submission <> "work"))
    work `shouldSatisfy` (/= Nothing)
    base.statObject cellRef.controlBucket (ObjectName (submissionPrefix submission <> "submission.json")) `shouldReturn` Nothing

  it "reports a marker collision without overwriting it" $ withSystemTempDirectory "kenshou-submit" \root -> do
    base <- newFileStore root
    handle <- acquireLease base cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    let markerName = ObjectName (submissionPrefix submission <> "submission.json")
        store =
          base
            { putObject = \bucket name media pre bytes ->
                if name == markerName then pure PreconditionFailed else base.putObject bucket name media pre bytes
            }
    publishSubmission store cellRef handle submission workBytes `shouldReturn` SubmissionAlreadyExists
    base.statObject cellRef.controlBucket markerName `shouldReturn` Nothing

fixtureFor :: LeaseHandle -> IO Submission
fixtureFor handle = do
  bytes <- LazyByteString.readFile "test/golden/cell/cell.submission.v1.json"
  fixture <- either (ioError . userError) pure (eitherDecode bytes)
  identifier <- newRunId
  lease <- leaseSnapshot handle
  let bundle = fixture.payload.bundle
      payload = fixture.payload {bundle = bundle {uri = "gs://control/payloads/sha256/" <> bundle.sha256 <> ".nar.zst"}}
  pure fixture {runId = identifier, leaseId = lease.leaseId, payload = payload, work = workObjectFor "application/json" workBytes}

submissionPrefix :: Submission -> Text
submissionPrefix submission = "cells/alpha/submissions/" <> renderRunId submission.runId <> "/"

workBytes :: LazyByteString.ByteString
workBytes = "{\"schema\":\"kenshou.run-plan/v1\",\"runs\":[]}"

cellRef :: CellRef
cellRef = CellRef "alpha" (Bucket "control")

request :: LeaseRequest
request = LeaseRequest "tester@workstation" "verification" 120

expectAcquired :: AcquireOutcome -> IO LeaseHandle
expectAcquired (Acquired handle) = pure handle
expectAcquired _ = expectationFailure "expected acquired lease" >> error "unreachable"
