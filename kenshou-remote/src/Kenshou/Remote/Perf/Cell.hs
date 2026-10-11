module Kenshou.Remote.Perf.Cell
  ( CellAdapter (..),
    executeCellTrial,
    verifyCellTrial,
    retainedRuntimeProblems,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, displayException)
import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeFileStrict', encode)
import Data.ByteString.Lazy qualified as Bytes
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), RunSpec (..))
import Kenshou.Measure.Perf (AdmissionProblem (..), runtimeResultProblems, verifyPerformanceRun)
import Kenshou.Perf.Plan (PerfProfile)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (CellBuckets (..), CellDescriptor (..), CellImages (..), CellNodes (..), CellOutcome (..), Requirements (..), ResetBlock (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Index (CellManifestLink (..), CellRunIndex (..), EvidenceLink (..), RunLink (..), deriveCellRunIndex)
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), LeaseHandle, leaseSnapshot, withHeartbeat)
import Kenshou.Remote.Cell.Prepare (cellMachineProfile)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities, RoutingRule)
import Kenshou.Remote.Cell.Session.Build
import Kenshou.Remote.Cell.Session.Journal
import Kenshou.Remote.Cell.Session.Resume
import Kenshou.Remote.Cell.Session.Runner
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.Watch (WatchEvent)
import Kenshou.Remote.Payload (PayloadDescriptor)
import Kenshou.Remote.Perf.Conditions (validateCellConditions, validateCellObservations)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

data CellAdapter = CellAdapter
  { registry :: Registry,
    store :: ObjectStore,
    ref :: CellRef,
    descriptor :: CellDescriptor,
    healthPolicy :: Value,
    capabilities :: Maybe CellCapabilities,
    rules :: [RoutingRule],
    payloads :: Map Text PayloadDescriptor,
    options :: BuildOptions,
    storeLabel :: Text,
    emit :: WatchEvent -> IO ()
  }

-- Each trial has a separate low-level cell journal. Its work digest is checked
-- against the immutable paired schedule before any new or resumed submission.
executeCellTrial :: CellAdapter -> LeaseHandle -> RunPlan -> FilePath -> PerfProfile -> (Text -> IO ()) -> PlannedRun -> IO (Either Text FilePath)
executeCellTrial adapter handle schedule attempt profile observeRuntime run = do
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
    Right journal -> do
      problems <- retainedRuntimeProblems profile run directory journal
      mapM_ observeRuntime problems
      verifyCellTrial adapter.healthPolicy adapter.descriptor run directory journal
  where
    continue results journalPath = do
      resumed <- resumeHeldSession adapter.store adapter.ref results handle journalPath adapter.emit
      case resumed of
        Left (ContinuationError (UnresolvedSlice _ SliceSubmitted)) -> threadDelay 2000000 >> continue results journalPath
        Left failure -> pure (Left (Text.pack (show failure)))
        Right journal -> pure (Right journal)

-- A bad outer health gate cannot erase a sealed nested runtime assertion or
-- failed/incomplete steady work. Reconstruct these before rejecting the pair.
retainedRuntimeProblems :: PerfProfile -> PlannedRun -> FilePath -> SessionJournal -> IO [Text]
retainedRuntimeProblems profile run directory journal = case journal.slices of
  [slice] | slice.state `elem` [SliceFetched, SliceVerified] -> do
    let tree = takeDirectory directory </> Text.unpack (renderRunId slice.cellRun) </> "tree"
    verified <- deriveCellRunIndex (Bucket journal.resultsBucket) Nothing tree
    case verified of
      Right index | index.cellRun == slice.cellRun && index.leaseId == journal.leaseId && index.cell == journal.cell && slice.manifestSha256 == Just index.cellManifest.sha256 && slice.cellOutcome == Just index.cellOutcome && any (\link -> link.runId == run.runId && link.path == "output/" <> renderRunId run.runId) index.runs -> do
        let nested = tree </> "output" </> Text.unpack (renderRunId run.runId)
        result <- eitherDecodeFileStrict' (nested </> "run-result.json")
        measured <- verifyPerformanceRun profile nested
        pure ([reason | RuntimeWorkFailure reason <- either (const []) runtimeResultProblems result <> either id (const []) measured])
      _ -> pure []
  _ -> pure []

