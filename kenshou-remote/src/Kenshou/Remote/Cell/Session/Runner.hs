module Kenshou.Remote.Cell.Session.Runner
  ( SessionRunError (..),
    runPlannedSlices,
    runPendingSlices,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Remote.Cell.Docs (Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), LeaseHandle, leaseSnapshot)
import Kenshou.Remote.Cell.Session (SessionError, SessionTransition, runSubmissionWithTransitions)
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), SessionJournal (..), SliceJournal (..), SliceState (..), applyTransition, readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.Watch (WatchEvent)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

data SessionRunError
  = InvalidSession !Text
  | SessionFileExists !FilePath
  | SessionFileMissing !FilePath
  | UnresolvedSlice !RunId !SliceState
  | SliceExecutionFailed !RunId !SessionError
  deriving stock (Eq, Show)

-- Run a new, already prepared journal. The journal and work files are the
-- caller's durable inputs; this function never rewrites a prior session.
runPlannedSlices :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> FilePath -> SessionJournal -> (WatchEvent -> IO ()) -> IO (Either SessionRunError SessionJournal)
runPlannedSlices store ref resultsBucket handle journalPath journal emit = do
  exists <- doesFileExist journalPath
  if exists
    then pure (Left (SessionFileExists journalPath))
    else do
      lease <- leaseSnapshot handle
      case validateSession ref resultsBucket lease journal of
        Left problem -> pure (Left (InvalidSession problem))
        Right ()
          | any ((/= SlicePlanned) . (.state)) journal.slices -> pure (Left (InvalidSession "new session contains a slice that is not planned"))
          | otherwise -> do
              preflight <- checkWorkFiles (takeDirectory journalPath) journal.slices
              case preflight of
                Left problem -> pure (Left (InvalidSession problem))
                Right () -> do
                  writeSessionJournal journalPath journal
                  executeSlices store ref resultsBucket handle journalPath journal journal.slices emit

-- Continue a journal whose planned slices have already been rebound to this
-- lease. Verified and rejected slices are retained without execution.
runPendingSlices :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> FilePath -> (WatchEvent -> IO ()) -> IO (Either SessionRunError SessionJournal)
runPendingSlices store ref resultsBucket handle journalPath emit = do
  exists <- doesFileExist journalPath
  if not exists
    then pure (Left (SessionFileMissing journalPath))
    else do
      decoded <- readSessionJournal journalPath
      case decoded of
        Left problem -> pure (Left (InvalidSession problem))
        Right journal -> do
          lease <- leaseSnapshot handle
          case validateSession ref resultsBucket lease journal of
            Left problem -> pure (Left (InvalidSession problem))
            Right () -> case filter (\slice -> slice.state `notElem` [SlicePlanned, SliceRejected, SliceVerified]) journal.slices of
              slice : _ -> pure (Left (UnresolvedSlice slice.cellRun slice.state))
              [] -> do
                let planned = filter ((== SlicePlanned) . (.state)) journal.slices
                preflight <- checkWorkFiles (takeDirectory journalPath) planned
                case preflight of
                  Left problem -> pure (Left (InvalidSession problem))
                  Right () -> executeSlices store ref resultsBucket handle journalPath journal planned emit

validateSession :: CellRef -> Bucket -> Lease -> SessionJournal -> Either Text ()
validateSession ref resultsBucket lease journal = do
  case eitherDecode (encode journal) :: Either String SessionJournal of
    Left failure -> Left (Text.pack failure)
    Right _ -> pure ()
  if journal.cell == ref.cellName && journal.controlBucket == ref.controlBucket.unBucket && journal.resultsBucket == resultsBucket.unBucket && journal.leaseId == lease.leaseId && journal.leaseMode == Held
    then pure ()
    else Left "session cell, bucket, lease or mode differs from the active held lease"

checkWorkFiles :: FilePath -> [SliceJournal] -> IO (Either Text ())
checkWorkFiles _ [] = pure (Right ())
checkWorkFiles directory (slice : rest) = do
  let path = directory </> slice.workPath
  present <- doesFileExist path
  if not present
    then pure (Left ("missing prepared work file: " <> Text.pack slice.workPath))
    else do
      bytes <- LazyByteString.readFile path
      if workObjectFor slice.submission.work.mediaType bytes /= slice.submission.work
        then pure (Left ("prepared work digest or size differs: " <> Text.pack slice.workPath))
        else checkWorkFiles directory rest

executeSlices :: ObjectStore -> CellRef -> Bucket -> LeaseHandle -> FilePath -> SessionJournal -> [SliceJournal] -> (WatchEvent -> IO ()) -> IO (Either SessionRunError SessionJournal)
executeSlices store ref resultsBucket handle journalPath journal slices emit = do
  current <- newIORef journal
  go current slices
  where
    directory = takeDirectory journalPath
    outRoot = takeDirectory directory
    go current [] = Right <$> readIORef current
    go current (slice : rest) = do
      bytes <- LazyByteString.readFile (directory </> slice.workPath)
      let checkpoint :: SessionTransition -> IO ()
          checkpoint transition = do
            before <- readIORef current
            now <- getCurrentTime
            changed <- either (ioError . userError . Text.unpack) pure (applyTransition now slice.cellRun transition before)
            writeSessionJournal journalPath changed
            writeIORef current changed
      result <- runSubmissionWithTransitions store ref resultsBucket handle slice.submission bytes outRoot emit checkpoint
      case result of
        Left failure -> pure (Left (SliceExecutionFailed slice.cellRun failure))
        Right _ -> go current rest
