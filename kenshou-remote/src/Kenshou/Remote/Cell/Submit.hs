module Kenshou.Remote.Cell.Submit
  ( PublishOutcome (..),
    workObjectFor,
    publishSubmission,
  )
where

import Control.Monad (unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (addUTCTime)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Remote.Cell.Docs (Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), LeaseHandle, leaseHeld, leaseSnapshot)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))

data PublishOutcome
  = Submitted
  | LostLease
  | Quarantined
  | WorkAlreadyExists
  | SubmissionAlreadyExists
  deriving stock (Eq, Show)

workObjectFor :: Text -> LazyByteString.ByteString -> WorkObject
workObjectFor mediaType bytes =
  WorkObject
    { sha256 = TextEncoding.decodeUtf8 (Base16.encode (SHA256.hash (LazyByteString.toStrict bytes))),
      bytes = LazyByteString.length bytes,
      mediaType = mediaType
    }

-- The agent increments runsStarted after it claims submission.json. The client
-- only publishes the opaque work object and then the visible submission marker.
publishSubmission :: ObjectStore -> CellRef -> LeaseHandle -> Submission -> LazyByteString.ByteString -> IO PublishOutcome
publishSubmission store ref handle submission workBytes = do
  expected <- leaseSnapshot handle
  unless (expected.cell == ref.cellName && submission.leaseId == expected.leaseId) (ioError (userError "submission lease does not match cell lease handle"))
  case eitherDecode (encode submission) :: Either String Submission of
    Left failure -> ioError (userError ("invalid cell submission: " <> failure))
    Right _ -> pure ()
  let bundle = submission.payload.bundle
      bundleUri = "gs://" <> ref.controlBucket.unBucket <> "/payloads/sha256/" <> bundle.sha256 <> ".nar.zst"
  unless (bundle.uri == bundleUri) (ioError (userError "submission payload bundle is not in the cell control bucket"))
  unless (submission.work == workObjectFor submission.work.mediaType workBytes) (ioError (userError "submission work digest or size does not match its bytes"))
  active <- leaseActive store ref handle
  if not active
    then pure LostLease
    else do
      quarantined <- cellQuarantined store ref
      if quarantined
        then pure Quarantined
        else do
          let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId submission.runId <> "/"
          workResult <- store.putObject ref.controlBucket (ObjectName (prefix <> "work")) submission.work.mediaType DoesNotExist workBytes
          case workResult of
            PreconditionFailed -> pure WorkAlreadyExists
            Written _ -> do
              stillActive <- leaseActive store ref handle
              if not stillActive
                then pure LostLease
                else do
                  nowQuarantined <- cellQuarantined store ref
                  if nowQuarantined
                    then pure Quarantined
                    else do
                      marker <- store.putObject ref.controlBucket (ObjectName (prefix <> "submission.json")) "application/json" DoesNotExist (encode submission)
                      pure case marker of
                        Written _ -> Submitted
                        PreconditionFailed -> SubmissionAlreadyExists

cellQuarantined :: ObjectStore -> CellRef -> IO Bool
cellQuarantined store ref = do
  status <- store.statObject ref.controlBucket (ObjectName ("cells/" <> ref.cellName <> "/quarantine.json"))
  pure (case status of Nothing -> False; Just _ -> True)

leaseActive :: ObjectStore -> CellRef -> LeaseHandle -> IO Bool
leaseActive store ref handle = do
  held <- leaseHeld handle
  if not held
    then pure False
    else do
      expected <- leaseSnapshot handle
      stored <- store.getObject ref.controlBucket (ObjectName ("cells/" <> ref.cellName <> "/lease.json"))
      case stored of
        Nothing -> pure False
        Just (body, meta) -> case eitherDecode body of
          Left failure -> ioError (userError ("invalid active cell lease: " <> failure))
          Right (current :: Lease) -> do
            now <- store.serverTime
            pure (current.cell == ref.cellName && current.leaseId == expected.leaseId && not current.cancelRequested && addUTCTime (fromIntegral current.ttlSeconds + 30) meta.updated >= now)