-- Recheck the outer cell seal and health even when a low-level journal already
-- says verified. An exit-one runtime result is still returned for independent
-- runtime classification; failed cell health cannot become a valid trial.
verifyCellTrial :: Value -> CellDescriptor -> PlannedRun -> FilePath -> SessionJournal -> IO (Either Text FilePath)
verifyCellTrial healthPolicy descriptor run directory journal =
  catch (verifyTrial healthPolicy descriptor run directory journal) (\(problem :: IOException) -> pure (Left (Text.pack (displayException problem))))

verifyTrial :: Value -> CellDescriptor -> PlannedRun -> FilePath -> SessionJournal -> IO (Either Text FilePath)
verifyTrial healthPolicy descriptor run directory journal = case journal.slices of
  [slice] | slice.state == SliceVerified && slice.runIds == [run.runId] -> do
    let tree = takeDirectory directory </> Text.unpack (renderRunId slice.cellRun) </> "tree"
    verified <- deriveCellRunIndex (Bucket journal.resultsBucket) Nothing tree
    let evidencePresent = either (const False) (\index -> all (`elem` map (.kind) index.evidence) ["cell-health", "cell-reset-evidence"]) verified
    conditions <-
      if evidencePresent
        then do
          health <- eitherDecodeFileStrict' (tree </> "cell/health.json")
          reset <- eitherDecodeFileStrict' (tree </> "cell/reset-evidence.json")
          interval <- eitherDecodeFileStrict' (tree </> "cell/execution-window.json")
          let roles = [("driver", (case descriptor.instances.drivers of driver : _ -> driver; [] -> ""), descriptor.images.driver), ("postgres", descriptor.instances.postgres, descriptor.images.postgres), ("monitoring", descriptor.instances.monitoring, descriptor.images.monitoring)] <> case (slice.submission.reset.broker, descriptor.instances.broker) of (Just _, Just broker) -> [("broker", broker, descriptor.images.broker)]; _ -> []
          raw <- traverse (\(role, machine, image) -> do value <- eitherDecodeFileStrict' (tree </> "cell/observations" </> Text.unpack role <> ".json"); pure (role, machine, image, value)) roles
          let machines =
                descriptor.instances.drivers
                  <> [descriptor.instances.postgres, descriptor.instances.monitoring]
                  <> case (slice.submission.reset.broker, descriptor.instances.broker) of (Just _, Just broker) -> [broker]; _ -> []
          pure do
            healthDocument <- either (Left . Text.pack) Right health
            resetDocument <- either (Left . Text.pack) Right reset
            validateCellConditions slice.cellRun descriptor.name machines healthDocument resetDocument
            executionWindow <- either (Left . Text.pack) Right interval
            windows <- traverse (\(role, machine, image, value) -> (role,machine,image,) <$> either (Left . Text.pack) Right value) raw
            validateCellObservations slice.cellRun slice.submission.requires.minAgentVersion healthPolicy healthDocument executionWindow windows
        else pure (Left "outer cell is missing sealed health or reset evidence")
    effective <- eitherDecodeFileStrict' (tree </> "output" </> Text.unpack (renderRunId run.runId) </> "run-spec.json") :: IO (Either String RunSpec)
    pure do
      index <- either (Left . Text.pack . show) Right verified
      conditions
      spec <- either (Left . Text.pack) Right effective
      unless (spec.environment.machineProfile == Just (cellMachineProfile descriptor)) (Left "effective machine profile differs from the frozen cell descriptor")
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
