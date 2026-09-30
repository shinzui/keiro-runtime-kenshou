module LeaseSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM)
import Data.Aeson (Value, eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isRight)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Maybe (isJust)
import Data.Time (addUTCTime, getCurrentTime)
import Kenshou.Core.Id (newRunId)
import Kenshou.Remote.Cell.Control (CellSnapshot (..), readCellSnapshot)
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseHandle, LeaseRequest (..), Quarantine (..), acquireLease, leaseHeld, leaseSnapshot, reattachLease, releaseLease, renewLease, requestCancel, resizeLease, withHeartbeat)
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cell lease protocol" do
  it "gives exactly one contender a create-only lease" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    replies <- replicateM 12 newEmptyMVar
    mapM_ (\reply -> forkIO (acquireLease store cellRef request >>= putMVar reply)) replies
    outcomes <- mapM takeMVar replies
    length [() | Acquired _ <- outcomes] `shouldBe` 1
    length [() | Busy _ <- outcomes] `shouldBe` 11

  it "renews with the latest generation, reattaches by id, and releases" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    first <- leaseSnapshot handle
    renewLease store cellRef handle `shouldReturn` True
    renewed <- leaseSnapshot handle
    renewed.heartbeatAt `shouldSatisfy` (>= first.heartbeatAt)
    reattached <- reattachLease store cellRef first.leaseId
    isJust reattached `shouldBe` True
    releaseLease store cellRef handle `shouldReturn` True
    leaseHeld handle `shouldReturn` False
    store.statObject cellRef.controlBucket (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing

  it "retains the lease when the cell agent advances runsStarted" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    lease <- leaseSnapshot handle
    let objectName = ObjectName "cells/alpha/lease.json"
    meta <- store.statObject cellRef.controlBucket objectName >>= maybe (expectationFailure "missing lease" >> error "unreachable") pure
    updated <- store.putObject cellRef.controlBucket objectName "application/json" (GenerationIs meta.generation) (encode (lease {runsStarted = 1}))
    updated `shouldSatisfy` \case Written _ -> True; _ -> False
    renewLease store cellRef handle `shouldReturn` True
    refreshed <- leaseSnapshot handle
    refreshed.runsStarted `shouldBe` 1
    releaseLease store cellRef handle `shouldReturn` True

  it "takes over only after server time exceeds updated plus TTL and grace" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    old <- acquireLease store cellRef shortRequest >>= expectAcquired
    let later = store {serverTime = addUTCTime 100 <$> store.serverTime}
    replacement <- acquireLease later cellRef request >>= expectAcquired
    leaseHeld replacement `shouldReturn` True
    renewLease store cellRef old `shouldReturn` False
    releaseLease later cellRef replacement `shouldReturn` True

  it "fences a detached TTL extension against a stale lease generation" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    resizeLease store cellRef handle 900 `shouldReturn` True
    snapshot <- leaseSnapshot handle
    snapshot.ttlSeconds `shouldBe` 900
    stale <- reattachLease store cellRef snapshot.leaseId
    case stale of
      Nothing -> expectationFailure "extended lease disappeared"
      Just old -> do
        renewLease store cellRef handle `shouldReturn` True
        resizeLease store cellRef old 1200 `shouldReturn` False
        leaseHeld old `shouldReturn` False
    releaseLease store cellRef handle `shouldReturn` True

  it "releases a newly won lease when quarantine exists" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    now <- getCurrentTime
    let record = Quarantine "alpha" "reset-failed" Nothing now
    _ <- store.putObject cellRef.controlBucket (ObjectName "cells/alpha/quarantine.json") "application/json" DoesNotExist (encode record)
    outcome <- acquireLease store cellRef request
    case outcome of
      Quarantined observed -> observed `shouldBe` record
      _ -> expectationFailure "expected quarantined cell"
    store.statObject cellRef.controlBucket (ObjectName "cells/alpha/lease.json") `shouldReturn` Nothing

  it "keeps a heartbeat and allows release after its thread stops" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef shortRequest >>= expectAcquired
    withHeartbeat store cellRef handle \stillHeld -> do
      threadDelay 1200000
      stillHeld `shouldReturn` True
    releaseLease store cellRef handle `shouldReturn` True

  it "retries one transient heartbeat write failure while the lease remains valid" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef shortRequest >>= expectAcquired
    initial <- leaseSnapshot handle
    failNext <- newIORef True
    let flaky =
          store
            { putObject = \bucket object mediaType precondition bytes -> do
                shouldFail <-
                  if object == ObjectName "cells/alpha/lease.json"
                    then atomicModifyIORef' failNext (\failPending -> (False, failPending))
                    else pure False
                if shouldFail
                  then ioError (userError "transient heartbeat write failure")
                  else store.putObject bucket object mediaType precondition bytes
            }
    withHeartbeat flaky cellRef handle \stillHeld -> do
      threadDelay 1700000
      stillHeld `shouldReturn` True
    renewed <- leaseSnapshot handle
    renewed.heartbeatAt `shouldSatisfy` (> initial.heartbeatAt)
    releaseLease store cellRef handle `shouldReturn` True

  it "cancels only the expected lease unless force is explicit" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    current <- leaseSnapshot handle
    otherId <- newRunId
    requestCancel store cellRef Nothing False `shouldThrow` anyIOException
    requestCancel store cellRef (Just otherId) False `shouldReturn` False
    requestCancel store cellRef (Just current.leaseId) False `shouldReturn` True
    renewLease store cellRef handle `shouldReturn` False
    reattached <- reattachLease store cellRef current.leaseId
    case reattached of
      Just fresh -> releaseLease store cellRef fresh `shouldReturn` True
      Nothing -> expectationFailure "cancelled lease could not be reattached for release"
    second <- acquireLease store cellRef request >>= expectAcquired
    requestCancel store cellRef Nothing True `shouldReturn` True
    leaseHeld second `shouldReturn` True
    renewLease store cellRef second `shouldReturn` False

  it "round-trips the cell lease document" $ withSystemTempDirectory "kenshou-lease" \root -> do
    store <- newFileStore root
    handle <- acquireLease store cellRef request >>= expectAcquired
    lease <- leaseSnapshot handle
    eitherDecode (encode lease) `shouldBe` Right lease

  it "decodes the cell owner's lease and quarantine fixtures and preserves their JSON" do
    leaseBytes <- LazyByteString.readFile "test/golden/cell/cell.lease.v1.json"
    quarantineBytes <- LazyByteString.readFile "test/golden/cell/cell.quarantine.v1.json"
    let decodedLease = eitherDecode leaseBytes :: Either String Lease
        decodedQuarantine = eitherDecode quarantineBytes :: Either String Quarantine
    decodedLease `shouldSatisfy` isRight
    decodedQuarantine `shouldSatisfy` isRight
    fmap (eitherDecode . encode) decodedLease `shouldBe` Right (eitherDecode leaseBytes :: Either String Value)
    fmap (eitherDecode . encode) decodedQuarantine `shouldBe` Right (eitherDecode quarantineBytes :: Either String Value)

  it "reads owner control objects only for an allowed project and matching bucket" $ withSystemTempDirectory "kenshou-cell-control" \root -> do
    store <- newFileStore root
    descriptor <- LazyByteString.readFile "test/golden/cell/cell.descriptor.v1.json"
    let ref = CellRef "alpha" (Bucket "tan-nb-exp-cells-control")
    _ <- store.putObject ref.controlBucket (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist descriptor
    snapshot <- readCellSnapshot store ref ["tan-nb-exp"]
    case snapshot of
      Right observed -> do
        observed.lease `shouldBe` Nothing
        observed.quarantine `shouldBe` Nothing
      Left problem -> expectationFailure (show problem)
    readCellSnapshot store ref ["another-project"] `shouldReturn` Left "cell project is outside KENSHOU_GCP_ALLOWED_PROJECTS: tan-nb-exp"
    let wrongBucket = CellRef "alpha" (Bucket "other-control")
    _ <- store.putObject wrongBucket.controlBucket (ObjectName "cells/alpha/descriptor.json") "application/json" DoesNotExist descriptor
    readCellSnapshot store wrongBucket ["tan-nb-exp"] `shouldReturn` Left "cell descriptor control bucket differs from selected bucket"

cellRef :: CellRef
cellRef = CellRef "alpha" (Bucket "control")

request :: LeaseRequest
request = LeaseRequest "tester@workstation" "verification" 120

shortRequest :: LeaseRequest
shortRequest = LeaseRequest "tester@workstation" "verification" 1

expectAcquired :: AcquireOutcome -> IO LeaseHandle
expectAcquired (Acquired handle) = pure handle
expectAcquired _ = expectationFailure "expected acquired lease" >> error "unreachable"
