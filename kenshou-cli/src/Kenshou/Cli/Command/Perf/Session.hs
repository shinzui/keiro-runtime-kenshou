module Kenshou.Cli.Command.Perf.Session (sessionCommands) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, IOException, catch, displayException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson hiding (decode)
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kenshou.Cli.Command.Cell (startCellInstances)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cli (CliEnv (..))
import Kenshou.Core.Id
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Measure.Compare.Compatibility (VaryingAxis (..))
import Kenshou.Measure.Compare.Ordering (PairedOrdering (ABBA))
import Kenshou.Measure.Compare.Policy (Policy)
import Kenshou.Perf.Artifacts
import Kenshou.Perf.Plan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Request (PerfRequest (..), strictObject)
import Kenshou.Perf.Result
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Control
import Kenshou.Remote.Cell.Docs (CachePolicy (Cold), CellBuckets (..), CellDescriptor (..))
import Kenshou.Remote.Cell.Lease qualified as Lease
import Kenshou.Remote.Cell.Prepare
import Kenshou.Remote.Cell.RouteRules
import Kenshou.Remote.Cell.Session.Build (BuildOptions (..), buildSession)
import Kenshou.Remote.Cell.Session.Journal (readSessionJournal)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Pair
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Publish (digestFile)
import Kenshou.Remote.Perf.Attempt
import Kenshou.Remote.Perf.Cell
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
import System.FilePath (takeDirectory, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

data SessionFailure = SessionFailure Int Text deriving stock (Show)

instance Exception SessionFailure

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
  where
    session = strOption (long "session" <> metavar "DIRECTORY")
    runParser = runNew <$> strOption (long "prepared" <> metavar "FILE") <*> strOption (long "evidence-base-uri" <> metavar "GS_URI") <*> strOption (long "out" <> metavar "DIRECTORY") <*> strOption (long "control-bucket" <> value "tan-nb-exp-cells-control" <> showDefault) <*> switch (long "start" <> help "Start stopped instances after acquiring their cell lease")
    statusParser = runStatus <$> session
    resumeParser = runResume <$> session
    verifyParser = runVerify <$> session <*> switch (long "offline" <> help "Verify the retained sealed snapshot and receipt without contacting storage")

runNew :: FilePath -> Text -> FilePath -> Text -> Bool -> CliEnv -> IO ExitCode
runNew preparedPath uri destination bucket start environment = guarded do
  prepared <- eitherDecodeFileStrict' preparedPath >>= either (throwIO . SessionFailure 2 . Text.pack) pure
  input (Prepared.validatePrepared prepared)
  _ <- input (parseDestination uri)
  input (initialSessionPlaceholder prepared uri)
  verifyPerfManifest (takeDirectory preparedPath) >>= require
  exists <- doesPathExist destination
  when exists (throwIO (SessionFailure 2 "performance output already exists"))
  output <- makeAbsolute destination
  (store, label) <- openStore (Bucket bucket)
  projects <- maybe ["tan-nb-exp"] (map Text.strip . Text.splitOn "," . Text.pack) <$> lookupEnv "KENSHOU_GCP_ALLOWED_PROJECTS"
  capabilityDirectory <- fromMaybe ".dev/cells" <$> lookupEnv "KENSHOU_CELL_CAPABILITIES_DIR"
  pinned <- traverse (loadCell store projects capabilityDirectory bucket) prepared.plan.request.cells
  let inputs = ExecutionInputs bucket label projects start pinned
  payloads <- loadPayloads store prepared
  identifier <- newRunId
  preflight environment store inputs payloads prepared identifier
  -- The create-only probe is retained as evidence of the actual destination
  -- permissions. It needs object creation and retrieval, never deletion.
  accessProbe store uri identifier prepared
  now <- getCurrentTime
  session <- require (initialSession identifier (Prepared.preparedDigest prepared) prepared.plan uri now)
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
    inputs <- require (parseInputs session)
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
      handle identity = Lease.reattachLease store (ref identity) identity.leaseId >>= maybe (ioError (userError "performance lease is no longer owned")) pure
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
              encodeFile schedulePath planned
              pure planned
        policy <- require (policyFor prepared entry)
        result <- executeAttempt identity entry schedule policy (axesFor prepared) directory callbacks (executeCellTrial (adapter environment store inputs payloads p) acquired schedule directory)
        maybe (pure ()) (encodeFile (directory </> "comparison.json")) result.comparison
        encodeFile (directory </> "result.json") result
        pure result
      verify result = verifyConfiguration inputs prepared output result
      hooks =
        RunnerHooks
          getCurrentTime
          admission
          (\identity -> maybe False (const True) <$> Lease.reattachLease store (ref identity) identity.leaseId)
          (\identity entry -> pinned identity >>= supports entry)
          compareOne
          verify
          ( \identity -> do
              _ <- Lease.requestCancel store (ref identity) (Just identity.leaseId) False
              pure ()
          )
          ( \identity -> do
              owned <- Lease.reattachLease store (ref identity) identity.leaseId
              maybe (pure False) (Lease.releaseLease store (ref identity)) owned
          )
          (publishSnapshot store inputs prepared output)
  createDirectoryIfMissing True (output </> "configurations")
  result <- runPerformance hooks prepared (output </> "session.json")
  encodeFile (output </> "result.json") result
  TextIO.writeFile (output </> "report.md") (renderReport result)
  Lazy.putStrLn (encode result)
  pure (exit result.exitCode)

verifyConfiguration :: ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> ConfigurationResult -> IO Bool
verifyConfiguration inputs prepared output result = do
  entry <- maybe (ioError (userError "result names an unselected profile")) pure (find ((== result.profile) . (.name) . (.profile)) prepared.plan.selected)
  let base = output </> "configurations" </> Text.unpack result.profile
  attempts <- listDirectory base
  candidates <-
    traverse
      ( \name -> do
          let directory = base </> name
          present <- doesFileExist (directory </> "result.json")
          recorded <- if present then Just <$> readJSON (directory </> "result.json") else pure Nothing
          if maybe True (\record -> record.comparison /= result.comparison || record.validPairs /= result.validPairs) (recorded :: Maybe ConfigurationResult)
            then pure False
            else do
              schedule <- readJSON (directory </> "schedule.json") >>= require . decodeWorkPlan
              metadata <- readJSON (directory </> "attempt.json")
              identity <- either (ioError . userError) pure (parseEither (withObject "Attempt" (.: "lease")) metadata :: Either String LeaseIdentity)
              pinned <- maybe (ioError (userError "attempt cell is outside frozen pool")) pure (find ((== identity.cell) . (.name) . fst) inputs.cells)
              paths <- readJSON (directory </> "trial-paths.json") :: IO (Map.Map Text FilePath)
              outer <-
                traverse
                  ( \run ->
                      if Map.member (renderRunId run.runId) paths
                        then do
                          let trial = directory </> "trials" </> Text.unpack (renderRunId run.runId)
                          journal <- readSessionJournal (trial </> "session.json") >>= require
                          verified <- verifyCellTrial (fst pinned) run trial journal
                          pure (verified == Right (directory </> (paths Map.! renderRunId run.runId)))
                        else pure True
                  )
                  schedule.runs
              policy <- require (policyFor prepared entry)
              replayed <- verifyAttempt entry schedule policy (axesFor prepared) directory result
              pure (and outer && replayed)
      )
      [name | name <- attempts, "attempt-" `Text.isPrefixOf` Text.pack name]
  pure (or candidates)

publishSnapshot :: ObjectStore -> ExecutionInputs -> Prepared.PerfPrepared -> FilePath -> PerfSession -> PerfResult -> IO Bool
publishSnapshot store _ _ output session result = do
  identifier <- newRunId
  let relative = "snapshots/" <> Text.unpack (renderRunId identifier)
      directory = output </> relative
  createDirectoryIfMissing True directory
  mapM_ (\name -> copyTree (output </> name) (directory </> name)) ["preparation", "configurations"]
  mapM_ (\name -> copyFile (output </> name) (directory </> name)) ["prepared.json", "request.json", "plan.json", "session.json"]
  encodeFile (directory </> "result.json") result
  TextIO.writeFile (directory </> "report.md") (renderReport result)
  sealPerfDirectory directory >>= require
  (bucket, prefix) <- require (parseDestination session.evidenceBaseUri)
  published <- publishEvidence store bucket (prefix <> "/sessions/" <> renderRunId session.sessionId <> "/" <> Text.pack relative) directory
  case published of
    Left problem -> TextIO.hPutStrLn stderr problem >> pure False
    Right uri -> do
      manifest <- Bytes.readFile (directory </> "manifest.json")
      encodeFile (output </> "receipt.json") (object ["snapshot" .= relative, "manifestUri" .= uri, "manifestSha256" .= sha256Hex manifest, "resultSha256" .= sha256Hex (canonicalEncode (toJSON result))])
      pure True

runVerify :: FilePath -> Bool -> CliEnv -> IO ExitCode
runVerify output offline _ = guarded do
  receipt <- readJSON (output </> "receipt.json")
  (relative, uri, manifestDigest, resultDigest) <-
    either
      (ioError . userError)
      pure
      ( parseEither
          ( withObject "PerformanceReceipt" \v -> do
              strictObject ["snapshot", "manifestUri", "manifestSha256", "resultSha256"] v
              (,,,) <$> v .: "snapshot" <*> v .: "manifestUri" <*> v .: "manifestSha256" <*> v .: "resultSha256"
          )
          receipt
      )
  unless ("snapshots/" `Text.isPrefixOf` relative && Text.all (\c -> c `elem` (['a' .. 'z'] <> ['0' .. '9'] <> ['-', '/'])) relative && Text.count "/" relative == 1) (ioError (userError "unsafe retained snapshot"))
  let directory = output </> Text.unpack relative
  verifyPerfManifest directory >>= require
  manifest <- Bytes.readFile (directory </> "manifest.json")
  unless (sha256Hex manifest == manifestDigest) (ioError (userError "retained manifest differs from durable receipt"))
  prepared <- loadPreparation (directory </> "preparation/prepared.json")
  checkRootInputs directory prepared
  session <- readPerfSession (directory </> "session.json") >>= require
  require (validateSessionInputs prepared session)
  unless (uri == session.evidenceBaseUri <> "/sessions/" <> renderRunId session.sessionId <> "/" <> relative <> "/manifest.json") (ioError (userError "receipt destination differs from its pinned session"))
  inputs <- require (parseInputs session)
  result <- readJSON (directory </> "result.json")
  unless (sha256Hex (canonicalEncode (toJSON (result :: PerfResult))) == resultDigest) (ioError (userError "retained aggregate differs from durable receipt"))
  state <- require (journalState session)
  let completed = Map.elems state.completed
  valid <- traverse (verifyConfiguration inputs prepared directory) completed
  unless (and valid) (ioError (userError "retained comparison replay differs"))
  recomputed <- require (aggregateResult session.plan session.preparedSha256 result.evidenceVerified result.configurations)
  unless (toJSON recomputed == toJSON result && all (\entry -> any (\retained -> retained.profile == entry.profile && retained.comparison == entry.comparison && retained.runtimeFailures == entry.runtimeFailures) result.configurations) completed) (ioError (userError "aggregate differs from the pinned session results"))
  unless offline do
    destination <- maybe (ioError (userError "receipt has no manifest URI")) pure (Text.stripSuffix "/manifest.json" uri)
    (bucket, prefix) <- require (parseDestination destination)
    (store, _) <- openStore bucket
    verifyPublication store bucket prefix directory >>= require
  Lazy.putStrLn (encode (object ["verified" .= True, "offline" .= offline, "manifestUri" .= (uri :: Text), "result" .= result]))
  pure (exit result.exitCode)

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
renderReport result = Text.unlines (["# Runtime performance validation", "", "Performance: " <> result.performanceVerdict, "Coverage: " <> result.coverage <> " (whole change: " <> result.changeCoverage <> ")", "Infrastructure: " <> result.infrastructureState, "Exit: " <> Text.pack (show result.exitCode), "", "| Profile | Verdict | Valid pairs | Infrastructure |", "| --- | --- | --- | --- |"] <> ["| " <> item.profile <> " | " <> item.performanceVerdict <> " | " <> Text.pack (show item.validPairs) <> "/" <> Text.pack (show item.requiredPairs) <> " | " <> item.infrastructureState <> " |" | item <- result.configurations] <> ["", "Runtime blockers: " <> Text.intercalate "; " result.blockingRuntimeFailures])

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
