module Kenshou.Remote.Cell.Watch
  ( WatchCursor,
    WatchEvent (..),
    WatchTerminal (..),
    WatchSnapshot (..),
    newWatchCursor,
    pollCellRun,
    watchCellRun,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, eitherDecode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (RunId, renderRunId)
import Kenshou.Remote.Cell.Docs (CellPhase (..), CellStatus (..), LogChunks (..), Rejected (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Store (ObjectName (..), ObjectStore (..))

data WatchCursor = WatchCursor
  { lastPhase :: !(Maybe CellPhase),
    stdoutNext :: !Int,
    stderrNext :: !Int
  }
  deriving stock (Eq, Show)

data WatchEvent
  = PhaseChanged !CellPhase
  | StdoutChunk !LazyByteString.ByteString
  | StderrChunk !LazyByteString.ByteString
  deriving stock (Eq, Show)

data WatchTerminal = RunSealed !CellStatus | RunRejected !Rejected
  deriving stock (Eq, Show)

data WatchSnapshot = WatchSnapshot
  { cursor :: !WatchCursor,
    events :: ![WatchEvent],
    terminal :: !(Maybe WatchTerminal)
  }
  deriving stock (Eq, Show)

newWatchCursor :: WatchCursor
newWatchCursor = WatchCursor Nothing 0 0

pollCellRun :: ObjectStore -> CellRef -> RunId -> WatchCursor -> IO WatchSnapshot
pollCellRun store ref identifier cursor = do
  let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId identifier <> "/"
  rejected <- readDocument store ref (ObjectName (prefix <> "rejected.json"))
  case rejected of
    Just record -> do
      unless (record.runId == identifier) (ioError (userError "cell rejection names another run"))
      pure (WatchSnapshot cursor [] (Just (RunRejected record)))
    Nothing -> do
      status <- readDocument store ref (ObjectName (prefix <> "status.json"))
      case status of
        Nothing -> pure (WatchSnapshot cursor [] Nothing)
        Just current -> do
          unless (current.runId == identifier) (ioError (userError "cell status names another run"))
          unless (current.logChunks.stdout >= cursor.stdoutNext && current.logChunks.stderr >= cursor.stderrNext) (ioError (userError "cell log chunk count moved backwards"))
          stdout <- readChunks "stdout" cursor.stdoutNext current.logChunks.stdout StdoutChunk prefix
          stderr <- readChunks "stderr" cursor.stderrNext current.logChunks.stderr StderrChunk prefix
          let changed = if cursor.lastPhase == Just current.phase then [] else [PhaseChanged current.phase]
              next = WatchCursor (Just current.phase) current.logChunks.stdout current.logChunks.stderr
              done = if current.phase == Sealed then Just (RunSealed current) else Nothing
          pure (WatchSnapshot next (changed <> stdout <> stderr) done)
  where
    readChunks :: Text -> Int -> Int -> (LazyByteString.ByteString -> WatchEvent) -> Text -> IO [WatchEvent]
    readChunks stream first end wrap prefix = forM [first .. end - 1] \index -> do
      let object = ObjectName (prefix <> "log/" <> stream <> "." <> showText index)
      stored <- store.getObject ref.controlBucket object
      case stored of
        Nothing -> ioError (userError ("missing cell log chunk " <> show object))
        Just (bytes, _) -> pure (wrap bytes)

watchCellRun :: ObjectStore -> CellRef -> RunId -> (WatchEvent -> IO ()) -> IO WatchTerminal
watchCellRun store ref identifier emit = loop newWatchCursor
  where
    loop cursor = do
      snapshot <- pollCellRun store ref identifier cursor
      mapM_ emit snapshot.events
      case snapshot.terminal of
        Just terminal -> pure terminal
        Nothing -> threadDelay 2000000 >> loop snapshot.cursor

readDocument :: (FromJSON document) => ObjectStore -> CellRef -> ObjectName -> IO (Maybe document)
readDocument store ref name = do
  stored <- store.getObject ref.controlBucket name
  case stored of
    Nothing -> pure Nothing
    Just (bytes, _) -> case eitherDecode bytes of
      Left failure -> ioError (userError ("invalid cell document at " <> show name <> ": " <> failure))
      Right value -> pure (Just value)

showText :: Int -> Text
showText = Text.pack . show
