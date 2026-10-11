module Kenshou.Remote.Perf.Cell
  ( CellAdapter (..),
    executeCellTrial,
    verifyCellTrial,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict', encode)
import Data.ByteString.Lazy qualified as Bytes
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (CellBuckets (..), CellDescriptor (..), CellNodes (..), CellOutcome (..), ResetBlock (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Index (CellManifestLink (..), CellRunIndex (..), EvidenceLink (..), deriveCellRunIndex)
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), LeaseHandle, leaseSnapshot, withHeartbeat)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities, RoutingRule)
import Kenshou.Remote.Cell.Session.Build
import Kenshou.Remote.Cell.Session.Journal
import Kenshou.Remote.Cell.Session.Resume
import Kenshou.Remote.Cell.Session.Runner
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.Watch (WatchEvent)
import Kenshou.Remote.Payload (PayloadDescriptor)
import Kenshou.Remote.Perf.Conditions (validateCellConditions)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

data CellAdapter = CellAdapter
  { registry :: Registry,
    store :: ObjectStore,
    ref :: CellRef,
    descriptor :: CellDescriptor,
    capabilities :: Maybe CellCapabilities,
    rules :: [RoutingRule],
    payloads :: Map Text PayloadDescriptor,
    options :: BuildOptions,
    storeLabel :: Text,
    emit :: WatchEvent -> IO ()
  }

-- Each trial has a separate low-level cell journal. Its work digest is checked
-- against the immutable paired schedule before any new or resumed submission.
executeCellTrial :: CellAdapter -> LeaseHandle -> RunPlan -> FilePath -> PlannedRun -> IO (Either Text FilePath)
executeCellTrial adapter handle schedule attempt run = do
  lease <- leaseSnapshot handle
  let directory = attempt </> "trials" </> Text.unpack (renderRunId run.runId)
      journalPath = directory </> "session.json"
      bytes = encode schedule {runs = [run], estimateMinutes = run.estimateMinutes}
      expected = (workObjectFor "application/json" bytes).sha256
      results = Bucket adapter.descriptor.buckets.results
  exists <- doesFileExist journalPath
  result <- withHeartbeat adapter.store adapter.ref handle \_ ->
    if exists
      then do
        saved <- readSessionJournal journalPath
        case saved of
          Left problem -> pure (Left problem)
          Right journal
            | journal.leaseId /= lease.leaseId || journal.planSha256 /= expected || journal.payloads /= adapter.payloads ->
                pure (Left "retained cell journal differs from the pinned trial, payloads or lease")
          Right _ -> continue results journalPath
      else do
        built <- buildSession adapter.registry adapter.descriptor adapter.capabilities adapter.rules adapter.payloads adapter.options adapter.storeLabel lease.leaseId bytes
        case built of
          Left problem -> pure (Left problem)
          Right session -> do
            createDirectoryIfMissing True directory
            Bytes.writeFile (directory </> "plan.json") bytes
            mapM_
              ( \(relative, content) -> do
                  createDirectoryIfMissing True (takeDirectory (directory </> relative))
                  Bytes.writeFile (directory </> relative) content
              )
              session.workFiles
            either (Left . Text.pack . show) Right <$> runPlannedSlices adapter.store adapter.ref results handle journalPath session.journal adapter.emit
  case result of
    Left problem -> pure (Left problem)
    Right journal -> verifyCellTrial adapter.descriptor run directory journal
  where
    continue results journalPath = do
      resumed <- resumeHeldSession adapter.store adapter.ref results handle journalPath adapter.emit
      case resumed of
        Left (ContinuationError (UnresolvedSlice _ SliceSubmitted)) -> threadDelay 2000000 >> continue results journalPath
        Left failure -> pure (Left (Text.pack (show failure)))
        Right journal -> pure (Right journal)

-- Recheck the outer cell seal and health even when a low-level journal already
-- says verified. An exit-one runtime result is still returned for independent
-- runtime classification; failed cell health cannot become a valid trial.
verifyCellTrial :: CellDescriptor -> PlannedRun -> FilePath -> SessionJournal -> IO (Either Text FilePath)
verifyCellTrial descriptor run directory journal = case journal.slices of
  [slice] | slice.state == SliceVerified && slice.runIds == [run.runId] -> do
    let tree = takeDirectory directory </> Text.unpack (renderRunId slice.cellRun) </> "tree"
    verified <- deriveCellRunIndex (Bucket journal.resultsBucket) Nothing tree
    let evidencePresent = either (const False) (\index -> all (`elem` map (.kind) index.evidence) ["cell-health", "cell-reset-evidence"]) verified
    conditions <-
      if evidencePresent
        then do
          health <- eitherDecodeFileStrict' (tree </> "cell/health.json")
          reset <- eitherDecodeFileStrict' (tree </> "cell/reset-evidence.json")
          let machines =
                descriptor.instances.drivers
                  <> [descriptor.instances.postgres, descriptor.instances.monitoring]
                  <> case (slice.submission.reset.broker, descriptor.instances.broker) of (Just _, Just broker) -> [broker]; _ -> []
          pure do
            healthDocument <- either (Left . Text.pack) Right health
            resetDocument <- either (Left . Text.pack) Right reset
            validateCellConditions slice.cellRun descriptor.name machines healthDocument resetDocument
        else pure (Left "outer cell is missing sealed health or reset evidence")
    pure do
      index <- either (Left . Text.pack . show) Right verified
      conditions
      unless
        ( index.cellOutcome == Completed
            && index.leaseId == journal.leaseId
            && index.cell == journal.cell
            && index.cellRun == slice.cellRun
            && slice.manifestSha256 == Just index.cellManifest.sha256
        )
        (Left "outer cell identity, seal or health differs from its journal")
      pure (tree </> "output" </> Text.unpack (renderRunId run.runId))
  _ -> pure (Left "cell trial is incomplete, rejected or has unexpected runs")
