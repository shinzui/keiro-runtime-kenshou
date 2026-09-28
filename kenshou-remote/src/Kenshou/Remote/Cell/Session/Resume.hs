module Kenshou.Remote.Cell.Session.Resume
  ( ResumeError (..),
    HeldResumeError (..),
    resumeObservedSlices,
    resumeHeldSession,
  )
where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Remote.Cell.Fetch (FetchError, VerifyProblem, fetchCellRun)
import Kenshou.Remote.Cell.Index (deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Cell.Lease (CellRef (..), LeaseHandle)
import Kenshou.Remote.Cell.Session (SessionTransition (..))
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..), SliceState (..), applyTransition, readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Cell.Session.Rebind (RebindError, rebindPlannedSlices)
import Kenshou.Remote.Cell.Session.Runner (SessionRunError, runPendingSlices)
import Kenshou.Remote.Cell.Watch (WatchEvent, WatchSnapshot (..), WatchTerminal (..), newWatchCursor, pollCellRun)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.FilePath (takeDirectory)

data ResumeError
  = InvalidJournal !Text
  | ResultFetchFailed !RunId !FetchError
  | ResultVerificationFailed !RunId !(NonEmpty VerifyProblem)
  deriving stock (Eq, Show)

data HeldResumeError
  = ObservationError !ResumeError
  | RebindingError !RebindError
  | ContinuationError !SessionRunError
  deriving stock (Eq, Show)

resumeHeldSession :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> FilePath -> (WatchEvent -> IO ()) -> IO (Either HeldResumeError SessionJournal)
resumeHeldSession store ref resultsBucket handle journalPath emit = do
  observed <- resumeObservedSlices store ref resultsBucket journalPath emit
  case observed of
    Left failure -> pure (Left (ObservationError failure))
    Right _ -> do
      rebound <- rebindPlannedSlices store ref handle journalPath
      case rebound of
        Left failure -> pure (Left (RebindingError failure))
        Right _ -> do
          continued <- runPendingSlices store ref resultsBucket handle journalPath emit
          pure (either (Left . ContinuationError) Right continued)

-- Reconcile observations and collect already sealed results. Planned or still
-- running slices remain untouched for a later lease-aware resume step.
resumeObservedSlices :: ObjectStore -> CellRef -> Bucket -> FilePath -> (WatchEvent -> IO ()) -> IO (Either ResumeError SessionJournal)
resumeObservedSlices store ref resultsBucket journalPath emit = do
  decoded <- readSessionJournal journalPath
  case decoded of
    Left problem -> pure (Left (InvalidJournal problem))
    Right journal
      | journal.cell /= ref.cellName || journal.controlBucket /= ref.controlBucket.unBucket || journal.resultsBucket /= resultsBucket.unBucket -> pure (Left (InvalidJournal "session cell or buckets differ from the requested store"))
      | otherwise -> do
          current <- newIORef journal
          reconcile current journal.slices
  where
    outRoot = takeDirectory (takeDirectory journalPath)
    checkpoint current identifier transition = do
      before <- readIORef current
      now <- getCurrentTime
      changed <- either (ioError . userError . Text.unpack) pure (applyTransition now identifier transition before)
      writeSessionJournal journalPath changed
      writeIORef current changed
    reconcile current [] = Right <$> readIORef current
    reconcile current (slice : rest) = do
      outcome <- case slice.state of
        SlicePlanned -> pure (Right ())
        SliceRejected -> pure (Right ())
        SliceVerified -> pure (Right ())
        SliceSubmitted -> do
          observed <- observe slice.cellRun
          case observed of
            Nothing -> pure (Right ())
            Just (RunRejected rejected) -> checkpoint current slice.cellRun (SubmissionRejectedByCell rejected) >> pure (Right ())
            Just (RunSealed status) -> do
              checkpoint current slice.cellRun (SubmissionSealed status)
              collect current slice.cellRun (Just status) True
        SliceSealed -> do
          status <- sealedStatus slice.cellRun
          collect current slice.cellRun status True
        SliceFetched -> do
          status <- sealedStatus slice.cellRun
          collect current slice.cellRun status False
      case outcome of
        Left failure -> pure (Left failure)
        Right () -> reconcile current rest
    observe identifier = do
      snapshot <- pollCellRun store ref identifier newWatchCursor
      mapM_ emit snapshot.events
      pure snapshot.terminal
    sealedStatus identifier = do
      terminal <- observe identifier
      pure case terminal of
        Just (RunSealed status) -> Just status
        _ -> Nothing
    collect current identifier status shouldCheckpointFetch = do
      fetched <- fetchCellRun store resultsBucket identifier outRoot
      case fetched of
        Left failure -> pure (Left (ResultFetchFailed identifier failure))
        Right tree -> do
          if shouldCheckpointFetch then checkpoint current identifier (ResultsFetched tree) else pure ()
          verified <- deriveCellRunIndex resultsBucket status tree
          case verified of
            Left problems -> pure (Left (ResultVerificationFailed identifier problems))
            Right index -> do
              _ <- writeCellRunIndex tree index
              checkpoint current identifier (ResultsVerified index)
              pure (Right ())
