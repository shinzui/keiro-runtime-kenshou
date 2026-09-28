module Kenshou.Remote.Cell.Session.Rebind
  ( RebindError (..),
    rebindPlannedSlices,
  )
where

import Control.Monad (forM)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId, newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (Submission (..))
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), LeaseHandle, leaseSnapshot, renewLease)
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), SessionJournal (..), SliceJournal (..), SliceState (..), readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..))

data RebindError
  = InvalidJournal !Text
  | LeaseUnavailable
  | UnresolvedSlice !RunId !SliceState
  | RemoteMarkerExists !RunId
  deriving stock (Eq, Show)

-- A planned entry might have uploaded work before the client died. It may be
-- rebound only when no claim marker, status or rejection exists for that ID.
rebindPlannedSlices :: ObjectStore -> CellRef -> LeaseHandle -> FilePath -> IO (Either RebindError SessionJournal)
rebindPlannedSlices store ref handle journalPath = do
  decoded <- readSessionJournal journalPath
  case decoded of
    Left failure -> pure (Left (InvalidJournal failure))
    Right journal -> do
      lease <- leaseSnapshot handle
      held <- renewLease store ref handle
      if not held
        then pure (Left LeaseUnavailable)
        else
          if journal.cell /= ref.cellName || journal.controlBucket /= ref.controlBucket.unBucket || journal.leaseMode /= Held
            then pure (Left (InvalidJournal "session cell, control bucket or lease mode is incompatible with a held lease"))
            else case unresolved journal.slices of
              Just slice -> pure (Left (UnresolvedSlice slice.cellRun slice.state))
              Nothing -> do
                let planned = filter ((== SlicePlanned) . (.state)) journal.slices
                present <- firstRemoteMarker planned
                case present of
                  Just identifier -> pure (Left (RemoteMarkerExists identifier))
                  Nothing
                    | null planned -> pure (Right journal)
                    | otherwise -> do
                        rebound <- forM journal.slices \slice ->
                          if slice.state == SlicePlanned
                            then do
                              identifier <- newRunId
                              let previous = slice.submission
                                  submission = Submission identifier lease.leaseId previous.payload previous.work previous.env previous.reset previous.limits previous.requires previous.labels
                              pure (SliceJournal slice.index identifier slice.ordinals slice.runIds slice.reset submission slice.workPath SlicePlanned Nothing Nothing Nothing Nothing Nothing)
                            else pure slice
                        now <- getCurrentTime
                        let updated = journal {leaseId = lease.leaseId, slices = rebound, updatedAt = now}
                        writeSessionJournal journalPath updated
                        pure (Right updated)
  where
    unresolved [] = Nothing
    unresolved (slice : rest)
      | slice.state `elem` [SliceSubmitted, SliceSealed, SliceFetched] = Just slice
      | otherwise = unresolved rest
    firstRemoteMarker [] = pure Nothing
    firstRemoteMarker (slice : rest) = do
      let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/"
      found <- or <$> forM ["submission.json", "status.json", "rejected.json"] (fmap isJust . store.statObject ref.controlBucket . ObjectName . (prefix <>))
      if found then pure (Just slice.cellRun) else firstRemoteMarker rest
