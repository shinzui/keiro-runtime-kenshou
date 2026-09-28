module Kenshou.Remote.Cell.Session
  ( SessionError (..),
    SessionTransition (..),
    runSubmission,
    runSubmissionWithTransitions,
  )
where

import Control.Concurrent (threadDelay)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Kenshou.Remote.Cell.Docs (CellStatus, Rejected (..), Submission (..))
import Kenshou.Remote.Cell.Fetch (FetchError, VerifyProblem, fetchCellRun)
import Kenshou.Remote.Cell.Index (CellRunIndex, deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Cell.Lease (CellRef, LeaseHandle, withHeartbeat)
import Kenshou.Remote.Cell.Submit (PublishOutcome (..), publishSubmission)
import Kenshou.Remote.Cell.Watch (WatchEvent, WatchSnapshot (..), WatchTerminal (..), newWatchCursor, pollCellRun)
import Kenshou.Remote.Store (Bucket, ObjectStore)

data SessionError
  = LeaseLost
  | PublicationFailed !PublishOutcome
  | SubmissionRejected !Text
  | FetchFailed !FetchError
  | VerificationFailed !(NonEmpty VerifyProblem)
  deriving stock (Eq, Show)

data SessionTransition
  = SubmissionPublished
  | SubmissionSealed !CellStatus
  | SubmissionRejectedByCell !Rejected
  | ResultsFetched !FilePath
  | ResultsVerified !CellRunIndex
  deriving stock (Eq, Show)

-- One already prepared slice under an existing held lease. Its caller owns the
-- session document and advances its state after each returned transition.
runSubmission :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> Submission -> LazyByteString.ByteString -> FilePath -> (WatchEvent -> IO ()) -> IO (Either SessionError CellRunIndex)
runSubmission store ref resultsBucket handle submission workBytes outDir emit =
  runSubmissionWithTransitions store ref resultsBucket handle submission workBytes outDir emit (const (pure ()))

runSubmissionWithTransitions :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> Submission -> LazyByteString.ByteString -> FilePath -> (WatchEvent -> IO ()) -> (SessionTransition -> IO ()) -> IO (Either SessionError CellRunIndex)
runSubmissionWithTransitions store ref resultsBucket handle submission workBytes outDir emit checkpoint =
  withHeartbeat store ref handle \stillHeld -> do
    published <- publishSubmission store ref handle submission workBytes
    case published of
      Submitted -> checkpoint SubmissionPublished >> waitForSeal stillHeld newWatchCursor
      LostLease -> pure (Left LeaseLost)
      other -> pure (Left (PublicationFailed other))
  where
    waitForSeal stillHeld cursor = do
      held <- stillHeld
      if not held
        then pure (Left LeaseLost)
        else do
          snapshot <- pollCellRun store ref submission.runId cursor
          mapM_ emit snapshot.events
          case snapshot.terminal of
            Just (RunRejected rejected) -> checkpoint (SubmissionRejectedByCell rejected) >> pure (Left (SubmissionRejected rejected.reason))
            Just (RunSealed status) -> do
              checkpoint (SubmissionSealed status)
              fetched <- fetchCellRun store resultsBucket submission.runId outDir
              case fetched of
                Left failure -> pure (Left (FetchFailed failure))
                Right tree -> do
                  checkpoint (ResultsFetched tree)
                  indexed <- deriveCellRunIndex resultsBucket (Just status) tree
                  case indexed of
                    Left problems -> pure (Left (VerificationFailed problems))
                    Right index -> do
                      _ <- writeCellRunIndex tree index
                      checkpoint (ResultsVerified index)
                      pure (Right index)
            Nothing -> threadDelay 2000000 >> waitForSeal stillHeld snapshot.cursor
