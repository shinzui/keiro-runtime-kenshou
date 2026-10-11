module PerfCleanupSpec (spec) where

import Data.Aeson (ToJSON, eitherDecode, encode)
import Data.ByteString.Lazy qualified as Lazy
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs
import Kenshou.Remote.Cell.Docs qualified as Submission (Submission (..))
import Kenshou.Remote.Cell.Lease qualified as Lease
import Kenshou.Remote.Cell.Session.Journal
import Kenshou.Remote.Perf.Cleanup
import Kenshou.Remote.Perf.Journal (LeaseIdentity (..))
import Kenshou.Remote.Store
import Kenshou.Remote.Store.File (newFileStore)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance owned cleanup" do
  it "accepts an unpublished planned slice but retains an ambiguous submitted slice" $ fixture \store ref identity journal -> do
    ownedWorkSettled store ref identity [journal] `shouldReturn` True
    let submitted = journal {slices = map (\slice -> slice {state = SliceSubmitted}) journal.slices}
    ownedWorkSettled store ref identity [submitted] `shouldReturn` False
  it "waits for a submitted run to seal with both outcome and digest" $ fixture \store ref identity journal -> do
    slice <- onlySlice journal
    let status = CellStatus slice.cellRun Running Nothing journal.createdAt Nothing (LogChunks 0 0) Nothing Nothing Nothing
    put store ref slice "submission.json" slice.submission
    put store ref slice "status.json" status
    ownedWorkSettled store ref identity [journal] `shouldReturn` False
    put store ref slice "status.json" (status {phase = Sealed})
    ownedWorkSettled store ref identity [journal] `shouldThrow` anyIOException
    put store ref slice "status.json" (status {phase = Sealed, outcome = Just Cancelled, manifestSha256 = Just (Text.replicate 64 "a")})
    ownedWorkSettled store ref identity [journal] `shouldReturn` True
  it "accepts owner rejection and rejects a marker naming another lease" $ fixture \store ref identity journal -> do
    slice <- onlySlice journal
    put store ref slice "submission.json" slice.submission
    put store ref slice "rejected.json" (Rejected slice.cellRun "cancelled lease" journal.createdAt)
    ownedWorkSettled store ref identity [journal] `shouldReturn` True
    other <- newRunId
    put store ref slice "submission.json" (slice.submission {Submission.leaseId = other})
    ownedWorkSettled store ref identity [journal] `shouldThrow` anyIOException
  it "does not inspect another owner's work and rejects a mismatched control reference" $ fixture \store ref identity journal -> do
    other <- newRunId
    ownedWorkSettled store ref (LeaseIdentity identity.cell other) [journal] `shouldReturn` True
    ownedWorkSettled store (ref {Lease.controlBucket = Bucket "wrong"}) identity [journal] `shouldThrow` anyIOException
    ownedWorkSettled store (ref {Lease.cellName = "beta"}) identity [journal] `shouldThrow` anyIOException
  it "reattaches live work but treats expired and cancelled leases as lost" $ withSystemTempDirectory "perf-live-lease" \root -> do
    store <- newFileStore root
    let ref = Lease.CellRef "alpha" (Bucket "control")
    acquired <- Lease.acquireLease store ref (Lease.LeaseRequest "test" "recovery" 120)
    handle <- case acquired of
      Lease.Acquired value -> pure value
      _ -> expectationFailure "lease was not acquired" >> error "unreachable"
    lease <- Lease.leaseSnapshot handle
    isJust <$> Lease.reattachActiveLease store ref lease.leaseId `shouldReturn` True
    let later = store {serverTime = addUTCTime 151 <$> store.serverTime}
    isNothing <$> Lease.reattachActiveLease later ref lease.leaseId `shouldReturn` True
    isJust <$> Lease.reattachLease later ref lease.leaseId `shouldReturn` True
    Lease.requestCancel store ref (Just lease.leaseId) False `shouldReturn` True
    isNothing <$> Lease.reattachActiveLease store ref lease.leaseId `shouldReturn` True
    isJust <$> Lease.reattachLease store ref lease.leaseId `shouldReturn` True

fixture :: (ObjectStore -> Lease.CellRef -> LeaseIdentity -> SessionJournal -> IO ()) -> IO ()
fixture action = withSystemTempDirectory "perf-cleanup" \root -> do
  store <- newFileStore root
  bytes <- Lazy.readFile "test/golden/cell-session.json"
  journal <- either (ioError . userError) pure (eitherDecode bytes)
  action store (Lease.CellRef journal.cell (Bucket journal.controlBucket)) (LeaseIdentity journal.cell journal.leaseId) journal

onlySlice :: SessionJournal -> IO SliceJournal
onlySlice journal = case journal.slices of
  [slice] -> pure slice
  _ -> expectationFailure "cleanup fixture must have one slice" >> error "unreachable"

put :: (ToJSON value) => ObjectStore -> Lease.CellRef -> SliceJournal -> Text.Text -> value -> IO ()
put store ref slice name value = do
  let path = ObjectName ("cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/" <> name)
  current <- store.statObject ref.controlBucket path
  _ <- store.putObject ref.controlBucket path "application/json" (maybe DoesNotExist (GenerationIs . (.generation)) current) (encode value)
  pure ()
