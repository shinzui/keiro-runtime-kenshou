module Kenshou.Cli.Command.Perf.Session (sessionCommands, replayCalibrationReceipt, verifyCalibrationAdmission) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, IOException, catch, displayException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson hiding (decode)
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.List (find, isSuffixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kenshou.Cli.Command.Cell (startCellInstances)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cli (CliEnv (..))
import Kenshou.Core.Id
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Measure.Compare.Compatibility (VaryingAxis (..))
import Kenshou.Measure.Compare.Ordering (PairedOrdering (ABBA))
import Kenshou.Measure.Compare.Policy (Direction (..), MetricRule (..), Policy, matchesRule)
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Perf.Artifacts
import Kenshou.Perf.Calibration qualified as Calibration
import Kenshou.Perf.Plan
import Kenshou.Perf.Plan qualified as PerfPlan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Request (PerfRequest (..), strictObject)
import Kenshou.Perf.Result
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Control
import Kenshou.Remote.Cell.Docs (CachePolicy (Cold), CellBuckets (..), CellDescriptor (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease qualified as Lease
import Kenshou.Remote.Cell.Prepare
import Kenshou.Remote.Cell.RouteRules
import Kenshou.Remote.Cell.Session.Build (BuildOptions (..), buildSession)
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..), readSessionJournal)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Pair
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Publish (digestFile)
import Kenshou.Remote.Perf.Attempt
import Kenshou.Remote.Perf.Cell
import Kenshou.Remote.Perf.Cleanup
import Kenshou.Remote.Perf.Journal
import Kenshou.Remote.Perf.Lock
import Kenshou.Remote.Perf.Publication
import Kenshou.Remote.Perf.Runner
import Kenshou.Remote.Store
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Remote.Store.Gcs (newGcsStore, newTokenProvider)
import Options.Applicative hiding (Success, action)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)
import Text.Printf (printf)

data SessionFailure = SessionFailure Int Text deriving stock (Show)

instance Exception SessionFailure

data PublicationReceipt = PublicationReceipt
  { snapshot :: Text,
    manifestUri :: Text,
    manifestSha256 :: Text,
    resultSha256 :: Text,
    payloadsReadyAt :: UTCTime,
    publicationStartedAt :: UTCTime,
    verifiedReportAt :: UTCTime,
    totalElapsedSeconds :: Double
  }
  deriving stock (Eq, Show)

instance ToJSON PublicationReceipt where
  toJSON receipt = object ["schema" .= ("kenshou.perf-publication/v1" :: Text), "snapshot" .= receipt.snapshot, "manifestUri" .= receipt.manifestUri, "manifestSha256" .= receipt.manifestSha256, "resultSha256" .= receipt.resultSha256, "payloadsReadyAt" .= receipt.payloadsReadyAt, "publicationStartedAt" .= receipt.publicationStartedAt, "verifiedReportAt" .= receipt.verifiedReportAt, "totalElapsedSeconds" .= receipt.totalElapsedSeconds]

