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

-- A planned entry may be rebound only when it has no remote claim marker.
-- A submitted entry may be rebound under a different, renewed lease when no
-- status, rejection or result object exists: the new lease fences the old
-- agent's start_run.
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
            else case unresolved lease.leaseId journal.leaseId journal.slices of
              Just slice -> pure (Left (UnresolvedSlice slice.cellRun slice.state))
              Nothing -> do
                let planned = filter ((== SlicePlanned) . (.state)) journal.slices
                    pending = filter (\slice -> slice.state `elem` [SlicePlanned, SliceSubmitted]) journal.slices
                active <- firstSubmittedStatus (Bucket journal.resultsBucket) journal.slices
                case active of
                  Just slice -> pure (Left (UnresolvedSlice slice.cellRun slice.state))
                  Nothing -> do
                    present <- firstRemoteMarker planned
                    case present of
                      Just identifier -> pure (Left (RemoteMarkerExists identifier))
                      Nothing
                        | null pending -> pure (Right journal)
                        | otherwise -> do
                            rebound <- forM journal.slices \slice ->
                              if slice.state `elem` [SlicePlanned, SliceSubmitted]
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
    unresolved _ _ [] = Nothing
    unresolved activeLease priorLease (slice : rest)
      | slice.state `elem` [SliceSealed, SliceFetched] || (slice.state == SliceSubmitted && activeLease == priorLease) = Just slice
      | otherwise = unresolved activeLease priorLease rest
    firstSubmittedStatus _ [] = pure Nothing
    firstSubmittedStatus resultsBucket (slice : rest)
      | slice.state /= SliceSubmitted = firstSubmittedStatus resultsBucket rest
      | otherwise = do
          let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/"
              resultPrefix = "runs/" <> renderRunId slice.cellRun <> "/"
          visible <- or <$> forM ["status.json", "rejected.json"] (fmap isJust . store.statObject ref.controlBucket . ObjectName . (prefix <>))
          results <- store.listObjects resultsBucket resultPrefix
          if visible || not (null results) then pure (Just slice) else firstSubmittedStatus resultsBucket rest
    firstRemoteMarker [] = pure Nothing
    firstRemoteMarker (slice : rest) = do
      let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/"
      found <- or <$> forM ["submission.json", "status.json", "rejected.json"] (fmap isJust . store.statObject ref.controlBucket . ObjectName . (prefix <>))
      if found then pure (Just slice.cellRun) else firstRemoteMarker rest
