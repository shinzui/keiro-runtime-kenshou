module Kenshou.Remote.Perf.Cleanup (ownedWorkSettled, waitForOwnedWork) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (eitherDecode)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Remote.Cell.Docs (CellPhase (Sealed), CellStatus (..), Rejected (..), Submission (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..), SliceState (..))
import Kenshou.Remote.Perf.Journal (LeaseIdentity (..))
import Kenshou.Remote.Store (ObjectName (..), ObjectStore (..))
import Kenshou.Remote.Store qualified as Store

-- Caller bounds this wait with the original cleanup deadline. Do not clear a
-- lease while an ambiguous or active submitted unit still belongs to it.
waitForOwnedWork :: ObjectStore -> CellRef -> LeaseIdentity -> [SessionJournal] -> IO ()
waitForOwnedWork store ref identity journals = do
  settled <- ownedWorkSettled store ref identity journals
  unless settled (threadDelay 1000000 >> waitForOwnedWork store ref identity journals)

ownedWorkSettled :: ObjectStore -> CellRef -> LeaseIdentity -> [SessionJournal] -> IO Bool
ownedWorkSettled store ref identity journals = do
  unless (ref.cellName == identity.cell) (ioError (userError "owned cleanup reference names another cell"))
  unless (all ((== refBucket) . (.controlBucket)) owned) (ioError (userError "owned cleanup journal names another control bucket"))
  and <$> traverse inspect slices
  where
    Store.Bucket refBucket = ref.controlBucket
    owned = [journal | journal <- journals, journal.cell == identity.cell, journal.leaseId == identity.leaseId]
    slices = concatMap (.slices) owned
    inspect slice = do
      let prefix = "cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/"
          get name = store.getObject ref.controlBucket (ObjectName (prefix <> name))
      marker <- get "submission.json"
      case marker of
        Nothing -> pure (slice.state == SlicePlanned)
        Just (bytes, _) -> do
          submission <- either (ioError . userError) pure (eitherDecode bytes)
          unless ((submission :: Submission).leaseId == identity.leaseId && submission == slice.submission) (ioError (userError "owned cleanup submission differs from its retained journal"))
          rejected <- get "rejected.json"
          case rejected of
            Just (body, _) -> do
              record <- either (ioError . userError) pure (eitherDecode body)
              unless ((record :: Rejected).runId == slice.cellRun) (ioError (userError "owned cleanup rejection names another run"))
              pure True
            Nothing -> do
              status <- get "status.json"
              case status of
                Nothing -> pure False
                Just (body, _) -> do
                  record <- either (ioError . userError) pure (eitherDecode body)
                  unless ((record :: CellStatus).runId == slice.cellRun) (ioError (userError "owned cleanup status names another run"))
                  pure (record.phase == Sealed && record.manifestSha256 /= Nothing && record.outcome /= Nothing)
