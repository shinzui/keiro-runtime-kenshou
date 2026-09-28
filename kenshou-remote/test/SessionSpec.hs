module SessionSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import FetchSpec (completeTreeWithNested)
import Kenshou.Core.Id (RunId, newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (..), CellPhase (..), CellStatus (..), LogChunks (..), Rejected (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Index (CellManifestLink (..), CellRunIndex (..))
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseHandle, LeaseRequest (..), acquireLease, leaseSnapshot, releaseLease, requestCancel)
import Kenshou.Remote.Cell.Session (SessionError (..), runSubmission)
import Kenshou.Remote.Cell.Session qualified as Session
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), SessionJournal (..), SliceJournal (..), SliceState (..), applyTransition, readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Cell.Session.Rebind (RebindError (RemoteMarkerExists), rebindPlannedSlices)
import Kenshou.Remote.Cell.Session.Rebind qualified as Rebind
import Kenshou.Remote.Cell.Session.Resume (HeldResumeError (..), resumeHeldSession, resumeObservedSlices)
import Kenshou.Remote.Cell.Session.Runner (SessionRunError (..), runPendingSlices, runPlannedSlices)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "one leased cell submission" do
  it "round-trips a durable journal and rejects skipped transitions" do
    journal <- readSessionJournal "test/golden/cell-session.json" >>= expectRight
    now <- getCurrentTime
    identifier <- case journal.slices of
      [slice] -> pure slice.cellRun
      _ -> expectationFailure "expected one golden slice" >> error "unreachable"
    applyTransition now identifier (Session.ResultsFetched "tree") journal `shouldSatisfy` isLeft
    submitted <- expectRight (applyTransition now identifier Session.SubmissionPublished journal)
    fmap (.state) submitted.slices `shouldBe` [SliceSubmitted]
    applyTransition now identifier Session.SubmissionPublished submitted `shouldSatisfy` isLeft

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
    let journalPath = root </> "out" </> "session.json"
    (_, checkpoint) <- journalCheckpoint journalPath submission
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
    Session.runSubmissionWithTransitions store cellRef (Bucket "results") handle submission workBytes (root </> "out") (const (pure ())) checkpoint `shouldReturn` Left (SubmissionRejected "unsafe-command")
    journal <- readSessionJournal journalPath >>= expectRight
    fmap (.state) journal.slices `shouldBe` [SliceRejected]
    fmap (.rejectionReason) journal.slices `shouldBe` [Just "unsafe-command"]

  it "takes one submission through a sealed local protocol agent and writes the index" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor handle
    let journalPath = root </> "out" </> "session.json"
    (nested, checkpoint) <- journalCheckpoint journalPath submission
    workerResult <- newEmptyMVar
    _ <- forkIO do
      completed <- try (publishSealedFixture store root submission nested) :: IO (Either SomeException ())
      putMVar workerResult completed
    result <- timeout 10000000 (Session.runSubmissionWithTransitions store cellRef (Bucket "results") handle submission workBytes (root </> "out") (const (pure ())) checkpoint)
    case result of
      Nothing -> expectationFailure "session did not observe the sealed result within ten seconds"
      Just (Left failure) -> expectationFailure (show failure)
      Just (Right index) -> do
        index.cellRun `shouldBe` submission.runId
        indexed <- doesFileExist (root </> "out" </> Text.unpack (renderRunId submission.runId) </> "cell-run.json")
        indexed `shouldBe` True
        journal <- readSessionJournal journalPath >>= expectRight
        fmap (.state) journal.slices `shouldBe` [SliceVerified]
        fmap (.manifestSha256) journal.slices `shouldBe` [Just index.cellManifest.sha256]
        otherRun <- newRunId
        now <- getCurrentTime
        case journal.slices of
          [slice] -> do
            let mismatched = journal {slices = [slice {state = SliceFetched, entryExitCode = Nothing, runIds = [otherRun]}]}
            applyTransition now submission.runId (Session.ResultsVerified index) mismatched `shouldBe` Left "verified index nested runs differ from planned slice"
          _ -> expectationFailure "expected one journal slice"
        worker <- takeMVar workerResult
        case worker of
          Left failure -> expectationFailure (show failure)
          Right () -> pure ()

  it "runs two prepared slices under one lease and checkpoints both results" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    first <- fixtureFor handle
    second <- fixtureFor handle
    firstNested <- newRunId
    secondNested <- newRunId
    sessionId <- newRunId
    now <- getCurrentTime
    let sessionDir = root </> "out" </> Text.unpack (renderRunId sessionId)
        journalPath = sessionDir </> "session.json"
        firstWork = "slice-0/work.json"
        secondWork = "slice-1/work.json"
        makeSlice index submission nested workPath = SliceJournal index submission.runId [index] [nested] submission.reset submission workPath SlicePlanned Nothing Nothing Nothing Nothing Nothing
        initial = SessionJournal sessionId "alpha" "file" Nothing "control" "results" first.leaseId Held Map.empty (Text.replicate 64 "a") [] [makeSlice 0 first firstNested firstWork, makeSlice 1 second secondNested secondWork] now now
    createDirectoryIfMissing True (sessionDir </> "slice-0")
    createDirectoryIfMissing True (sessionDir </> "slice-1")
    LazyByteString.writeFile (sessionDir </> firstWork) workBytes
    LazyByteString.writeFile (sessionDir </> secondWork) "wrong"
    runPlannedSlices store cellRef (Bucket "results") handle journalPath initial (const (pure ())) `shouldReturn` Left (InvalidSession "prepared work digest or size differs: slice-1/work.json")
    doesFileExist journalPath `shouldReturn` False
    LazyByteString.writeFile (sessionDir </> secondWork) workBytes
    workerResult <- newEmptyMVar
    _ <- forkIO do
      completed <- try (forM_ [(first, firstNested), (second, secondNested)] \(submission, nested) -> publishSealedFixture store root submission nested) :: IO (Either SomeException ())
      putMVar workerResult completed
    result <- timeout 20000000 (runPlannedSlices store cellRef (Bucket "results") handle journalPath initial (const (pure ())))
    case result of
      Nothing -> expectationFailure "two-slice session did not finish within twenty seconds"
      Just (Left failure) -> expectationFailure (show failure)
      Just (Right journal) -> do
        fmap (.state) journal.slices `shouldBe` [SliceVerified, SliceVerified]
        persisted <- readSessionJournal journalPath >>= expectRight
        persisted `shouldBe` journal
        forM_ [first, second] \submission -> do
          indexed <- doesFileExist (root </> "out" </> Text.unpack (renderRunId submission.runId) </> "cell-run.json")
          indexed `shouldBe` True
        worker <- takeMVar workerResult
        case worker of
          Left failure -> expectationFailure (show failure)
          Right () -> pure ()
        runPlannedSlices store cellRef (Bucket "results") handle journalPath initial (const (pure ())) `shouldReturn` Left (SessionFileExists journalPath)
        case journal.slices of
          [firstSlice, secondSlice] -> do
            let interrupted =
                  journal
                    { slices =
                        [ firstSlice {state = SliceSealed, entryExitCode = Nothing, fetchedPath = Nothing},
                          secondSlice {state = SliceSubmitted, cellOutcome = Nothing, entryExitCode = Nothing, manifestSha256 = Nothing, fetchedPath = Nothing}
                        ]
                    }
            writeSessionJournal journalPath interrupted
            runPendingSlices store cellRef (Bucket "results") handle journalPath (const (pure ())) `shouldReturn` Left (UnresolvedSlice firstSlice.cellRun SliceSealed)
            resumed <- resumeObservedSlices store cellRef (Bucket "results") journalPath (const (pure ()))
            recovered <- case resumed of
              Left failure -> expectationFailure (show failure) >> error "unreachable"
              Right value -> pure value
            fmap (.state) recovered.slices `shouldBe` [SliceVerified, SliceVerified]
            readSessionJournal journalPath `shouldReturn` Right recovered
            resumeHeldSession store cellRef (Bucket "results") handle journalPath (const (pure ())) `shouldReturn` Right recovered
            case recovered.slices of
              [firstRecovered, secondRecovered] -> do
                writeSessionJournal journalPath (recovered {slices = [firstRecovered {state = SliceFetched, entryExitCode = Nothing}, secondRecovered]})
                fetchedAgain <- resumeObservedSlices store cellRef (Bucket "results") journalPath (const (pure ()))
                case fetchedAgain of
                  Left failure -> expectationFailure (show failure)
                  Right value -> fmap (.state) value.slices `shouldBe` [SliceVerified, SliceVerified]
                let oldMarker = secondRecovered {state = SlicePlanned, cellOutcome = Nothing, entryExitCode = Nothing, manifestSha256 = Nothing, fetchedPath = Nothing}
                writeSessionJournal journalPath (recovered {slices = [firstRecovered, oldMarker]})
                rebindPlannedSlices store cellRef handle journalPath `shouldReturn` Left (RemoteMarkerExists secondRecovered.cellRun)
                resumeHeldSession store cellRef (Bucket "results") handle journalPath (const (pure ())) `shouldReturn` Left (RebindingError (RemoteMarkerExists secondRecovered.cellRun))
              _ -> expectationFailure "expected two recovered slices"
          _ -> expectationFailure "expected two journal slices"
        fresh <- fixtureFor handle
        freshNested <- newRunId
        freshSessionId <- newRunId
        at <- getCurrentTime
        let freshDir = root </> "out" </> Text.unpack (renderRunId freshSessionId)
            freshPath = freshDir </> "session.json"
            freshSlice = SliceJournal 0 fresh.runId [0] [freshNested] fresh.reset fresh "slice-0/work.json" SlicePlanned Nothing Nothing Nothing Nothing Nothing
            freshJournal = SessionJournal freshSessionId "alpha" "file" Nothing "control" "results" fresh.leaseId Held Map.empty (Text.replicate 64 "a") [] [freshSlice] at at
        writeSessionJournal freshPath freshJournal
        rebound <- rebindPlannedSlices store cellRef handle freshPath
        case rebound of
          Left failure -> expectationFailure (show failure)
          Right updated -> do
            updated.leaseId `shouldBe` fresh.leaseId
            fmap (.state) updated.slices `shouldBe` [SlicePlanned]
            fmap (.cellRun) updated.slices `shouldNotBe` [fresh.runId]
            readSessionJournal freshPath `shouldReturn` Right updated
            case updated.slices of
              [pendingSlice] -> do
                createDirectoryIfMissing True (freshDir </> "slice-0")
                LazyByteString.writeFile (freshDir </> pendingSlice.workPath) workBytes
                pendingWorker <- newEmptyMVar
                _ <- forkIO do
                  completed <- try (publishSealedFixture store root pendingSlice.submission freshNested) :: IO (Either SomeException ())
                  putMVar pendingWorker completed
                continued <- timeout 10000000 (runPendingSlices store cellRef (Bucket "results") handle freshPath (const (pure ())))
                case continued of
                  Nothing -> expectationFailure "rebound slice did not finish within ten seconds"
                  Just (Left failure) -> expectationFailure (show failure)
                  Just (Right finalJournal) -> do
                    fmap (.state) finalJournal.slices `shouldBe` [SliceVerified]
                    readSessionJournal freshPath `shouldReturn` Right finalJournal
                pendingOutcome <- takeMVar pendingWorker
                case pendingOutcome of
                  Left failure -> expectationFailure (show failure)
                  Right () -> pure ()
              _ -> expectationFailure "expected one rebound slice"

  it "retries an unaccepted submitted slice only after a fresh lease fences it" $ withSystemTempDirectory "kenshou-session" \root -> do
    store <- newFileStore root
    old <- acquireLease store cellRef request >>= expectAcquired
    submission <- fixtureFor old
    nested <- newRunId
    sessionId <- newRunId
    now <- getCurrentTime
    let sessionDir = root </> "out" </> Text.unpack (renderRunId sessionId)
        journalPath = sessionDir </> "session.json"
        slice = SliceJournal 0 submission.runId [0] [nested] submission.reset submission "slice-0/work.json" SliceSubmitted Nothing Nothing Nothing Nothing Nothing
        journal = SessionJournal sessionId "alpha" "file" Nothing "control" "results" submission.leaseId Held Map.empty (Text.replicate 64 "a") [] [slice] now now
        marker = ObjectName (submissionPrefix submission <> "submission.json")
        status = ObjectName (submissionPrefix submission <> "status.json")
        result = ObjectName ("runs/" <> renderRunId submission.runId <> "/cell/result.json")
    createDirectoryIfMissing True (sessionDir </> "slice-0")
    LazyByteString.writeFile (sessionDir </> slice.workPath) workBytes
    writeSessionJournal journalPath journal
    _ <- store.putObject cellRef.controlBucket marker "application/json" DoesNotExist (encode submission)
    rebindPlannedSlices store cellRef old journalPath `shouldReturn` Left (Rebind.UnresolvedSlice submission.runId SliceSubmitted)
    releaseLease store cellRef old `shouldReturn` True
    fresh <- acquireLease store cellRef request >>= expectAcquired
    _ <- store.putObject cellRef.controlBucket status "application/json" DoesNotExist "{}"
    rebindPlannedSlices store cellRef fresh journalPath `shouldReturn` Left (Rebind.UnresolvedSlice submission.runId SliceSubmitted)
    store.deleteObject cellRef.controlBucket status NoPrecondition `shouldReturn` True
    _ <- store.putObject (Bucket "results") result "application/json" DoesNotExist "{}"
    rebindPlannedSlices store cellRef fresh journalPath `shouldReturn` Left (Rebind.UnresolvedSlice submission.runId SliceSubmitted)
    store.deleteObject (Bucket "results") result NoPrecondition `shouldReturn` True
    rebound <- rebindPlannedSlices store cellRef fresh journalPath
    updated <- case rebound of
      Left failure -> expectationFailure (show failure) >> error "unreachable"
      Right value -> pure value
    fmap (.state) updated.slices `shouldBe` [SlicePlanned]
    updated.leaseId `shouldNotBe` submission.leaseId
    case updated.slices of
      [reboundSlice] -> do
        reboundSlice.cellRun `shouldNotBe` submission.runId
        reboundSlice.submission.leaseId `shouldBe` updated.leaseId
        store.statObject cellRef.controlBucket marker >>= (`shouldSatisfy` (maybe False (const True)))
      _ -> expectationFailure "expected one rebound slice"