instance FromJSON PublicationReceipt where
  parseJSON = withObject "PerformanceReceipt" \v -> do
    strictObject ["schema", "snapshot", "manifestUri", "manifestSha256", "resultSha256", "payloadsReadyAt", "publicationStartedAt", "verifiedReportAt", "totalElapsedSeconds"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-publication/v1" :: Text)) (fail "unsupported publication receipt")
    receipt <- PublicationReceipt <$> v .: "snapshot" <*> v .: "manifestUri" <*> v .: "manifestSha256" <*> v .: "resultSha256" <*> v .: "payloadsReadyAt" <*> v .: "publicationStartedAt" <*> v .: "verifiedReportAt" <*> v .: "totalElapsedSeconds"
    unless (receipt.payloadsReadyAt <= receipt.publicationStartedAt && receipt.publicationStartedAt <= receipt.verifiedReportAt && abs (receipt.totalElapsedSeconds - realToFrac (diffUTCTime receipt.verifiedReportAt receipt.payloadsReadyAt)) < 0.000001) (fail "publication receipt timing mismatch")
    pure receipt

data ExecutionInputs = ExecutionInputs
  { controlBucket :: Text,
    storeLabel :: Text,
    allowedProjects :: [Text],
    start :: Bool,
    cells :: [(CellDescriptor, Maybe CellCapabilities)]
  }

instance ToJSON ExecutionInputs where
  toJSON inputs = object ["controlBucket" .= inputs.controlBucket, "storeLabel" .= inputs.storeLabel, "allowedProjects" .= inputs.allowedProjects, "start" .= inputs.start, "cells" .= [object ["descriptor" .= descriptor, "capabilities" .= capabilities] | (descriptor, capabilities) <- inputs.cells]]

instance FromJSON ExecutionInputs where
  parseJSON = withObject "PerformanceExecutionInputs" \v -> do
    strictObject ["controlBucket", "storeLabel", "allowedProjects", "start", "cells"] v
    entries <-
      v .: "cells"
        >>= traverse
          ( withObject "PinnedCell" \c -> do
              strictObject ["descriptor", "capabilities"] c
              (,) <$> c .: "descriptor" <*> c .:? "capabilities"
          )
    ExecutionInputs <$> v .: "controlBucket" <*> v .: "storeLabel" <*> v .: "allowedProjects" <*> v .: "start" <*> pure entries

sessionCommands :: Mod CommandFields (CliEnv -> IO ExitCode)
sessionCommands =
  command "run" (info (runParser <**> helper) (progDesc "Execute a pinned performance preparation with persistent budgets"))
    <> command "status" (info (statusParser <**> helper) (progDesc "Read persistent performance session state without cell actions"))
    <> command "resume" (info (resumeParser <**> helper) (progDesc "Verify inputs and reconcile a retained performance session"))
    <> command "verify" (info (verifyParser <**> helper) (progDesc "Replay retained comparisons and verify published evidence without executing trials"))
    <> command "calibration" (info (calibrationParser <**> helper) (progDesc "Freeze calibration batches and verify their retained acceptance evidence"))
  where
    session = strOption (long "session" <> metavar "DIRECTORY")
    runParser = runNew <$> strOption (long "prepared" <> metavar "FILE") <*> strOption (long "evidence-base-uri" <> metavar "GS_URI") <*> strOption (long "out" <> metavar "DIRECTORY") <*> strOption (long "control-bucket" <> value "tan-nb-exp-cells-control" <> showDefault) <*> switch (long "start" <> help "Start stopped instances after acquiring their cell lease")
    statusParser = runStatus <$> session
    resumeParser = runResume <$> session
    verifyParser = runVerify <$> session <*> switch (long "offline" <> help "Verify the retained sealed snapshot and receipt without contacting storage")
    calibrationParser =
      hsubparser
        ( command "declare" (info (runCalibrationPublish True <$> strOption (long "definition" <> metavar "FILE") <*> strOption (long "uri" <> metavar "GS_URI")) (progDesc "Create and retrieve a frozen definition before any acceptance trials"))
            <> command "publish" (info (runCalibrationPublish False <$> strOption (long "acceptance" <> metavar "FILE") <*> strOption (long "uri" <> metavar "GS_URI")) (progDesc "Create and retrieve the complete acceptance receipt inventory"))
            <> command "verify" (info (runCalibrationVerify <$> strOption (long "reference" <> metavar "FILE") <*> strOption (long "prepared" <> metavar "FILE")) (progDesc "Replay every calibration receipt against one prepared profile"))
        )

runNew :: FilePath -> Text -> FilePath -> Text -> Bool -> CliEnv -> IO ExitCode
runNew preparedPath uri destination bucket start environment = guarded do
  prepared <- eitherDecodeFileStrict' preparedPath >>= either (throwIO . SessionFailure 2 . Text.pack) pure
  input (Prepared.validatePrepared prepared)
  _ <- input (parseDestination uri)
  input (initialSessionPlaceholder prepared uri)
  verifyPerfManifest (takeDirectory preparedPath) >>= require
  exists <- doesPathExist destination
  when exists (throwIO (SessionFailure 2 "performance output already exists"))
  verifyGatingCalibration prepared
  output <- makeAbsolute destination
  (store, label) <- openStore (Bucket bucket)
  projects <- maybe ["tan-nb-exp"] (map Text.strip . Text.splitOn "," . Text.pack) <$> lookupEnv "KENSHOU_GCP_ALLOWED_PROJECTS"
  capabilityDirectory <- fromMaybe ".dev/cells" <$> lookupEnv "KENSHOU_CELL_CAPABILITIES_DIR"
  pinned <- traverse (loadCell store projects capabilityDirectory bucket) prepared.plan.request.cells
  let inputs = ExecutionInputs bucket label projects start pinned
  payloads <- loadPayloads store prepared
  payloadsReady <- getCurrentTime
  identifier <- newRunId
  preflight environment store inputs payloads prepared identifier
  -- The create-only probe is retained as evidence of the actual destination
  -- permissions. It needs object creation and retrieval, never deletion.
  accessProbe store uri identifier prepared
  session <- require (initialSession identifier (Prepared.preparedDigest prepared) prepared.plan uri payloadsReady)
  createDirectoryIfMissing True (takeDirectory output)
  createDirectory output
  copyTree (takeDirectory preparedPath) (output </> "preparation")
  encodeFile (output </> "prepared.json") prepared
  encodeFile (output </> "request.json") prepared.plan.request
  encodeFile (output </> "plan.json") prepared.plan
  writePerfSession (output </> "session.json") session {executionInputs = Just (toJSON inputs)}
  withPerformanceLock output (execute environment store inputs payloads prepared output)

-- Validate the destination using the same immutable journal admission rules
-- before obtaining an ID, writing output or performing any remote operation.
initialSessionPlaceholder :: Prepared.PerfPrepared -> Text -> Either Text ()
initialSessionPlaceholder prepared uri = do
  identifier <- parseRunId "00000000-0000-7000-8000-000000000000"
  let epoch = posixSecondsToUTCTime 0
  _ <- initialSession identifier (Prepared.preparedDigest prepared) prepared.plan uri epoch
  pure ()

runResume :: FilePath -> CliEnv -> IO ExitCode
runResume destination environment = guarded do
  output <- makeAbsolute destination
  withPerformanceLock output do
    prepared <- loadPreparation (output </> "preparation/prepared.json")
    session <- readPerfSession (output </> "session.json") >>= require
    require (validateSessionInputs prepared session)
    checkRootInputs output prepared
    verifyGatingCalibration prepared
    inputs <- require (parseInputs session)
    state <- require (journalState session)
    receiptExists <- doesFileExist (output </> "receipt.json")
    if receiptExists && state.lease == Nothing && state.activeComparison == Nothing && Map.size state.completed == length session.plan.selected
      then do
        (result, _) <- verifySessionEvidence output False
        receipt <- readJSON (output </> "receipt.json")
        retained <- readPerfSession (output </> Text.unpack (receipt :: PublicationReceipt).snapshot </> "session.json") >>= require
        unless (retained == session) (ioError (userError "published report does not describe the current session"))
        Lazy.putStrLn (encode result)
        pure (exit result.exitCode)
      else do
        (store, label) <- openStore (Bucket inputs.controlBucket)
        unless (inputs.storeLabel == label) (ioError (userError "object store differs from the immutable performance session"))
        mapM_ (checkCell store inputs) inputs.cells
        payloads <- loadPayloads store prepared
        preflight environment store inputs payloads prepared session.sessionId
        execute environment store inputs payloads prepared output

runStatus :: FilePath -> CliEnv -> IO ExitCode
runStatus output _ = guarded do
  session <- readPerfSession (output </> "session.json") >>= require
  state <- require (journalState session)
  now <- getCurrentTime
  Lazy.putStrLn (encode (object ["session" .= session.sessionId, "requestSha256" .= session.plan.requestSha256, "admissionSpentSeconds" .= state.admissionSpentSeconds, "executionDeadline" .= state.executionDeadline, "cleanupDeadline" .= state.cleanupDeadline, "lease" .= state.lease, "activeComparison" .= state.activeComparison, "attempts" .= state.attempts, "replacements" .= state.replacements, "completed" .= Map.elems state.completed, "runtimeBlockers" .= state.runtimeBlockers, "totalElapsedSeconds" .= (realToFrac (diffUTCTime now session.createdAt) :: Double)]))
  pure ExitSuccess

loadPreparation :: FilePath -> IO Prepared.PerfPrepared
loadPreparation path = do
  verifyPerfManifest (takeDirectory path) >>= require
  prepared <- readJSON path
  require (Prepared.validatePrepared prepared)
  pure prepared

loadCell :: ObjectStore -> [Text] -> FilePath -> Text -> Text -> IO (CellDescriptor, Maybe CellCapabilities)
loadCell store projects directory bucket name = do
  snapshot <- readCellSnapshot store (Lease.CellRef name (Bucket bucket)) projects >>= require
  capabilities <- loadCellCapabilities directory snapshot.descriptor >>= require
  pure (snapshot.descriptor, capabilities)

checkCell :: ObjectStore -> ExecutionInputs -> (CellDescriptor, Maybe CellCapabilities) -> IO ()
checkCell store inputs (descriptor, _) = do
  snapshot <- readCellSnapshot store (Lease.CellRef descriptor.name (Bucket inputs.controlBucket)) inputs.allowedProjects >>= require
  unless (snapshot.descriptor == descriptor) (ioError (userError "cell descriptor changed since performance preparation"))

parseInputs :: PerfSession -> Either Text ExecutionInputs
parseInputs session = do
  inputs <- maybe (Left "performance session has no frozen execution inputs") decode session.executionInputs
  unless (map ((.name) . fst) inputs.cells == session.plan.request.cells && not (Text.null inputs.controlBucket) && not (null inputs.allowedProjects)) (Left "frozen cell pool differs from the request")
  mapM_
    ( \(descriptor, capabilities) -> do
        unless (descriptor.buckets.control == inputs.controlBucket && descriptor.project `elem` inputs.allowedProjects) (Left "frozen cell bucket or project is invalid")
        case capabilities of
          Nothing -> pure ()
          Just record -> unless (record.cell == descriptor.name && record.descriptorSha256 == descriptorDigest descriptor) (Left "frozen capabilities differ from the cell descriptor")
    )
    inputs.cells
  pure inputs

checkRootInputs :: FilePath -> Prepared.PerfPrepared -> IO ()
checkRootInputs directory prepared = mapM_ check [("prepared.json", toJSON prepared), ("plan.json", toJSON prepared.plan), ("request.json", toJSON prepared.plan.request)]
  where
    check (name, expected) = do
      actual <- readJSON (directory </> name)
      unless (actual == expected) (ioError (userError ("retained " <> name <> " differs from immutable preparation")))

loadPayloads :: ObjectStore -> Prepared.PerfPrepared -> IO (Map.Map Text PayloadDescriptor)
loadPayloads store prepared = do
  entries <-
    traverse
      ( \(label, arm) -> do
          payload <- require (decode arm.payload)
          let prefix = "gs://"
              (bucket, suffix) = Text.breakOn "/" (Text.drop (Text.length prefix) payload.cell.bundle.uri)
          unless (prefix `Text.isPrefixOf` payload.cell.bundle.uri && not (Text.null bucket) && suffix == "/payloads/sha256/" <> payload.cell.bundle.sha256 <> ".nar.zst") (ioError (userError "invalid pinned payload location"))
          withSystemTempDirectory "kenshou-perf-payload-check" \temporary -> do
            let path = temporary </> "bundle.nar.zst"
            present <- store.downloadTo (Bucket bucket) (ObjectName (Text.drop 1 suffix)) path
            unless (present /= Nothing) (ioError (userError "pinned payload is missing"))
            (digest, bytes) <- digestFile path
            unless (digest == payload.cell.bundle.sha256 && bytes == payload.cell.bundle.bytes) (ioError (userError "pinned payload retrieval digest differs"))
          pure (label, payload)
      )
      [("baseline", prepared.baseline), ("candidate", prepared.candidate)]
  pure (Map.fromList entries)

options :: BuildOptions
options = BuildOptions (PrepareOptions False False [] Cold) GranularityRun False NullSink Nothing (24 * 1024 * 1024 * 1024) (20 * 1024 * 1024 * 1024) "0.1.0"

adapter :: CliEnv -> ObjectStore -> ExecutionInputs -> Map.Map Text PayloadDescriptor -> (CellDescriptor, Maybe CellCapabilities) -> CellAdapter
adapter environment store inputs payloads (descriptor, capabilities) = CellAdapter environment.registry store (Lease.CellRef descriptor.name (Bucket inputs.controlBucket)) descriptor capabilities defaultRoutingRules payloads options inputs.storeLabel (\event -> TextIO.hPutStrLn stderr (Text.pack (show event)))

preflight :: CliEnv -> ObjectStore -> ExecutionInputs -> Map.Map Text PayloadDescriptor -> Prepared.PerfPrepared -> RunId -> IO ()
preflight environment store inputs payloads prepared identifier = mapM_ check prepared.plan.selected
  where
    check entry = do
      schedule <- makeSchedule prepared entry identifier
      compatible <-
        traverse
          ( \pinned -> do
              let a = adapter environment store inputs payloads pinned
              built <- buildSession a.registry a.descriptor a.capabilities a.rules a.payloads a.options a.storeLabel identifier (encode schedule)
              pure (either (const False) (const (prepared.plan.request.purpose == "calibration" || entry.profile.machineProfile == cellMachineProfile a.descriptor)) built)
          )
          inputs.cells
      unless (or compatible) (ioError (userError ("no pinned cell supports profile " <> Text.unpack entry.profile.name)))

makeSchedule :: Prepared.PerfPrepared -> PlannedProfile -> RunId -> IO RunPlan
makeSchedule prepared entry identifier = do
  let profile = entry.profile
      source = object ["schema" .= ("kenshou.run-plan/v1" :: Text), "planId" .= identifier, "inputs" .= object ["preparedSha256" .= Prepared.preparedDigest prepared, "workloadSha256" .= entry.workloadSha256], "runs" .= [object ["ordinal" .= (1 :: Int), "runId" .= identifier, "estimateMinutes" .= (1 :: Int), "spec" .= object ["schema" .= ("kenshou.run-spec/v1" :: Text), "runId" .= identifier, "scenario" .= profile.scenario, "scenarioRevision" .= profile.scenarioRevision, "knobs" .= profile.knobs, "dimensions" .= profile.dimensions, "seed" .= prepared.plan.request.seed, "phases" .= zeroPhases, "timeoutSeconds" .= profile.timeoutSeconds, "environment" .= object ["placement" .= ("cell" :: Text), "machineProfile" .= profile.machineProfile]]]]]
  projected <- require (decodeWorkPlan source)
  require (pairPlan (PairRequest "candidate" "baseline" profile.minimumPairs ABBA (fromIntegral prepared.plan.request.seed) profile.replacementPairs) projected)

policyFor :: Prepared.PerfPrepared -> PlannedProfile -> Either Text Policy
policyFor prepared entry = do
  policies <- either (Left . Text.pack) Right (parseEither (withObject "PinnedInputs" (.: "policies")) prepared.inputs)
  document <- maybe (Left "pinned comparison policy missing") Right (Map.lookup entry.profile.policy (policies :: Map.Map FilePath Value))
  decode document

axesFor :: Prepared.PerfPrepared -> NonEmpty VaryingAxis
axesFor prepared = (if prepared.plan.request.control == "aa" then VaryControl else VaryCohort) :| []

attemptDirectory :: FilePath -> PlannedProfile -> Int -> FilePath
attemptDirectory output entry index = output </> "configurations" </> Text.unpack entry.profile.name </> "attempt-" <> show index

execute :: CliEnv -> ObjectStore -> ExecutionInputs -> Map.Map Text PayloadDescriptor -> Prepared.PerfPrepared -> FilePath -> IO ExitCode
execute environment store inputs payloads prepared output = do
  let ref identity = Lease.CellRef identity.cell (Bucket inputs.controlBucket)
      pinned identity = maybe (ioError (userError "leased cell is outside frozen pool")) pure (find ((== identity.cell) . (.name) . fst) inputs.cells)
      handle identity = Lease.reattachActiveLease store (ref identity) identity.leaseId >>= maybe (ioError (userError "performance lease is no longer active")) pure
      supports entry p = do
        planned <- makeSchedule prepared entry =<< newRunId
        let a = adapter environment store inputs payloads p
        built <- buildSession a.registry a.descriptor a.capabilities a.rules a.payloads a.options a.storeLabel planned.planId (encode planned)
        pure (either (const False) (const (prepared.plan.request.purpose == "calibration" || entry.profile.machineProfile == cellMachineProfile a.descriptor)) built)
      admission entry seconds = waitFor entry seconds
      waitFor entry left = do
        granted <- findLease entry inputs.cells
        case granted of
          Occupied | left > 1 -> threadDelay 1000000 >> waitFor entry (left - 1)
          _ -> pure granted
      findLease _ [] = pure Occupied
      findLease entry (p@(descriptor, _) : rest) = do
        compatible <- supports entry p
        if not compatible
          then findLease entry rest
          else do
            checkCell store inputs p
            granted <- Lease.acquireLease store (Lease.CellRef descriptor.name (Bucket inputs.controlBucket)) (Lease.LeaseRequest "kenshou-perf" "pinned runtime performance validation" 180)
            case granted of
              Lease.Acquired acquired -> do
                snapshot <- Lease.leaseSnapshot acquired
                pure (Admitted (LeaseIdentity descriptor.name snapshot.leaseId))
              _ -> findLease entry rest
      compareOne identity entry index _ callbacks = do
        p <- pinned identity
        acquired <- handle identity
        Lease.withHeartbeat store (ref identity) acquired \_ -> do
          when inputs.start (startCellInstances (fst p))
          let directory = attemptDirectory output entry index
              schedulePath = directory </> "schedule.json"
          exists <- doesFileExist schedulePath
          schedule <-
            if exists
              then readJSON schedulePath >>= require . decodeWorkPlan
              else do
                identifier <- newRunId
                planned <- makeSchedule prepared entry identifier
                createDirectoryIfMissing True directory
                encodeFile (schedulePath <> ".next") planned
                renameFile (schedulePath <> ".next") schedulePath
                pure planned
          policy <- require (policyFor prepared entry)
          result <- executeAttempt identity entry schedule policy (axesFor prepared) directory callbacks (executeCellTrial (adapter environment store inputs payloads p) acquired schedule directory entry.profile callbacks.recordRuntimeFailure)
          maybe (pure ()) (encodeFile (directory </> "comparison.json")) result.comparison
          encodeFile (directory </> "result.json") result
          pure result
      verify result = verifyConfiguration inputs prepared output result
      hooks =
        RunnerHooks
          getCurrentTime
          admission
          (\identity -> maybe False (const True) <$> Lease.reattachActiveLease store (ref identity) identity.leaseId)
          (\identity entry -> pinned identity >>= supports entry)
          compareOne
          verify
          ( \identity -> do
              _ <- Lease.requestCancel store (ref identity) (Just identity.leaseId) False
              pure ()
          )
          ( \identity -> do
              files <- treeFiles (output </> "configurations")
              journals <- traverse (\path -> readSessionJournal (output </> "configurations" </> path) >>= require) [path | path <- files, [_, _, "trials", _, "session.json"] <- [splitDirectories path]]
              settled <- ownedWorkSettled store (ref identity) identity journals
              unless settled do
                _ <- Lease.requestCancel store (ref identity) (Just identity.leaseId) False
                waitForOwnedWork store (ref identity) identity journals
              owned <- Lease.reattachLease store (ref identity) identity.leaseId
              maybe (pure False) (Lease.releaseLease store (ref identity)) owned
          )
          (describeReport output)
          (publishSnapshot store inputs prepared output)
  createDirectoryIfMissing True (output </> "configurations")
  auditAllAttempts True inputs prepared output
  result <- runPerformance hooks prepared (output </> "session.json")
  encodeFile (output </> "result.json") result
  TextIO.writeFile (output </> "report.md") (renderReport result)
  Lazy.putStrLn (encode result)
  pure (exit result.exitCode)

verifyConfiguration :: ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> ConfigurationResult -> IO Bool
verifyConfiguration inputs prepared output result = do
  entry <- maybe (ioError (userError "result names an unselected profile")) pure (find ((== result.profile) . (.name) . (.profile)) prepared.plan.selected)
  auditProfileAttempts False inputs prepared output entry (Just result)

auditAllAttempts :: Bool -> ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> IO ()
auditAllAttempts recover inputs prepared output = do
  names <- listDirectory (output </> "configurations")
  unless (all (`elem` map (Text.unpack . (.name) . (.profile)) prepared.plan.selected) names) (ioError (userError "retained evidence contains an unselected profile"))
  mapM_ (\entry -> auditProfileAttempts recover inputs prepared output entry Nothing >>= \valid -> unless valid (ioError (userError "retained attempt audit failed"))) prepared.plan.selected

-- Every retained attempt is checked, including abandoned and partially written
-- attempts. Only a complete matching attempt supplies the final comparison.
auditProfileAttempts :: Bool -> ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> PlannedProfile -> Maybe ConfigurationResult -> IO Bool
auditProfileAttempts recover inputs prepared output entry wanted = do
  session <- readPerfSession (output </> "session.json") >>= require
  let (_, identities) = foldl' remember (Nothing, Map.empty) session.events
      base = output </> "configurations" </> Text.unpack entry.profile.name
      remember (lease, known) event = case event.action of
        LeaseAcquired identity -> (Just identity, known)
        LeaseLost _ -> (Nothing, known)
        LeaseReleased -> (Nothing, known)
        ComparisonStarted profile index -> (lease, maybe known (\identity -> Map.insert (profile, "attempt-" <> show index) identity known) lease)
        _ -> (lease, known)
  exists <- doesDirectoryExist base
  names <- if exists then listDirectory base else pure []
  baseline <- require (decode prepared.baseline.payload)
  candidate <- require (decode prepared.candidate.payload)
  let payloads = Map.fromList [("baseline", baseline), ("candidate", candidate)]
  candidates <-
    traverse
      ( \name -> do
          identity <- maybe (ioError (userError "retained attempt has no journaled lease identity")) pure (Map.lookup (entry.profile.name, name) identities)
          let directory = base </> name
          files <- treeFiles directory
          scheduleExists <- doesFileExist (directory </> "schedule.json")
          if not scheduleExists
            then do
              unless (all (== "schedule.json.next") files) (ioError (userError "retained attempt has evidence before its paired schedule"))
              pure False
            else do
              schedule <- readJSON (directory </> "schedule.json") >>= require . decodeWorkPlan
              expected <- makeSchedule prepared entry schedule.planId
              unless (toJSON schedule == toJSON expected) (ioError (userError "retained paired schedule differs from its pinned request and seed"))
              metadataExists <- doesFileExist (directory </> "attempt.json")
              if not metadataExists
                then do
                  unless (all (`elem` ["schedule.json", "attempt.json.next"]) files) (ioError (userError "retained attempt has evidence but no immutable attempt header"))
                  pure False
                else do
                  verifyAttemptInputs identity entry schedule directory
                  pinned <- maybe (ioError (userError "attempt cell is outside frozen pool")) pure (find ((== identity.cell) . (.name) . fst) inputs.cells)
                  pathsExists <- doesFileExist (directory </> "trial-paths.json")
                  paths <- if pathsExists then readJSON (directory </> "trial-paths.json") else pure Map.empty
                  failureExists <- doesFileExist (directory </> "trial-failures.json")
                  failures <- if failureExists then readJSON (directory </> "trial-failures.json") else pure (Map.empty :: Map.Map Text Text)
                  let journalPaths = [path | path <- files, ["trials", _, "session.json"] <- [splitDirectories path]]
                      expectedPaths = ["trials" </> Text.unpack (renderRunId run.runId) </> "session.json" | run <- schedule.runs]
                  unless (all (`elem` expectedPaths) journalPaths) (ioError (userError "retained cell journal names an unplanned trial"))
                  mapM_
                    ( \run -> do
                        let identifier = renderRunId run.runId
                            trial = directory </> "trials" </> Text.unpack identifier
                            journalPath = trial </> "session.json"
                            planBytes = encode schedule {runs = [run], estimateMinutes = run.estimateMinutes}
                        journalExists <- doesFileExist journalPath
                        if not journalExists
                          then unless (Map.notMember identifier (paths :: Map.Map Text FilePath)) (ioError (userError "retained accepted trial has no cell journal"))
                          else do
                            journal <- readSessionJournal journalPath >>= require
                            unless (journal.leaseId == identity.leaseId && journal.cell == identity.cell && journal.controlBucket == inputs.controlBucket && journal.resultsBucket == (fst pinned).buckets.results && journal.payloads == payloads && journal.planSha256 == Text.drop 7 (sha256Hex (Lazy.toStrict planBytes))) (ioError (userError "retained cell journal differs from pinned payloads, trial or lease"))
                            storedPlan <- Lazy.readFile (trial </> "plan.json")
                            unless (storedPlan == planBytes) (ioError (userError "retained trial plan bytes differ"))
                            mapM_
                              ( \slice -> do
                                  work <- Lazy.readFile (trial </> slice.workPath)
                                  unless (slice.submission.leaseId == identity.leaseId && slice.submission.runId == slice.cellRun && slice.runIds == [run.runId] && slice.submission.work.sha256 == Text.drop 7 (sha256Hex (Lazy.toStrict work)) && slice.submission.work.bytes == Lazy.length work) (ioError (userError "retained submission work or identity differs"))
                              )
                              journal.slices
                            verified <- verifyCellTrial (fst pinned) run trial journal
                            runtimeProblems <- retainedRuntimeProblems entry.profile run trial journal
                            mapM_
                              ( \reason -> do
                                  current <- readPerfSession (output </> "session.json") >>= require
                                  state <- require (journalState current)
                                  unless (reason `elem` Map.findWithDefault [] entry.profile.name state.runtimeBlockers) do
                                    unless recover (ioError (userError "sealed runtime blocker is missing from the session"))
                                    now <- getCurrentTime
                                    changed <- require (appendEvent (SessionEvent now (RuntimeBlocked entry.profile.name reason)) current)
                                    writePerfSession (output </> "session.json") changed
                              )
                              runtimeProblems
                            case Map.lookup identifier paths of
                              Just path -> unless (verified == Right (directory </> path)) (ioError (userError "retained accepted trial outer evidence differs"))
                              Nothing -> when (Map.member identifier failures && either (const False) (const True) verified) (ioError (userError "retained failed trial has healthy completed outer evidence"))
                    )
                    schedule.runs
                  present <- doesFileExist (directory </> "result.json")
                  if not present
                    then pure False
                    else do
                      record <- readJSON (directory </> "result.json")
                      policy <- require (policyFor prepared entry)
                      replayed <- verifyAttempt entry schedule policy (axesFor prepared) directory record
                      unless replayed (ioError (userError "retained attempt result replay differs"))
                      comparisonExists <- doesFileExist (directory </> "comparison.json")
                      comparison <- if comparisonExists then Just <$> readJSON (directory </> "comparison.json") else pure Nothing
                      unless (comparison == record.comparison) (ioError (userError "retained ordinary comparison differs from attempt result"))
                      pure (maybe False (\result -> record.comparison == result.comparison && record.validPairs == result.validPairs && record.attempts == result.attempts && all (`elem` result.runtimeFailures) record.runtimeFailures) wanted)
      )
      names
  pure (maybe True (\result -> or candidates || (result.comparison == Nothing && result.validPairs == 0 && result.infrastructureState == "pending" && result.performanceVerdict == "inconclusive")) wanted)

describeReport :: FilePath -> PerfSession -> PerfResult -> IO PerfResult
describeReport output session result = do
  identifier <- newRunId
  now <- getCurrentTime
  let summaryPath = output </> "preparation/preparation-summary.json"
  summaryExists <- doesFileExist summaryPath
  preparationTimes <- if summaryExists then readJSON summaryPath >>= either (ioError . userError) pure . parseEither (withObject "PreparationSummary" (.: "stageSeconds")) else pure Map.empty
  let base = session.evidenceBaseUri <> "/sessions/" <> renderRunId session.sessionId <> "/snapshots/" <> renderRunId identifier
      leaseTimes = [event.at | event <- session.events, LeaseAcquired _ <- [event.action]]
      elapsed from to = realToFrac (diffUTCTime to from) :: Double
      timings =
        Map.fromList
          ( [("totalAtReportAssembly", elapsed session.createdAt now)] <> case leaseTimes of
              [] -> [("initialAdmission", elapsed session.createdAt now), ("measurementAndCleanupToAssembly", 0)]
              first : _ -> [("initialAdmission", elapsed session.createdAt first), ("measurementAndCleanupToAssembly", elapsed first now)]
          )
  files <- treeFiles (output </> "configurations")
  let relativeFiles = ["prepared.json", "request.json", "plan.json", "session.json"] <> ["configurations/" <> path | path <- files, "comparison.json" `isSuffixOf` path || "manifest.json" `isSuffixOf` path]
  references <-
    traverse
      ( \path -> do
          (digest, _) <- digestFile (output </> path)
          pure (ArtifactReference (if "manifest.json" `isSuffixOf` path then "cell-or-runtime-manifest" else if "comparison.json" `isSuffixOf` path then "comparison" else Text.pack path) (base <> "/" <> Text.pack path) (Just ("sha256:" <> digest)))
      )
      relativeFiles
  pure result {stageSeconds = timings <> Map.mapKeys ("preparation." <>) preparationTimes, artifactReferences = ArtifactReference "aggregate-manifest" (base <> "/manifest.json") Nothing : ArtifactReference "publication-receipt" (base <> "/receipt.json") Nothing : references}

treeFiles :: FilePath -> IO [FilePath]
treeFiles root = do
  names <- listDirectory root
  fmap
    concat
    ( traverse
        ( \name -> do
            let path = root </> name
            linked <- pathIsSymbolicLink path
            when linked (ioError (userError "performance evidence contains a symbolic link"))
            directory <- doesDirectoryExist path
            if directory then map (name </>) <$> treeFiles path else pure [name]
        )
        names
    )

publishSnapshot :: ObjectStore -> ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> PerfSession -> PerfResult -> IO Bool
publishSnapshot store _ _ output session result = do
  publicationStarted <- getCurrentTime
  manifestReference <- case filter ((== "aggregate-manifest") . (.kind)) result.artifactReferences of
    [reference] -> pure reference.uri
    _ -> ioError (userError "report has no unique aggregate manifest reference")
  relative <- maybe (ioError (userError "aggregate reference is outside its pinned session")) pure (Text.stripPrefix (session.evidenceBaseUri <> "/sessions/" <> renderRunId session.sessionId <> "/") manifestReference >>= Text.stripSuffix "/manifest.json")
  let directory = output </> Text.unpack relative
  createDirectoryIfMissing True directory
  mapM_ (\name -> copyTree (output </> name) (directory </> name)) ["preparation", "configurations"]
  mapM_ (\name -> copyFile (output </> name) (directory </> name)) ["prepared.json", "request.json", "plan.json", "session.json"]
  encodeFile (directory </> "result.json") result
  TextIO.writeFile (directory </> "report.md") (renderReport result)
  sealPerfDirectory directory >>= require
  (bucket, prefix) <- require (parseDestination session.evidenceBaseUri)
  published <- publishEvidence store bucket (prefix <> "/sessions/" <> renderRunId session.sessionId <> "/" <> relative) directory
  case published of
    Left problem -> TextIO.hPutStrLn stderr problem >> pure False
    Right uri -> do
      manifest <- Bytes.readFile (directory </> "manifest.json")
      verified <- getCurrentTime
      state <- require (journalState session)
      unless (maybe True (verified <=) state.executionDeadline) (ioError (userError "publication verification exceeded the original execution deadline"))
      let receipt = PublicationReceipt relative uri (sha256Hex manifest) (sha256Hex (canonicalEncode (toJSON result))) session.createdAt publicationStarted verified (realToFrac (diffUTCTime verified session.createdAt))
          bytes = encode receipt
          name = ObjectName (prefix <> "/sessions/" <> renderRunId session.sessionId <> "/" <> relative <> "/receipt.json")
      _ <- store.putObject bucket name "application/json" DoesNotExist bytes
      retained <- store.getObject bucket name
      unless (fmap fst retained == Just bytes) (ioError (userError "durable publication receipt retrieval differs"))
      receiptRetrievedAt <- getCurrentTime
      unless (maybe True (receiptRetrievedAt <=) state.executionDeadline) (ioError (userError "receipt retrieval exceeded the original execution deadline"))
      Lazy.writeFile (output </> "receipt.json") bytes
      pure True

runCalibrationPublish :: Bool -> FilePath -> Text -> CliEnv -> IO ExitCode
runCalibrationPublish definition path uri _ = guarded do
  bytes <- Lazy.readFile path
  (bucket, name) <- input (parseDestination uri)
  now <- getCurrentTime
  if definition
    then do
      document <- either (throwIO . SessionFailure 2 . Text.pack) pure (eitherDecode bytes :: Either String Calibration.CalibrationDefinition)
      input (Calibration.validateCalibrationDefinition now now document)
    else do
      document <- either (throwIO . SessionFailure 2 . Text.pack) pure (eitherDecode bytes :: Either String Calibration.CalibrationAcceptance)
      unless (length document.aa == 20 && length document.slowdown == 20 && all (not . null . (.receipts)) (document.aa <> document.slowdown)) (throwIO (SessionFailure 2 "acceptance inventory needs both twenty-slot experiments"))
  (store, _) <- openStore bucket
  _ <- store.putObject bucket (ObjectName name) "application/json" DoesNotExist bytes
  retained <- store.getObject bucket (ObjectName name)
  (retrieved, metadata) <- maybe (ioError (userError "calibration publication retrieval failed")) pure retained
  unless (retrieved == bytes) (ioError (userError "create-only calibration publication differs"))
  Lazy.putStrLn (encode (object ["uri" .= uri, "sha256" .= sha256Hex (Lazy.toStrict bytes), "declaredAt" .= metadata.updated]))
  pure ExitSuccess

runCalibrationVerify :: FilePath -> FilePath -> CliEnv -> IO ExitCode
runCalibrationVerify referencePath preparedPath _ = guarded do
  prepared <- loadPreparation preparedPath
  reference <- readJSON referencePath :: IO Calibration.CalibrationReference
  entry <- case prepared.plan.selected of [selected] -> pure selected; _ -> throwIO (SessionFailure 2 "calibration verification needs one prepared profile")
  (semantics, policies) <- require (either (Left . Text.pack) Right (parseEither (withObject "PinnedInputs" \v -> (,) <$> v .: "harnessSemanticsSha256" <*> v .: "policies") prepared.inputs))
  policy <- maybe (ioError (userError "missing pinned calibration policy")) pure (Map.lookup entry.profile.policy (policies :: Map.Map FilePath Value))
  digest <- verifyCalibrationAdmission entry {PerfPlan.profile = entry.profile {calibration = Just (toJSON reference)}} (Calibration.toolchainDigest prepared.baseline.buildInventory) semantics policy >>= require
  Lazy.putStrLn (encode (object ["verified" .= True, "profile" .= entry.profile.name, "acceptanceSha256" .= digest, "gatingEligible" .= False]))
  pure ExitSuccess

verifyCalibrationAdmission :: PlannedProfile -> Text -> Text -> Value -> IO (Either Text Text)
verifyCalibrationAdmission entry expectedToolchain semantics policyValue = do
  outcome <- try @IOException do
    reference <- require (either (Left . Text.pack) Right (parseEither (parseJSON @Calibration.CalibrationReference) (fromMaybe Null entry.profile.calibration)))
    (definitionBytes, declared) <- readPinned reference.definitionUri reference.definitionSha256
    (acceptanceBytes, _) <- readPinned reference.acceptanceUri reference.acceptanceSha256
    definition <- either (ioError . userError) pure (eitherDecode definitionBytes :: Either String Calibration.CalibrationDefinition)
    acceptance <- either (ioError . userError) pure (eitherDecode acceptanceBytes :: Either String Calibration.CalibrationAcceptance)
    unless ((definition.profile, definition.machineProfile, definition.workloadSha256, definition.toolchainSha256, definition.harnessSemanticsSha256) == (entry.profile.name, entry.profile.machineProfile, entry.workloadSha256, expectedToolchain, semantics)) (ioError (userError "calibration definition differs from the current workload, toolchain or harness"))
    unless (not ("pending" `Text.isInfixOf` entry.profile.machineProfile)) (ioError (userError "calibration requires an actual designated machine profile"))
    policy <- require (either (Left . Text.pack) Right (parseEither parseJSON policyValue))
    rule <- case filter (\rule -> matchesRule rule.match definition.targetMetric) (policy :: Policy).metricRules of
      [metricRule] -> pure metricRule
      _ -> ioError (userError "injected metric needs one unambiguous policy rule")
    unless (definition.targetMetric `elem` map (.name) entry.profile.requiredMetrics && rule.direction == LowerIsBetter && definition.targetRelativeEffect > rule.relativeLimit && definition.targetAbsoluteEffect > rule.absoluteFloor) (ioError (userError "injected latency effect must exceed both frozen policy thresholds"))
    aa <- traverse (traverse replayCalibrationReceipt . (.receipts)) acceptance.aa
    slowdown <- traverse (traverse replayCalibrationReceipt . (.receipts)) acceptance.slowdown
    now <- getCurrentTime
    _ <- require (Calibration.validateCalibration now declared definition acceptance aa slowdown)
    pure reference.acceptanceSha256
  pure (either (Left . Text.pack . displayException) Right outcome)
  where
    readPinned uri digest = do
      (bucket, name) <- require (parseDestination uri)
      (store, _) <- openStore bucket
      retained <- store.getObject bucket (ObjectName name)
      (bytes, metadata) <- maybe (ioError (userError "calibration record is missing")) pure retained
      unless (sha256Hex (Lazy.toStrict bytes) == digest) (ioError (userError "calibration record digest differs"))
      pure (bytes, metadata.updated)

verifyGatingCalibration :: Prepared.PerfPrepared -> IO ()
verifyGatingCalibration prepared = when prepared.plan.gatingEligible do
  (semantics, policies, admissions) <- require (either (Left . Text.pack) Right (parseEither (withObject "PinnedInputs" \v -> (,,) <$> v .: "harnessSemanticsSha256" <*> v .: "policies" <*> v .: "calibrationAdmissions") prepared.inputs))
  mapM_
    ( \entry -> do
        policy <- maybe (ioError (userError "pinned calibration policy is absent")) pure (Map.lookup entry.profile.policy (policies :: Map.Map FilePath Value))
        evidence <- verifyCalibrationAdmission entry (Calibration.toolchainDigest prepared.baseline.buildInventory) semantics policy >>= require
        unless (Map.lookup entry.workloadSha256 (admissions :: Map.Map Text Text) == Just evidence) (ioError (userError "pinned calibration admission differs"))
    )
    prepared.plan.selected

replayCalibrationReceipt :: Calibration.CalibrationReceipt -> IO Calibration.VerifiedCalibrationTrial
replayCalibrationReceipt reference = do
  (bucket, objectName) <- require (parseDestination reference.uri)
  prefix <- maybe (ioError (userError "calibration must reference a publication receipt")) pure (Text.stripSuffix "/receipt.json" objectName)
  (store, _) <- openStore bucket
  retained <- store.getObject bucket (ObjectName objectName)
  bytes <- maybe (ioError (userError "calibration receipt is missing")) (pure . fst) retained
  unless (sha256Hex (Lazy.toStrict bytes) == reference.sha256) (ioError (userError "calibration receipt digest differs"))
  receipt <- either (ioError . userError) pure (eitherDecode bytes :: Either String PublicationReceipt)
  unless (receipt.manifestUri == "gs://" <> bucket.unBucket <> "/" <> prefix <> "/manifest.json") (ioError (userError "calibration receipt destination differs"))
  unless ("snapshots/" `Text.isPrefixOf` receipt.snapshot && Text.count "/" receipt.snapshot == 1 && Text.all (\c -> c `elem` (['a' .. 'z'] <> ['0' .. '9'] <> ['-', '/'])) receipt.snapshot) (ioError (userError "unsafe calibration snapshot"))
  withSystemTempDirectory "kenshou-calibration-replay-" \root -> do
    let directory = root </> Text.unpack receipt.snapshot
    retrieveEvidence store bucket prefix receipt.manifestSha256 directory >>= require
    Lazy.writeFile (root </> "receipt.json") bytes
    (result, _) <- verifySessionEvidence root True
    prepared <- loadPreparation (directory </> "preparation/prepared.json")
    session <- readPerfSession (directory </> "session.json") >>= require
    unless (result.purpose == "calibration" && not result.gatingEligible && length result.configurations == 1 && length prepared.plan.selected == 1) (ioError (userError "calibration needs a single-profile non-gating report"))
    configuration <- case result.configurations of [retainedConfiguration] -> pure retainedConfiguration; _ -> ioError (userError "missing calibration configuration")
    semantics <- require (either (Left . Text.pack) Right (parseEither (withObject "PinnedInputs" (.: "harnessSemanticsSha256")) prepared.inputs))
    inputs <- require (parseInputs session)
    entry <- case prepared.plan.selected of [selected] -> pure selected; _ -> ioError (userError "missing calibration profile")
    let leasedCells = [identity.cell | event <- session.events, LeaseAcquired identity <- [event.action]]
    actualProfiles <-
      traverse
        (\cell -> maybe (ioError (userError "calibration lease is outside the frozen pool")) (pure . cellMachineProfile . fst) (find ((== cell) . (.name) . fst) inputs.cells))
        leasedCells
    unless (all (== entry.profile.machineProfile) actualProfiles && (result.infrastructureState /= "healthy" || not (null actualProfiles))) (ioError (userError "calibration ran on a different machine or image profile"))
    pure (Calibration.VerifiedCalibrationTrial session.sessionId prepared.plan.request.seed prepared.plan.request.control prepared.plan.request.project prepared.plan.request.baselineRevision prepared.plan.request.candidateRevision configuration.profile entry.profile.machineProfile configuration.workloadSha256 (Calibration.toolchainDigest prepared.baseline.buildInventory) semantics configuration.performanceVerdict result.infrastructureState result.blockingRuntimeFailures session.createdAt receipt.totalElapsedSeconds)

runVerify :: FilePath -> Bool -> CliEnv -> IO ExitCode
runVerify output offline _ = guarded do
  (result, uri) <- verifySessionEvidence output offline
  Lazy.putStrLn (encode (object ["verified" .= True, "offline" .= offline, "manifestUri" .= uri, "result" .= result]))
  pure (exit result.exitCode)

verifySessionEvidence :: FilePath -> Bool -> IO (PerfResult, Text)
verifySessionEvidence output offline = do
  receipt <- readJSON (output </> "receipt.json")
  let relative = (receipt :: PublicationReceipt).snapshot
      uri = receipt.manifestUri
      manifestDigest = receipt.manifestSha256
      resultDigest = receipt.resultSha256
  unless ("snapshots/" `Text.isPrefixOf` relative && Text.all (\c -> c `elem` (['a' .. 'z'] <> ['0' .. '9'] <> ['-', '/'])) relative && Text.count "/" relative == 1) (ioError (userError "unsafe retained snapshot"))
  let directory = output </> Text.unpack relative
  verifyPerfManifest directory >>= require
  manifest <- Bytes.readFile (directory </> "manifest.json")
  unless (sha256Hex manifest == manifestDigest) (ioError (userError "retained manifest differs from durable receipt"))
  prepared <- loadPreparation (directory </> "preparation/prepared.json")
  checkRootInputs directory prepared
  session <- readPerfSession (directory </> "session.json") >>= require
  require (validateSessionInputs prepared session)
  unless offline (verifyGatingCalibration prepared)
  unless (receipt.payloadsReadyAt == session.createdAt) (ioError (userError "receipt timing origin differs from its pinned session"))
  unless (uri == session.evidenceBaseUri <> "/sessions/" <> renderRunId session.sessionId <> "/" <> relative <> "/manifest.json") (ioError (userError "receipt destination differs from its pinned session"))
  inputs <- require (parseInputs session)
  result <- readJSON (directory </> "result.json")
  unless (sha256Hex (canonicalEncode (toJSON (result :: PerfResult))) == resultDigest) (ioError (userError "retained aggregate differs from durable receipt"))
  unless (maybe False (<= receipt.totalElapsedSeconds) (Map.lookup "totalAtReportAssembly" result.stageSeconds)) (ioError (userError "report timing exceeds its verified publication time"))
  let base = Text.dropEnd (Text.length ("/manifest.json" :: Text)) uri
  unless ([reference.uri | reference <- result.artifactReferences, reference.kind == "aggregate-manifest"] == [uri] && [reference.uri | reference <- result.artifactReferences, reference.kind == "publication-receipt"] == [base <> "/receipt.json"]) (ioError (userError "report does not reference its own publication and receipt"))
  mapM_
    ( \reference -> case reference.sha256 of
        Nothing -> unless (reference.kind `elem` ["aggregate-manifest", "publication-receipt"]) (ioError (userError "artifact reference has no digest"))
        Just expected -> do
          path <- maybe (ioError (userError "artifact reference is outside the sealed snapshot")) pure (Text.stripPrefix (base <> "/") reference.uri)
          unless (all (\part -> not (Text.null part) && part `notElem` [".", ".."]) (Text.splitOn "/" path) && not (Text.any (`elem` ['\\', '\n', '\r']) path)) (ioError (userError "unsafe artifact reference"))
          (actual, _) <- digestFile (directory </> Text.unpack path)
          unless (expected == "sha256:" <> actual) (ioError (userError "artifact reference digest differs"))
    )
    result.artifactReferences
  state <- require (journalState session)
  auditAllAttempts False inputs prepared directory
  unless (maybe True (receipt.verifiedReportAt <=) state.executionDeadline) (ioError (userError "publication receipt exceeds the original execution deadline"))
  let completed = Map.elems state.completed
  valid <- traverse (verifyConfiguration inputs prepared directory) completed
  unless (and valid) (ioError (userError "retained comparison replay differs"))
  recomputed <- require (aggregateResult session.plan session.preparedSha256 result.evidenceVerified result.configurations)
  unless (recomputed == result {stageSeconds = Map.empty, artifactReferences = []} && all (\entry -> any (\retained -> retained.profile == entry.profile && retained.comparison == entry.comparison && retained.runtimeFailures == entry.runtimeFailures) result.configurations) completed) (ioError (userError "aggregate differs from the pinned session results"))
  unless offline do
    destination <- maybe (ioError (userError "receipt has no manifest URI")) pure (Text.stripSuffix "/manifest.json" uri)
    (bucket, prefix) <- require (parseDestination destination)
    (store, _) <- openStore bucket
    verifyPublication store bucket prefix directory >>= require
    stored <- store.getObject bucket (ObjectName (prefix <> "/receipt.json"))
    bytes <- Lazy.readFile (output </> "receipt.json")
    unless (fmap fst stored == Just bytes) (ioError (userError "retained publication receipt differs from durable storage"))
  pure (result, uri)

accessProbe :: ObjectStore -> Text -> RunId -> Prepared.PerfPrepared -> IO ()
accessProbe store uri identifier prepared = do
  (bucket, prefix) <- require (parseDestination uri)
  let name = ObjectName (prefix <> "/access-checks/" <> renderRunId identifier <> ".json")
      bytes = encode (object ["session" .= identifier, "preparedSha256" .= Prepared.preparedDigest prepared])
  outcome <- store.putObject bucket name "application/json" DoesNotExist bytes
  unless (case outcome of Written _ -> True; _ -> False) (ioError (userError "performance evidence destination failed create-only access check"))
  found <- store.getObject bucket name
  unless (fmap fst found == Just bytes) (ioError (userError "performance evidence destination failed retrieval access check"))

parseDestination :: Text -> Either Text (Bucket, Text)
parseDestination uri = do
  suffix <- maybe (Left "evidence destination must be gs://BUCKET/PREFIX") Right (Text.stripPrefix "gs://" uri)
  let (bucket, path) = Text.breakOn "/" suffix
      prefix = Text.drop 1 path
  unless (not (Text.null bucket) && Text.all (\c -> c `elem` ['a' .. 'z'] <> ['0' .. '9'] <> ['-', '.']) bucket && not (Text.null prefix) && all (\part -> not (Text.null part) && part `notElem` [".", ".."]) (Text.splitOn "/" prefix) && not (Text.any (`elem` ['\\', '\n', '\r', ' ', '?', '#']) prefix)) (Left "unsafe evidence destination")
  pure (Bucket bucket, prefix)

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  link <- pathIsSymbolicLink source
  when link (ioError (userError "performance artifacts may not contain symbolic links"))
  directory <- doesDirectoryExist source
  if directory
    then do
      createDirectoryIfMissing True destination
      names <- listDirectory source
      mapM_ (\name -> copyTree (source </> name) (destination </> name)) names
    else copyFile source destination

renderReport :: PerfResult -> Text
renderReport result =
  Text.unlines
    ( ["# Runtime performance validation", "", "Performance: " <> result.performanceVerdict, "Coverage: " <> result.coverage <> " (whole change: " <> result.changeCoverage <> ")", "Infrastructure: " <> result.infrastructureState, "Purpose: " <> result.purpose, "Gating eligible: " <> Text.pack (show result.gatingEligible), "Exit: " <> Text.pack (show result.exitCode), "", "| Profile | Verdict | Valid pairs | Infrastructure |", "| --- | --- | --- | --- |"]
        <> ["| " <> item.profile <> " | " <> item.performanceVerdict <> " | " <> Text.pack (show item.validPairs) <> "/" <> Text.pack (show item.requiredPairs) <> " | " <> item.infrastructureState <> " |" | item <- result.configurations]
        <> concatMap effects result.configurations
        <> ["", "Runtime blockers: " <> if null result.blockingRuntimeFailures then "none" else Text.intercalate "; " result.blockingRuntimeFailures]
        <> ["", "## Scope", ""]
        <> ["- Excluded " <> scenario <> ": " <> reason | (scenario, reason) <- result.exclusions]
        <> ["- Uncovered: " <> scenario | scenario <- result.uncoveredScenarios]
        <> ["", "## Timings", "", "| Stage | Seconds |", "| --- | ---: |"]
        <> ["| " <> stage <> " | " <> number seconds <> " |" | (stage, seconds) <- Map.toAscList result.stageSeconds]
        <> ["", "Full report retrieval time is recorded in the linked publication receipt.", "", "## Evidence", ""]
        <> ["- [" <> reference.kind <> "](" <> reference.uri <> ")" <> maybe "" (\digest -> " (`" <> digest <> "`)") reference.sha256 | reference <- result.artifactReferences]
    )
  where
    number amount = Text.pack (printf "%.4g" (amount :: Double))
    effects configuration = case configuration.comparison of
      Nothing -> []
      Just document -> case parseEither metrics document of
        Left problem -> ["", "Retained metric report could not be rendered: " <> Text.pack problem]
        Right rows -> ["", "## " <> configuration.profile, "", "Intervals and thresholds below are retained comparison results.", "", "| Metric | Unit | Ratio estimate [low, high] | Delta estimate [low, high] | Relative limit | Absolute floor | Status |", "| --- | --- | --- | --- | ---: | ---: | --- |"] <> rows
    metrics = withObject "Comparison" \document -> do
      values <- document .: "metrics"
      traverse metric (Map.toAscList (values :: Map.Map Text Value))
    metric (name, document) =
      withObject
        "MetricComparison"
        ( \fields -> do
            unit <- fields .: "unit"
            ratio <- fields .: "ratio" >>= interval
            delta <- fields .: "delta" >>= interval
            limit <- fields .: "relativeLimit"
            floorValue <- fields .: "absoluteFloor"
            status <- fields .: "status"
            pure ("| " <> name <> " | " <> unit <> " | " <> ratio <> " | " <> delta <> " | " <> number limit <> " | " <> number floorValue <> " | " <> status <> " |")
        )
        document
    interval = withObject "Interval" \fields -> do
      low <- fields .: "low"
      estimate <- fields .: "estimate"
      high <- fields .: "high"
      pure (number estimate <> " [" <> number low <> ", " <> number high <> "]")

openStore :: Bucket -> IO (ObjectStore, Text)
openStore bucket = do
  selected <- lookupEnv "KENSHOU_CELL_STORE"
  case selected of
    Just setting -> do
      path <- maybe (ioError (userError "KENSHOU_CELL_STORE must be file:<dir> or unset for GCS")) (pure . Text.unpack) (Text.stripPrefix "file:" (Text.pack setting))
      when (null path) (ioError (userError "file-backed cell store directory is empty"))
      absolute <- makeAbsolute path
      store <- newFileStore absolute
      pure (store, "file:" <> Text.pack absolute)
    Nothing -> do
      tokens <- newTokenProvider bucket
      store <- newGcsStore tokens
      pure (store, "gcs")

readJSON :: (FromJSON a) => FilePath -> IO a
readJSON path = eitherDecodeFileStrict' path >>= either (ioError . userError . ((path <> ": ") <>)) pure

decode :: (FromJSON a) => Value -> Either Text a
decode document = case fromJSON document of Error problem -> Left (Text.pack problem); Success result -> Right result

require :: Either Text a -> IO a
require = either (ioError . userError . Text.unpack) pure

input :: Either Text a -> IO a
input = either (throwIO . SessionFailure 2) pure

exit :: Int -> ExitCode
exit 0 = ExitSuccess
exit code = ExitFailure code

guarded :: IO ExitCode -> IO ExitCode
guarded action = catch executeFailure (\(SessionFailure code problem) -> TextIO.hPutStrLn stderr problem >> pure (exit code))
  where
    executeFailure = do
      result <- try @IOException action
      case result of
        Right code -> pure code
        Left problem -> do
          TextIO.hPutStrLn stderr (Text.pack (displayException problem))
          pure (ExitFailure 4)
