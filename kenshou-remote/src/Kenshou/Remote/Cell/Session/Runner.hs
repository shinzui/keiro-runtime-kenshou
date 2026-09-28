module Kenshou.Remote.Cell.Session.Runner
  ( SessionRunError (..),
    runPlannedSlices,
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
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..), SliceState (..), applyTransition, writeSessionJournal)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.Watch (WatchEvent)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

data SessionRunError
  = InvalidSession !Text
  | SessionFileExists !FilePath
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
      case validate lease of
        Left problem -> pure (Left (InvalidSession problem))
        Right () -> do
          preflight <- checkWorkFiles journal.slices
          case preflight of
            Left problem -> pure (Left (InvalidSession problem))
            Right () -> do
              writeSessionJournal journalPath journal
              current <- newIORef journal
              runSlices current journal.slices
  where
    directory = takeDirectory journalPath
    outRoot = takeDirectory directory
    validate lease = do
      case eitherDecode (encode journal) :: Either String SessionJournal of
        Left failure -> Left (Text.pack failure)
        Right _ -> pure ()
      if journal.cell == ref.cellName && journal.controlBucket == ref.controlBucket.unBucket && journal.resultsBucket == resultsBucket.unBucket && journal.leaseId == lease.leaseId
        then pure ()
        else Left "session cell, bucket or lease differs from the active handle"
    checkWorkFiles [] = pure (Right ())
    checkWorkFiles (slice : rest)
      | slice.state /= SlicePlanned = pure (Left "new session contains a slice that is not planned")
      | otherwise = do
          let path = directory </> slice.workPath
          present <- doesFileExist path
          if not present
            then pure (Left ("missing prepared work file: " <> Text.pack slice.workPath))
            else do
              bytes <- LazyByteString.readFile path
              if workObjectFor slice.submission.work.mediaType bytes /= slice.submission.work
                then pure (Left ("prepared work digest or size differs: " <> Text.pack slice.workPath))
                else checkWorkFiles rest
    runSlices current [] = Right <$> readIORef current
    runSlices current (slice : rest) = do
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
        Right _ -> runSlices current rest