publishSealedFixture :: ObjectStore -> FilePath -> Submission -> RunId -> IO ()
publishSealedFixture store root submission nested = do
  let marker = ObjectName (submissionPrefix submission <> "submission.json")
      results = Bucket "results"
      resultPrefix = "runs/" <> renderRunId submission.runId <> "/"
      awaitMarker = do
        visible <- store.statObject cellRef.controlBucket marker
        case visible of
          Nothing -> threadDelay 10000 >> awaitMarker
          Just _ -> pure ()
  awaitMarker
  (sourceTree, manifest) <- completeTreeWithNested (root </> "fixture" </> Text.unpack (renderRunId submission.runId)) submission.runId submission.leaseId nested False False False
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

expectRight :: Either Text value -> IO value
expectRight = either (\failure -> expectationFailure (Text.unpack failure) >> error "unreachable") pure

journalCheckpoint :: FilePath -> Submission -> IO (RunId, Session.SessionTransition -> IO ())
journalCheckpoint path submission = do
  now <- getCurrentTime
  identifier <- newRunId
  nested <- newRunId
  let slice = SliceJournal 0 submission.runId [0] [nested] submission.reset submission "slice-0/work.json" SlicePlanned Nothing Nothing Nothing Nothing Nothing
      initial = SessionJournal identifier "alpha" "file" Nothing "control" "results" submission.leaseId Held Map.empty (Text.replicate 64 "a") [] [slice] now now
  writeSessionJournal path initial
  journalRef <- newIORef initial
  pure
    ( nested,
      \transition -> do
        current <- readIORef journalRef
        at <- getCurrentTime
        changed <- either (ioError . userError . Text.unpack) pure (applyTransition at submission.runId transition current)
        writeSessionJournal path changed
        writeIORef journalRef changed
    )
