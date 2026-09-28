module Kenshou.Remote.Cell.Lease
  ( CellRef (..),
    LeaseId,
    Lease (..),
    Quarantine (..),
    LeaseRequest (..),
    LeaseHandle,
    AcquireOutcome (..),
    acquireLease,
    renewLease,
    resizeLease,
    releaseLease,
    reattachLease,
    requestCancel,
    leaseSnapshot,
    leaseHeld,
    withHeartbeat,
    validCellName,
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeAsyncException, SomeException, bracket, fromException, throwIO, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, encode, object, withObject, (.:), (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Kenshou.Core.Id (RunId, newRunId)
import Kenshou.Remote.Store (Bucket, ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))

data CellRef = CellRef
  { cellName :: !Text,
    controlBucket :: !Bucket
  }
  deriving stock (Eq, Show)

type LeaseId = RunId

data Lease = Lease
  { leaseId :: !LeaseId,
    cell :: !Text,
    owner :: !Text,
    purpose :: !Text,
    ttlSeconds :: !Int,
    acquiredAt :: !UTCTime,
    heartbeatAt :: !UTCTime,
    cancelRequested :: !Bool,
    runsStarted :: !Int
  }
  deriving stock (Eq, Show)

data Quarantine = Quarantine
  { cell :: !Text,
    reason :: !Text,
    runId :: !(Maybe Text),
    at :: !UTCTime
  }
  deriving stock (Eq, Show)

data LeaseRequest = LeaseRequest
  { owner :: !Text,
    purpose :: !Text,
    ttlSeconds :: !Int
  }
  deriving stock (Eq, Show)

data LeaseHandle = LeaseHandle
  { state :: !(MVar (Lease, Int64, Bool))
  }

data AcquireOutcome = Acquired !LeaseHandle | Busy !Lease | Quarantined !Quarantine

instance ToJSON Lease where
  toJSON lease =
    object
      [ "schema" .= ("cell.lease/v1" :: Text),
        "leaseId" .= lease.leaseId,
        "cell" .= lease.cell,
        "owner" .= lease.owner,
        "purpose" .= lease.purpose,
        "ttlSeconds" .= lease.ttlSeconds,
        "acquiredAt" .= lease.acquiredAt,
        "heartbeatAt" .= lease.heartbeatAt,
        "cancelRequested" .= lease.cancelRequested,
        "runsStarted" .= lease.runsStarted
      ]

instance FromJSON Lease where
  parseJSON = withObject "cell lease" \value -> do
    schema <- value .: "schema"
    unless (schema == ("cell.lease/v1" :: Text)) (fail "unsupported cell lease schema")
    lease <- Lease <$> value .: "leaseId" <*> value .: "cell" <*> value .: "owner" <*> value .: "purpose" <*> value .: "ttlSeconds" <*> value .: "acquiredAt" <*> value .: "heartbeatAt" <*> value .: "cancelRequested" <*> value .: "runsStarted"
    unless (validCellName lease.cell && not (Text.null lease.owner) && not (Text.null lease.purpose) && lease.ttlSeconds > 0 && lease.runsStarted >= 0) (fail "invalid cell lease")
    pure lease

instance ToJSON Quarantine where
  toJSON quarantine =
    object
      [ "schema" .= ("cell.quarantine/v1" :: Text),
        "cell" .= quarantine.cell,
        "reason" .= quarantine.reason,
        "runId" .= quarantine.runId,
        "at" .= quarantine.at
      ]

instance FromJSON Quarantine where
  parseJSON = withObject "cell quarantine" \value -> do
    schema <- value .: "schema"
    unless (schema == ("cell.quarantine/v1" :: Text)) (fail "unsupported cell quarantine schema")
    quarantine <- Quarantine <$> value .: "cell" <*> value .: "reason" <*> value .: "runId" <*> value .: "at"
    unless (validCellName quarantine.cell && not (Text.null quarantine.reason)) (fail "invalid cell quarantine")
    pure quarantine

acquireLease :: ObjectStore -> CellRef -> LeaseRequest -> IO AcquireOutcome
acquireLease store ref request = do
  unless (validCellName ref.cellName && not (Text.null request.owner) && not (Text.null request.purpose) && request.ttlSeconds > 0) (ioError (userError "invalid lease request"))
  identifier <- newRunId
  acquire identifier (0 :: Int)
  where
    acquire identifier attempts = do
      unless (attempts < maxCasAttempts) (ioError (userError "lease claim contention exceeded retry limit"))
      now <- store.serverTime
      let proposed = Lease identifier ref.cellName request.owner request.purpose request.ttlSeconds now now False 0
      result <- store.putObject ref.controlBucket (leaseName ref) "application/json" DoesNotExist (encode proposed)
      case result of
        Written meta -> accept proposed meta
        PreconditionFailed -> do
          observed <- readCurrent store ref
          case observed of
            Nothing -> acquire identifier (attempts + 1)
            Just (current, meta) -> do
              clock <- store.serverTime
              if addUTCTime (fromIntegral current.ttlSeconds + 30) meta.updated < clock
                then do
                  replaced <- store.putObject ref.controlBucket (leaseName ref) "application/json" (GenerationIs meta.generation) (encode proposed)
                  case replaced of
                    Written next -> accept proposed next
                    PreconditionFailed -> acquire identifier (attempts + 1)
                else pure (Busy current)
    accept lease meta = do
      quarantine <- readQuarantine store ref
      case quarantine of
        Nothing -> Acquired <$> newHandle lease meta.generation
        Just record -> do
          released <- store.deleteObject ref.controlBucket (leaseName ref) (GenerationIs meta.generation)
          unless released (ioError (userError "quarantined cell lease could not be released"))
          pure (Quarantined record)

renewLease :: ObjectStore -> CellRef -> LeaseHandle -> IO Bool
renewLease store ref handle = modifyMVar handle.state \(lease, generation, held) ->
  if not held || lease.cancelRequested
    then pure ((lease, generation, False), False)
    else do
      unless (lease.cell == ref.cellName) (ioError (userError "lease handle names another cell"))
      now <- store.serverTime
      let renewed = lease {heartbeatAt = now}
      result <- store.putObject ref.controlBucket (leaseName ref) "application/json" (GenerationIs generation) (encode renewed)
      case result of
        Written meta -> pure ((renewed, meta.generation, True), True)
        PreconditionFailed -> pure ((lease, generation, False), False)

-- A detached submission needs a lease that outlives its wall-clock budget.
-- Fence the TTL change before publishing its marker.
resizeLease :: ObjectStore -> CellRef -> LeaseHandle -> Int -> IO Bool
resizeLease store ref handle ttl = do
  unless (ttl > 0) (ioError (userError "lease TTL must be positive"))
  modifyMVar handle.state \(lease, generation, held) ->
    if not held || lease.cancelRequested
      then pure ((lease, generation, False), False)
      else do
        unless (lease.cell == ref.cellName) (ioError (userError "lease handle names another cell"))
        now <- store.serverTime
        let resized = lease {ttlSeconds = ttl, heartbeatAt = now}
        result <- store.putObject ref.controlBucket (leaseName ref) "application/json" (GenerationIs generation) (encode resized)
        case result of
          Written meta -> pure ((resized, meta.generation, True), True)
          PreconditionFailed -> pure ((lease, generation, False), False)

releaseLease :: ObjectStore -> CellRef -> LeaseHandle -> IO Bool
releaseLease store ref handle = modifyMVar handle.state \(lease, generation, held) ->
  if not held
    then pure ((lease, generation, False), False)
    else do
      unless (lease.cell == ref.cellName) (ioError (userError "lease handle names another cell"))
      released <- store.deleteObject ref.controlBucket (leaseName ref) (GenerationIs generation)
      pure ((lease, generation, False), released)

reattachLease :: ObjectStore -> CellRef -> LeaseId -> IO (Maybe LeaseHandle)
reattachLease store ref identifier = do
  current <- readCurrent store ref
  case current of
    Just (lease, meta) | lease.leaseId == identifier -> Just <$> newHandle lease meta.generation
    _ -> pure Nothing

requestCancel :: ObjectStore -> CellRef -> Maybe LeaseId -> Bool -> IO Bool
requestCancel store ref expected force = do
  unless (force || isJust expected) (ioError (userError "cancelling another owner's lease requires force"))
  attempt (0 :: Int)
  where
    attempt count = do
      unless (count < maxCasAttempts) (ioError (userError "lease cancellation contention exceeded retry limit"))
      current <- readCurrent store ref
      case current of
        Nothing -> pure False
        Just (lease, meta)
          | not force && Just lease.leaseId /= expected -> pure False
          | lease.cancelRequested -> pure True
          | otherwise -> do
              result <- store.putObject ref.controlBucket (leaseName ref) "application/json" (GenerationIs meta.generation) (encode (lease {cancelRequested = True}))
              case result of
                Written _ -> pure True
                PreconditionFailed -> attempt (count + 1)

leaseHeld :: LeaseHandle -> IO Bool
leaseHeld handle = (\(_, _, held) -> held) <$> readMVar handle.state

leaseSnapshot :: LeaseHandle -> IO Lease
leaseSnapshot handle = (\(lease, _, _) -> lease) <$> readMVar handle.state

withHeartbeat :: ObjectStore -> CellRef -> LeaseHandle -> (IO Bool -> IO value) -> IO value
withHeartbeat store ref handle action = bracket start killThread (const (action (leaseHeld handle)))
  where
    start = forkIO loop
    loop = do
      (lease, _, held) <- readMVar handle.state
      if held
        then do
          threadDelay (max 100000 (lease.ttlSeconds * 1000000 `div` 3))
          result <- try (renewLease store ref handle) :: IO (Either SomeException Bool)
          case result of
            Right True -> loop
            Left failure | Just async <- (fromException failure :: Maybe SomeAsyncException) -> throwIO async
            _ -> modifyMVar_ handle.state \(current, generation, _) -> pure (current, generation, False)
        else pure ()

newHandle :: Lease -> Int64 -> IO LeaseHandle
newHandle lease generation = LeaseHandle <$> newMVar (lease, generation, True)

readCurrent :: ObjectStore -> CellRef -> IO (Maybe (Lease, ObjectMeta))
readCurrent store ref = do
  stored <- store.getObject ref.controlBucket (leaseName ref)
  case stored of
    Nothing -> pure Nothing
    Just (bytes, meta) -> do
      lease <- decodeDocument "cell lease" bytes
      unless (lease.cell == ref.cellName) (ioError (userError "cell lease names another cell"))
      pure (Just (lease, meta))

readQuarantine :: ObjectStore -> CellRef -> IO (Maybe Quarantine)
readQuarantine store ref = do
  stored <- store.getObject ref.controlBucket (quarantineName ref)
  case stored of
    Nothing -> pure Nothing
    Just (bytes, _) -> do
      record <- decodeDocument "cell quarantine" bytes
      unless (record.cell == ref.cellName) (ioError (userError "cell quarantine names another cell"))
      pure (Just record)

decodeDocument :: (FromJSON value) => String -> LazyByteString.ByteString -> IO value
decodeDocument label bytes = either (ioError . userError . ((label <> ": ") <>)) pure (eitherDecode bytes)

leaseName :: CellRef -> ObjectName
leaseName ref = ObjectName ("cells/" <> ref.cellName <> "/lease.json")

quarantineName :: CellRef -> ObjectName
quarantineName ref = ObjectName ("cells/" <> ref.cellName <> "/quarantine.json")

validCellName :: Text -> Bool
validCellName value =
  Text.length value >= 3
    && Text.length value <= 63
    && Text.head value `elem` (['a' .. 'z'] <> ['0' .. '9'])
    && Text.all (\character -> character `elem` (['a' .. 'z'] <> ['0' .. '9'] <> "-")) value

maxCasAttempts :: Int
maxCasAttempts = 32
