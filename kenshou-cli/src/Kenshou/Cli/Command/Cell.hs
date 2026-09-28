module Kenshou.Cli.Command.Cell (cellCommand) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException, SomeException, displayException, finally, fromException, throwIO, try)
import Data.Aeson (FromJSON, Value (..), eitherDecode, eitherDecodeFileStrict', encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (diffUTCTime, getCurrentTime)
import Kenshou.Core.Cli (CliCommand (..), CliEnv (..), CliGroup (..))
import Kenshou.Core.Id (RunId, newRunId, parseRunId, renderRunId)
import Kenshou.Remote.Cell.Control (CellSnapshot (..), readCellSnapshot)
import Kenshou.Remote.Cell.Docs (CachePolicy (..), CellBuckets (..), CellDescriptor (..), CellManifest (..), CellOutcome (..), CellStatus (..), Limits (..), Rejected (..), Submission (..))
import Kenshou.Remote.Cell.Exec (cellExec)
import Kenshou.Remote.Cell.Fetch (FetchError (..), fetchCellRun, verifyCellRun)
import Kenshou.Remote.Cell.Index (deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseHandle, LeaseRequest (..), Quarantine (..), acquireLease, leaseSnapshot, reattachLease, releaseLease, resizeLease, validCellName, withHeartbeat)
import Kenshou.Remote.Cell.Parity (ParityOptions (..), ParityReport (..), compareForParity)
import Kenshou.Remote.Cell.Prepare (Granularity (..), OtlpSink (..), PrepareOptions (..))
import Kenshou.Remote.Cell.RouteJson (RouteDocuments (..), routeWorkJson)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities (..), defaultRoutingRules, descriptorDigest, loadCellCapabilities)
import Kenshou.Remote.Cell.Session (SessionTransition (..))
import Kenshou.Remote.Cell.Session.Build (BuildOptions (..), BuiltSession (..), buildSession)
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), SessionJournal (..), SliceJournal (..), SliceState (..), applyTransition, readSessionJournal, writeSessionJournal)
import Kenshou.Remote.Cell.Session.Resume (resumeHeldSession, resumeObservedSlices)
import Kenshou.Remote.Cell.Session.Runner (runPlannedSlices)
import Kenshou.Remote.Cell.Submit (PublishOutcome (Submitted), publishSubmission)
import Kenshou.Remote.Cell.Watch (WatchEvent (..), WatchTerminal (..), watchCellRun)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Publisher (PublishError (..), PublishOptions (..), publishPayload)
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..))
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Remote.Store.Gcs (newGcsStore, newTokenProvider)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesPathExist, renameFile)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

data CellLocation = CellLocation !Text !(Maybe Text)

data LeaseCli = LeaseCli !CellLocation !Text !(Maybe Text) !Int !Int !Bool !Bool

data RouteCli = RouteCli ![Text] !(Maybe Text) !FilePath !(Maybe FilePath) !(Maybe FilePath) !FilePath !Bool !Bool

data SubmitSettings = SubmitSettings ![String] !FilePath !FilePath !Granularity !CachePolicy ![Text] !Bool !Bool !Bool !(Maybe FilePath) !OtlpSink !(Maybe Text) !Bool

data SubmitCli = SubmitCli !CellLocation !Text !SubmitSettings !Bool

data RunCli = RunCli !CellLocation !SubmitSettings !Int !Int !Bool

data ProbeCli = ProbeCli !CellLocation !FilePath !(Maybe FilePath)

data PayloadPublishCli = PayloadPublishCli !Text !Text !(Maybe Text) !FilePath !FilePath !Bool

data CellAction
  = Fetch !Text !Text !FilePath
  | Verify !FilePath
  | Parity !FilePath !FilePath !(Maybe FilePath) ![Text]
  | Status !CellLocation !Bool
  | LeaseCell !LeaseCli
  | Release !CellLocation !Text
  | Watch !CellLocation !Text
  | Route !RouteCli
  | Submit !SubmitCli
  | Run !RunCli
  | Probe !ProbeCli
  | Resume !FilePath !(Maybe Text)
  | PublishPayload !PayloadPublishCli
  | ShowPayload !FilePath
  | Exec !FilePath !FilePath

cellCommand :: CliCommand
cellCommand = CliCommand "cell" "Run and inspect leased verification cells" Execution False (runCell <$> cellParser)

cellParser :: Parser CellAction
cellParser =
  hsubparser $
    command "fetch" (info (fetchParser <**> helper) (progDesc "Fetch and verify one sealed cell run"))
      <> command "verify" (info (verifyParser <**> helper) (progDesc "Verify a fetched tree or a sealed GCS run"))
      <> command "parity" (info (parityParser <**> helper) (progDesc "Compare local and cell verdicts with named placement differences"))
      <> command "status" (info (statusParser <**> helper) (progDesc "Inspect cell descriptor and lease state"))
      <> command "lease" (info (leaseParser <**> helper) (progDesc "Acquire a cell lease"))
      <> command "release" (info (releaseParser <**> helper) (progDesc "Release an owned cell lease"))
      <> command "watch" (info (watchParser <**> helper) (progDesc "Follow a cell run to its terminal status"))
      <> command "route" (info (routeParser <**> helper) (progDesc "Split a plan across compatible cells"))
      <> command "submit" (info (submitParser <**> helper) (progDesc "Submit a prepared plan under an existing lease"))
      <> command "run" (info (runParser <**> helper) (progDesc "Lease, submit, verify and release a cell session"))
      <> command "probe" (info (probeParser <**> helper) (progDesc "Run a cell environment probe and cache capabilities"))
      <> command "resume" (info (resumeParser <**> helper) (progDesc "Continue a saved cell session"))
      <> command "payload" (info (payloadParser <**> helper) (progDesc "Build and publish a checked cell payload"))
      <> (command "exec" (info (cellExecParser <**> helper) (progDesc "Execute prepared work on a cell driver")) <> internal)

payloadParser :: Parser CellAction
payloadParser =
  hsubparser $
    command "publish" (info (publishPayloadParser <**> helper) (progDesc "Publish a Nix closure after checking its runtime cohort"))
      <> command "show" (info (ShowPayload <$> strArgument (metavar "FILE") <**> helper) (progDesc "Show a payload descriptor after checking its bundle exists"))

publishPayloadParser :: Parser CellAction
publishPayloadParser =
  PublishPayload
    <$> ( PayloadPublishCli
            <$> strOption (long "cohort" <> metavar "released|head" <> help "Pinned runtime cohort")
            <*> strOption (long "variant" <> metavar "default|info-table|profiled" <> value "default" <> showDefault <> help "Executable build variant")
            <*> optional (strOption (long "control-bucket" <> metavar "BUCKET" <> help "Payload control bucket"))
            <*> strOption (long "out" <> metavar "FILE" <> help "Payload descriptor JSON output")
            <*> strOption (long "root" <> metavar "DIR" <> value "." <> showDefault <> help "Flake and cohort descriptor root")
            <*> switch (long "allow-dirty" <> help "Permit a payload from a dirty worktree")
        )

cellLocationParser :: Parser CellLocation
cellLocationParser =
  CellLocation
    <$> strOption (long "cell" <> metavar "NAME" <> help "Cell name")
    <*> optional (strOption (long "control-bucket" <> metavar "BUCKET" <> help "Cell control bucket"))

statusParser :: Parser CellAction
statusParser = Status <$> cellLocationParser <*> switch (long "json" <> help "Print JSON")

leaseParser :: Parser CellAction
leaseParser =
  LeaseCell
    <$> ( LeaseCli
            <$> cellLocationParser
            <*> strOption (long "purpose" <> metavar "TEXT" <> help "Purpose recorded in the lease")
            <*> optional (strOption (long "owner" <> metavar "TEXT" <> help "Lease owner; defaults to USER"))
            <*> option auto (long "ttl" <> metavar "SECONDS" <> value 120 <> showDefault <> help "Lease lifetime between renewals")
            <*> option auto (long "wait" <> metavar "SECONDS" <> value 0 <> showDefault <> help "Wait for a busy lease")
            <*> switch (long "hold" <> help "Renew in the foreground until interrupted")
            <*> switch (long "json" <> help "Print the lease document as JSON")
        )

releaseParser :: Parser CellAction
releaseParser = Release <$> cellLocationParser <*> strOption (long "lease-id" <> metavar "UUID" <> help "Expected lease identifier")

watchParser :: Parser CellAction
watchParser = Watch <$> cellLocationParser <*> strArgument (metavar "CELL_RUN_ID")

routeParser :: Parser CellAction
routeParser =
  Route
    <$> ( RouteCli
            <$> some (strOption (long "cell" <> metavar "NAME" <> help "Candidate cell in preference order; repeat to add cells"))
            <*> optional (strOption (long "control-bucket" <> metavar "BUCKET" <> help "Cell control bucket"))
            <*> strOption (long "plan" <> metavar "FILE" <> help "Run plan JSON, or - for stdin")
            <*> optional (strOption (long "payload" <> metavar "FILE" <> help "Payload descriptor for cohort preparation"))
            <*> optional (strOption (long "routing-rules" <> metavar "FILE" <> help "Replace the built-in routing policy with JSON, or - for stdin"))
            <*> strOption (long "out" <> metavar "DIR" <> help "Directory for routed plans and refusal report")
            <*> switch (long "coerce-durable" <> help "Use durable PostgreSQL when the scenario supports it")
            <*> switch (long "ephemeral-on-driver" <> help "Keep server-control correctness work on the cell driver")
        )

submitParser :: Parser CellAction
submitParser =
  Submit
    <$> ( SubmitCli
            <$> cellLocationParser
            <*> strOption (long "lease-id" <> metavar "UUID" <> help "Active lease identifier")
            <*> submitSettingsParser (switch (long "dry-run" <> help "Print a planned session without writing or submitting"))
            <*> pure False
        )

runParser :: Parser CellAction
runParser =
  Run
    <$> ( RunCli
            <$> cellLocationParser
            <*> submitSettingsParser (pure False)
            <*> option auto (long "ttl" <> metavar "SECONDS" <> value 120 <> showDefault <> help "Held lease lifetime between renewals")
            <*> option auto (long "wait" <> metavar "SECONDS" <> value 0 <> showDefault <> help "Wait for a busy cell")
            <*> switch (long "detach" <> help "Submit one slice and leave its budgeted lease to run after this process exits")
        )

probeParser :: Parser CellAction
probeParser =
  Probe
    <$> ( ProbeCli
            <$> cellLocationParser
            <*> strOption (long "payload" <> metavar "FILE" <> help "Published payload descriptor with the cell-environment scenario")
            <*> optional (strOption (long "out" <> metavar "FILE" <> help "Capability cache JSON; defaults to the configured cache directory"))
        )

submitSettingsParser :: Parser Bool -> Parser SubmitSettings
submitSettingsParser dryFlag =
  SubmitSettings
    <$> some (strOption (long "payload" <> metavar "[LABEL=]FILE" <> help "Payload descriptor; repeat for trial arms"))
    <*> strOption (long "plan" <> metavar "FILE" <> help "Run plan JSON, or - for stdin")
    <*> strOption (long "out" <> metavar "DIR" <> help "New session directory")
    <*> option (eitherReader parseGranularity) (long "granularity" <> metavar "auto|plan|run" <> value GranularityAuto <> showDefaultWith (const "auto") <> help "Submission slice boundary")
    <*> option (eitherReader parseCachePolicy) (long "cache-policy" <> metavar "cold|warm" <> value Cold <> showDefaultWith (const "cold") <> help "Cell cache reset policy")
    <*> many (strOption (long "pg-setting" <> metavar "KEY=VALUE" <> help "PostgreSQL reset setting; repeat as needed"))
    <*> switch (long "skip-incompatible" <> help "Record incompatible runs and submit compatible ones")
    <*> switch (long "coerce-durable" <> help "Use durable PostgreSQL when the scenario supports it")
    <*> switch (long "ephemeral-on-driver" <> help "Keep server-control correctness work on the cell driver")
    <*> optional (strOption (long "routing-rules" <> metavar "FILE" <> help "Replace the built-in routing policy JSON"))
    <*> option (eitherReader parseOtlpSink) (long "otlp-sink" <> metavar "null|file" <> value NullSink <> showDefaultWith (const "null") <> help "Cell OTLP sink")
    <*> optional (strOption (long "rts" <> metavar "OPTS" <> help "Runtime system options passed to the payload"))
    <*> dryFlag

parseGranularity :: String -> Either String Granularity
parseGranularity "auto" = Right GranularityAuto
parseGranularity "plan" = Right GranularityPlan
parseGranularity "run" = Right GranularityRun
parseGranularity _ = Left "expected auto, plan or run"

parseCachePolicy :: String -> Either String CachePolicy
parseCachePolicy "cold" = Right Cold
parseCachePolicy "warm" = Right Warm
parseCachePolicy _ = Left "expected cold or warm"

parseOtlpSink :: String -> Either String OtlpSink
parseOtlpSink "null" = Right NullSink
parseOtlpSink "file" = Right FileSink
parseOtlpSink _ = Left "expected null or file"

resumeParser :: Parser CellAction
resumeParser =
  Resume
    <$> strOption (long "session" <> metavar "DIR" <> help "Directory containing session.json")
    <*> optional (strOption (long "lease-id" <> metavar "UUID" <> help "Use this active lease instead of the journal lease"))

cellExecParser :: Parser CellAction
cellExecParser = Exec <$> strArgument (metavar "WORK_FILE") <*> strArgument (metavar "OUT_DIR")

fetchParser :: Parser CellAction
fetchParser =
  Fetch
    <$> strOption (long "results-bucket" <> metavar "BUCKET" <> help "Results bucket containing the sealed run")
    <*> strArgument (metavar "CELL_RUN_ID")
    <*> strOption (long "out" <> metavar "DIR" <> help "Directory for the fetched cell run")

verifyParser :: Parser CellAction
verifyParser = Verify <$> strArgument (metavar "DIR_OR_GS_URI")

parityParser :: Parser CellAction
parityParser =
  Parity
    <$> strOption (long "local" <> metavar "DIR" <> help "Local run directory")
    <*> strOption (long "cell" <> metavar "DIR" <> help "Fetched nested cell run directory")
    <*> optional (strOption (long "out" <> metavar "FILE" <> help "Write the parity report to FILE instead of stdout"))
    <*> many (strOption (long "volatile" <> metavar "PATH" <> help "Allow a named volatile verdict field; repeat as needed"))

runCell :: CellAction -> CliEnv -> IO ExitCode
runCell selected cli = case selected of
  PublishPayload (PayloadPublishCli cohort variant selectedBucket output root allowDirty) -> do
    configured <- lookupEnv "KENSHOU_CELL_CONTROL_BUCKET"
    let bucketName = fromMaybe (maybe "tan-nb-exp-cells-control" Text.pack configured) selectedBucket
    case validateBucket bucketName of
      Left problem -> usage problem
      Right bucket -> guardIO do
        store <- openStore bucket
        published <- publishPayload store (PublishOptions root cohort variant bucket output allowDirty)
        case published of
          Left (PublishInvalidSelection problem) -> usage problem
          Left (PublishCohortMismatch problem) -> failVerification problem
          Left PublishDirtyWorktree -> unavailable "worktree is dirty; pass --allow-dirty to publish it"
          Left problem -> unavailable (Text.pack (show problem))
          Right _ -> TextIO.putStrLn (Text.pack output) >> pure ExitSuccess
  ShowPayload path -> guardIO do
    decoded <- eitherDecodeFileStrict' path
    case decoded of
      Left problem -> failVerification (Text.pack problem)
      Right (descriptor :: PayloadDescriptor) -> case parsePayloadUri descriptor.cell.bundle.uri of
        Left problem -> failVerification problem
        Right (bucket, bundleObject) -> do
          store <- openStore bucket
          observed <- store.statObject bucket bundleObject
          case observed of
            Nothing -> failVerification "payload bundle does not exist"
            Just meta
              | meta.size /= descriptor.cell.bundle.bytes -> failVerification "payload bundle size differs from descriptor"
              | otherwise -> LazyByteString.putStrLn (encode descriptor) >> pure ExitSuccess
  Fetch bucket identifier outDir -> case (validateBucket bucket, parseRunId identifier) of
    (Left problem, _) -> usage problem
    (_, Left problem) -> usage problem
    (Right resultsBucket, Right cellRun) -> guardIO $ do
      store <- openStore resultsBucket
      fetched <- fetchCellRun store resultsBucket cellRun outDir
      case fetched of
        Left problem -> fetchFailure problem
        Right tree -> do
          indexed <- deriveCellRunIndex resultsBucket Nothing tree
          case indexed of
            Left problems -> failVerification (Text.pack (show (NonEmpty.toList problems)))
            Right index -> do
              path <- writeCellRunIndex tree index
              TextIO.putStrLn (Text.pack path)
              pure ExitSuccess
  Verify location -> case Text.stripPrefix "gs://" (Text.pack location) of
    Nothing -> guardIO $ do
      let nested = location </> "tree"
      isRunDirectory <- doesDirectoryExist nested
      exists <- doesDirectoryExist location
      if exists then verifyTree (if isRunDirectory then nested else location) else unavailable "verification directory does not exist"
    Just suffix -> case parseResultsUri suffix of
      Left problem -> usage problem
      Right (bucket, identifier) -> guardIO $
        withSystemTempDirectory "kenshou-cell-verify" \temporary -> do
          store <- openStore bucket
          fetched <- fetchCellRun store bucket identifier temporary
          case fetched of
            Left problem -> fetchFailure problem
            Right tree -> verifyTree tree
  Parity localDir cellDir output volatile
    | any (\path -> not ("result.summaries.verdicts." `Text.isPrefixOf` path || "verdicts." `Text.isPrefixOf` path)) volatile -> usage "--volatile must name a field under result.summaries.verdicts or verdicts"
    | otherwise -> guardIO do
        report <- compareForParity (ParityOptions volatile) localDir cellDir
        case output of
          Nothing -> LazyByteString.putStrLn (encode report)
          Just path -> do
            createDirectoryIfMissing True (takeDirectory path)
            LazyByteString.writeFile path (encode report)
            TextIO.putStrLn (Text.pack path)
        pure (if null report.unexpected then ExitSuccess else ExitFailure 1)
  Status location asJson -> withControl location \_ _ snapshot -> do
    if asJson
      then LazyByteString.putStrLn (encode (object ["descriptor" .= snapshot.descriptor, "lease" .= snapshot.lease, "quarantine" .= snapshot.quarantine]))
      else do
        let descriptor = snapshot.descriptor
        TextIO.putStrLn ("cell " <> descriptor.name <> " project=" <> descriptor.project <> " zone=" <> descriptor.zone <> " pg=" <> Text.pack (show descriptor.postgresMajor))
        TextIO.putStrLn ("lease " <> maybe "none" (renderRunId . (.leaseId)) snapshot.lease)
        TextIO.putStrLn ("quarantine " <> maybe "none" (.reason) snapshot.quarantine)
    pure ExitSuccess
  LeaseCell (LeaseCli location purpose owner ttl waitSeconds hold asJson)
    | ttl <= 0 || waitSeconds < 0 || Text.null purpose || maybe False Text.null owner -> usage "lease purpose and TTL must be positive; wait cannot be negative"
    | otherwise -> withControl location \store ref _ -> do
        defaultOwner <- Text.pack . fromMaybe "kenshou" <$> lookupEnv "USER"
        let request = LeaseRequest (fromMaybe defaultOwner owner) purpose ttl
        start <- getCurrentTime
        let acquire = do
              outcome <- acquireLease store ref request
              case outcome of
                Acquired handle -> do
                  record <- leaseSnapshot handle
                  if asJson
                    then LazyByteString.putStrLn (encode record)
                    else TextIO.putStrLn ("lease " <> renderRunId record.leaseId <> " ttl=" <> Text.pack (show record.ttlSeconds))
                  if hold
                    then withHeartbeat store ref handle (holdLease) `finally` (do _ <- releaseLease store ref handle; pure ())
                    else pure ExitSuccess
                Busy current -> do
                  now <- getCurrentTime
                  if diffUTCTime now start < fromIntegral waitSeconds
                    then threadDelay 2000000 >> acquire
                    else unavailable ("cell is busy under lease " <> renderRunId current.leaseId)
                Quarantined record -> unavailable ("cell is quarantined: " <> record.reason)
        acquire
  Release location leaseText -> case parseRunId leaseText of
    Left problem -> usage problem
    Right expected -> withControl location \store ref _ -> do
      reattached <- reattachLease store ref expected
      case reattached of
        Nothing -> unavailable "cell has no matching lease"
        Just handle -> do
          released <- releaseLease store ref handle
          if released then TextIO.putStrLn ("released " <> leaseText) >> pure ExitSuccess else unavailable "cell lease changed before release"
  Watch location runText -> case parseRunId runText of
    Left problem -> usage problem
    Right identifier -> withControl location \store ref _ -> do
      terminal <- watchCellRun store ref identifier emitWatchEvent
      case terminal of
        RunRejected rejected -> do
          TextIO.hPutStrLn stderr ("rejected: " <> rejected.reason)
          pure (if rejected.reason `elem` ["lease-mismatch", "payload-digest-mismatch"] then ExitFailure 4 else ExitFailure 2)
        RunSealed status -> do
          TextIO.hPutStrLn stderr ("sealed: " <> Text.pack (show status.outcome))
          pure (if status.outcome == Just Completed then ExitSuccess else ExitFailure 4)
  Route (RouteCli names bucket planFile payloadFile rulesFile outDir coerce ephemeral)
    | length (nub names) /= length names || not (all validCellName names) -> usage "cell names must be valid and unique"
    | planFile == "-" && rulesFile == Just "-" -> usage "only one JSON document may be read from stdin"
    | payloadFile == Just "-" -> usage "payload must name a file"
    | otherwise -> case NonEmpty.nonEmpty names of
        Nothing -> usage "at least one cell is required"
        Just (first :| rest) -> withControl (CellLocation first bucket) \store ref observed -> do
          allowed <- maybe ["tan-nb-exp"] (map Text.strip . Text.splitOn "," . Text.pack) <$> lookupEnv "KENSHOU_GCP_ALLOWED_PROJECTS"
          remaining <- traverse (\name -> readCellSnapshot store (CellRef name ref.controlBucket) allowed) rest
          case sequence remaining of
            Left problem -> unavailable problem
            Right snapshots -> do
              let descriptors = observed.descriptor : fmap (.descriptor) snapshots
              capabilityResult <- loadCapabilitiesFor descriptors
              planResult <- readJsonDocument planFile
              rulesResult <- maybe (pure (Right defaultRoutingRules)) readJsonDocument rulesFile
              payloadResult <- traverse eitherDecodeFileStrict' payloadFile
              case (capabilityResult, planResult, rulesResult, sequence payloadResult) of
                (Left problem, _, _, _) -> usage problem
                (_, Left failure, _, _) -> usage (Text.pack failure)
                (_, _, Left failure, _) -> usage (Text.pack failure)
                (_, _, _, Left failure) -> usage (Text.pack failure)
                (Right caches, Right plan, Right rules, Right payload) ->
                  case NonEmpty.nonEmpty (zip descriptors caches) >>= \cells -> Just (routeWorkJson cli.registry cells rules (Map.singleton "default" <$> payload) (PrepareOptions coerce ephemeral [] Cold) plan) of
                    Nothing -> usage "at least one cell is required"
                    Just (Left problem) -> usage problem
                    Just (Right documents) -> guardIO do
                      exists <- doesPathExist outDir
                      if exists
                        then usage "route output path already exists; choose a new directory"
                        else do
                          createDirectoryIfMissing True outDir
                          traverse_ (\(name, planDocument) -> LazyByteString.writeFile (outDir </> "plan." <> Text.unpack name <> ".json") (encode planDocument)) (Map.toAscList documents.perCell)
                          traverse_ (\planDocument -> LazyByteString.writeFile (outDir </> "plan.local.json") (encode planDocument)) documents.local
                          LazyByteString.writeFile (outDir </> "unroutable.json") (encode documents.report)
                          TextIO.hPutStrLn stderr ("routed plans: " <> Text.pack (show (Map.size documents.perCell)) <> "; see " <> Text.pack (outDir </> "unroutable.json"))
                          pure (if documents.routeComplete then ExitSuccess else ExitFailure 2)
  Submit (SubmitCli location leaseText (SubmitSettings payloadFiles planFile outDir granularity cache settingTexts skip coerce ephemeral rulesFile sink rts dryRun) detached)
    | planFile == "-" && rulesFile == Just "-" -> usage "only one JSON document may be read from stdin"
    | otherwise -> case (parseRunId leaseText, traverse parsePgSetting settingTexts) of
        (Left problem, _) -> usage problem
        (_, Left problem) -> usage problem
        (Right leaseId, Right settings) -> withControl location \store ref observed -> do
          handle <- reattachLease store ref leaseId
          case handle of
            Nothing -> unavailable "cell has no matching lease"
            Just active -> do
              payloadResult <- loadPayloads payloadFiles
              rulesResult <- maybe (pure (Right defaultRoutingRules)) readJsonDocument rulesFile
              case (payloadResult, rulesResult) of
                (Left problem, _) -> usage problem
                (_, Left failure) -> usage (Text.pack failure)
                (Right payloads, Right rules) -> do
                  capabilityResult <- loadCapabilitiesFor [observed.descriptor]
                  case capabilityResult of
                    Left problem -> usage problem
                    Right [cachedCapabilities] -> do
                      bytes <- if planFile == "-" then LazyByteString.getContents else LazyByteString.readFile planFile
                      selectedStore <- lookupEnv "KENSHOU_CELL_STORE"
                      let options = BuildOptions (PrepareOptions coerce ephemeral settings cache) granularity skip sink rts (24 * 1024 * 1024 * 1024) (20 * 1024 * 1024 * 1024) "0.1.0"
                          storeLabel = Text.pack (fromMaybe "gs://" selectedStore)
                      built <- buildSession cli.registry observed.descriptor cachedCapabilities rules payloads options storeLabel leaseId bytes
                      case built of
                        Left problem -> usage problem
                        Right session
                          | dryRun -> LazyByteString.putStrLn (encode session.journal) >> pure ExitSuccess
                          | detached && length session.journal.slices /= 1 -> usage "detached sessions require exactly one slice; use --granularity plan for a compatible plan"
                          | otherwise -> guardIO do
                              exists <- doesPathExist outDir
                              if exists
                                then usage "session output path already exists; choose a new directory"
                                else do
                                  if detached
                                    then do
                                      slice <- singleSlice session.journal
                                      let budget = toInteger slice.submission.limits.wallClockSeconds + 600
                                      if budget > toInteger (maxBound :: Int)
                                        then ioError (userError "detached lease budget exceeds supported TTL")
                                        else do
                                          lease <- leaseSnapshot active
                                          enlarged <- resizeLease store ref active (max lease.ttlSeconds (fromInteger budget))
                                          if enlarged then pure () else ioError (userError "cell lease changed before detached submission")
                                    else pure ()
                                  traverse_
                                    ( \(relative, content) -> do
                                        let destination = outDir </> relative
                                        createDirectoryIfMissing True (takeDirectory destination)
                                        LazyByteString.writeFile destination content
                                    )
                                    session.workFiles
                                  if detached
                                    then do
                                      slice <- singleSlice session.journal
                                      let journal = session.journal {leaseMode = Detached}
                                          journalPath = outDir </> "session.json"
                                      writeSessionJournal journalPath journal
                                      work <- LazyByteString.readFile (outDir </> slice.workPath)
                                      published <- publishSubmission store ref active slice.submission work
                                      case published of
                                        Submitted -> do
                                          now <- getCurrentTime
                                          checkpoint <- either (ioError . userError . Text.unpack) pure (applyTransition now slice.cellRun SubmissionPublished journal)
                                          writeSessionJournal journalPath checkpoint
                                          TextIO.hPutStrLn stderr ("detached session " <> renderRunId checkpoint.sessionId <> " submitted; collect with cell resume --session " <> Text.pack outDir)
                                          pure ExitSuccess
                                        other -> unavailable ("detached submission failed: " <> Text.pack (show other))
                                    else do
                                      result <- runPlannedSlices store ref (Bucket observed.descriptor.buckets.results) active (outDir </> "session.json") session.journal emitWatchEvent
                                      case result of
                                        Left failure -> unavailable (Text.pack (show failure))
                                        Right finished -> do
                                          TextIO.hPutStrLn stderr ("session " <> renderRunId finished.sessionId <> " verified; journal " <> Text.pack (outDir </> "session.json"))
                                          pure (sessionExitCode finished)
                    Right _ -> unavailable "cell capability cache count differs from descriptor count"
  Run (RunCli location settings ttl waitSeconds detached)
    | ttl <= 0 || waitSeconds < 0 -> usage "lease TTL must be positive and wait cannot be negative"
    | otherwise -> withControl location \store ref _ -> do
        defaultOwner <- Text.pack . fromMaybe "kenshou" <$> lookupEnv "USER"
        start <- getCurrentTime
        let request = LeaseRequest defaultOwner "kenshou cell run" ttl
            acquire = do
              outcome <- acquireLease store ref request
              case outcome of
                Acquired handle -> do
                  lease <- leaseSnapshot handle
                  let execute = runCell (Submit (SubmitCli location (renderRunId lease.leaseId) settings detached)) cli
                      releaseCurrent = do
                        current <- reattachLease store ref lease.leaseId
                        traverse_ (\active -> do _ <- releaseLease store ref active; pure ()) current
                      releaseUnlessPublished = do
                        let SubmitSettings _ _ outDir _ _ _ _ _ _ _ _ _ _ = settings
                            journalPath = outDir </> "session.json"
                        present <- doesPathExist journalPath
                        if not present
                          then releaseCurrent
                          else do
                            decoded <- readSessionJournal journalPath
                            case decoded of
                              Left _ -> pure ()
                              Right journal | journal.leaseId /= lease.leaseId || journal.cell /= ref.cellName -> releaseCurrent
                              Right journal -> do
                                markers <- traverse (\slice -> store.statObject ref.controlBucket (ObjectName ("cells/" <> ref.cellName <> "/submissions/" <> renderRunId slice.cellRun <> "/submission.json"))) journal.slices
                                if all isNothing markers then releaseCurrent else pure ()
                  execute `finally` (if detached then releaseUnlessPublished else releaseCurrent)
                Busy current -> do
                  now <- getCurrentTime
                  if diffUTCTime now start < fromIntegral waitSeconds
                    then threadDelay 2000000 >> acquire
                    else unavailable ("cell is busy under lease " <> renderRunId current.leaseId)
                Quarantined record -> unavailable ("cell is quarantined: " <> record.reason)
        acquire
  Probe request -> runProbe cli request
  Resume sessionDir selectedLease -> guardIO do
    let journalPath = sessionDir </> "session.json"
    present <- doesPathExist journalPath
    if not present
      then unavailable "session.json is missing"
      else do
        decoded <- readSessionJournal journalPath
        case decoded of
          Left problem -> usage problem
          Right journal -> do
            selectedStore <- Text.pack . fromMaybe "gs://" <$> lookupEnv "KENSHOU_CELL_STORE"
            if selectedStore /= journal.store
              then usage "selected cell store differs from the session journal"
              else case traverse parseRunId selectedLease of
                Left problem -> usage problem
                Right requested -> withControl (CellLocation journal.cell (Just journal.controlBucket)) \store ref observed -> do
                  if observed.descriptor.buckets.results /= journal.resultsBucket
                    then usage "cell results bucket differs from the session journal"
                    else do
                      let expected = fromMaybe journal.leaseId requested
                      existing <- reattachLease store ref expected
                      case existing of
                        Just _ | journal.leaseMode == Detached -> continueDetached store ref journalPath journal
                        Just handle -> continueSession store ref journalPath journal handle
                        Nothing | requested /= Nothing -> unavailable "cell has no matching selected lease"
                        Nothing | journal.leaseMode == Detached -> continueDetached store ref journalPath journal
                        Nothing -> do
                          owner <- Text.pack . fromMaybe "kenshou" <$> lookupEnv "USER"
                          acquired <- acquireLease store ref (LeaseRequest owner ("resume " <> renderRunId journal.sessionId) 120)
                          case acquired of
                            Busy current -> unavailable ("cell is busy under lease " <> renderRunId current.leaseId)
                            Quarantined record -> unavailable ("cell is quarantined: " <> record.reason)
                            Acquired handle -> continueSession store ref journalPath journal handle `finally` (do _ <- releaseLease store ref handle; pure ())
  Exec workFile outDir -> cellExec cli.registry workFile outDir

continueSession :: ObjectStore -> CellRef -> FilePath -> SessionJournal -> LeaseHandle -> IO ExitCode
continueSession store ref journalPath journal handle = do
  resumed <- resumeHeldSession store ref (Bucket journal.resultsBucket) handle journalPath emitWatchEvent
  case resumed of
    Left failure -> unavailable (Text.pack (show failure))
    Right finished -> do
      TextIO.hPutStrLn stderr ("session " <> renderRunId finished.sessionId <> " verified; journal " <> Text.pack journalPath)
      pure (sessionExitCode finished)

continueDetached :: ObjectStore -> CellRef -> FilePath -> SessionJournal -> IO ExitCode
continueDetached store ref journalPath journal = do
  observed <- resumeObservedSlices store ref (Bucket journal.resultsBucket) journalPath emitWatchEvent
  case observed of
    Left failure -> unavailable (Text.pack (show failure))
    Right finished ->
      if not (null finished.slices) && all (\slice -> slice.state `elem` [SliceRejected, SliceVerified]) finished.slices
        then do
          current <- reattachLease store ref journal.leaseId
          traverse_ (\active -> do _ <- releaseLease store ref active; pure ()) current
          TextIO.hPutStrLn stderr ("detached session " <> renderRunId finished.sessionId <> " collected; journal " <> Text.pack journalPath)
          pure (sessionExitCode finished)
        else unavailable "detached session has not reached a terminal cell status; resume later"

singleSlice :: SessionJournal -> IO SliceJournal
singleSlice journal = case journal.slices of
  [slice] -> pure slice
  _ -> ioError (userError "detached session must contain exactly one slice")

sessionExitCode :: SessionJournal -> ExitCode
sessionExitCode journal
  | any ((/= SliceVerified) . (.state)) journal.slices = ExitFailure 4
  | any ((/= Just Completed) . (.cellOutcome)) journal.slices = ExitFailure 4
  | any ((== Just 4) . (.entryExitCode)) journal.slices = ExitFailure 4
  | any ((== Just 3) . (.entryExitCode)) journal.slices = ExitFailure 3
  | any ((== Just 1) . (.entryExitCode)) journal.slices = ExitFailure 1
  | all ((== Just 0) . (.entryExitCode)) journal.slices = ExitSuccess
  | otherwise = ExitFailure 4

runProbe :: CliEnv -> ProbeCli -> IO ExitCode
runProbe cli (ProbeCli location payload output) = withControl location \_ _ observed -> do
  cacheDirectory <- fromMaybe ".dev/cells" <$> lookupEnv "KENSHOU_CELL_CAPABILITIES_DIR"
  identifier <- newRunId
  let sessionDirectory = cacheDirectory </> "probes" </> Text.unpack (renderRunId identifier)
      planFile = sessionDirectory <> ".plan.json"
      cacheFile = fromMaybe (cacheDirectory </> Text.unpack observed.descriptor.name <> ".capabilities.json") output
      settings = SubmitSettings [payload] planFile sessionDirectory GranularityRun Cold [] False False False Nothing NullSink Nothing False
      planArguments =
        [ "plan",
          "--all",
          "--select",
          "selftest/remote/correctness/cell-environment",
          "--placement",
          "cell",
          "--seed",
          "7",
          "--dim",
          "pg.durability=durable",
          "--dim",
          "pg.version=" <> show observed.descriptor.postgresMajor,
          "--out",
          planFile
        ]
  createDirectoryIfMissing True (takeDirectory planFile)
  executable <- getExecutablePath
  (planned, _, planErrors) <- readProcessWithExitCode executable planArguments ""
  if planned /= ExitSuccess
    then usage ("cell probe could not plan its environment scenario: " <> Text.pack planErrors)
    else do
      result <- runCell (Run (RunCli location settings 120 0 False)) cli
      if result /= ExitSuccess
        then pure result
        else do
          saved <- readSessionJournal (sessionDirectory </> "session.json")
          case saved of
            Right journal -> case journal.slices of
              [slice] | slice.state == SliceVerified -> case slice.runIds of
                [nested] -> do
                  let runResult = takeDirectory sessionDirectory </> Text.unpack (renderRunId slice.cellRun) </> "tree" </> "output" </> Text.unpack (renderRunId nested) </> "run-result.json"
                  document <- eitherDecodeFileStrict' runResult
                  case document >>= extractProbeCapabilities slice.cellRun of
                    Left problem -> failVerification ("cell probe result has no valid capabilities: " <> Text.pack problem)
                    Right capabilities -> do
                      now <- getCurrentTime
                      let cache = CellCapabilities observed.descriptor.name (descriptorDigest observed.descriptor) slice.cellRun now capabilities
                          temporary = cacheFile <> "." <> Text.unpack (renderRunId identifier) <> ".tmp"
                      createDirectoryIfMissing True (takeDirectory cacheFile)
                      LazyByteString.writeFile temporary (encode cache)
                      renameFile temporary cacheFile
                      TextIO.putStrLn (Text.pack cacheFile)
                      pure ExitSuccess
                _ -> failVerification "cell probe verified a slice with an unexpected nested run count"
              _ -> failVerification "cell probe did not verify exactly one slice"
            Left problem -> failVerification ("cell probe session is invalid: " <> problem)

extractProbeCapabilities :: RunId -> Value -> Either String (Map.Map Text Value)
extractProbeCapabilities expectedCellRun (Object root) = do
  schema <- member "schema" root
  if schema == String "kenshou.run-result/v1" then pure () else Left "unexpected run-result schema"
  outcome <- member "outcome" root
  if outcome == String "passed" then pure () else Left "probe run did not pass"
  fingerprint <- member "fingerprint" root
  cell <- asObject "fingerprint.cell" =<< member "cell" =<< asObject "fingerprint" fingerprint
  cellRun <- member "cellRun" cell
  if cellRun == Aeson.toJSON expectedCellRun then pure () else Left "probe cell run identity differs from the verified slice"
  capabilities <- member "capabilities" cell
  case Aeson.fromJSON capabilities of
    Aeson.Error problem -> Left problem
    Aeson.Success values
      | all primitive (Map.elems values) && all (`Map.member` values) required -> Right values
      | otherwise -> Left "probe capabilities are missing or contain a non-primitive value"
  where
    primitive (Bool _) = True
    primitive (String _) = True
    primitive (Number _) = True
    primitive _ = False
    required = ["postgres.major", "postgres.pg_partman", "postgres.second-server", "postgres.control-hook", "broker", "otlp.null", "otlp.file", "fault-hook"]
    member :: Text -> KeyMap.KeyMap Value -> Either String Value
    member name fields = maybe (Left ("missing " <> Text.unpack name)) Right (KeyMap.lookup (Key.fromText name) fields)
    asObject :: String -> Value -> Either String (KeyMap.KeyMap Value)
    asObject _ (Object fields) = Right fields
    asObject label _ = Left (label <> " is not an object")
extractProbeCapabilities _ _ = Left "run result is not an object"

parsePgSetting :: Text -> Either Text (Text, Text)
parsePgSetting setting = case Text.breakOn "=" setting of
  (name, assignment) | not (Text.null name) && Text.length assignment > 1 -> Right (name, Text.drop 1 assignment)
  _ -> Left "--pg-setting must be KEY=VALUE"

loadPayloads :: [String] -> IO (Either Text (Map.Map Text PayloadDescriptor))
loadPayloads paths = do
  loaded <- traverse load paths
  pure do
    entries <- sequence loaded
    let labels = fmap fst entries
    if length (nub labels) == length labels
      then Right (Map.fromList entries)
      else Left "payload labels must be unique"
  where
    load input = case break (== '=') input of
      (label, '=' : path) | not (null label) && not (null path) && path /= "-" -> readPayload (Text.pack label) path
      (_, '=' : _) -> pure (Left "--payload must be [LABEL=]FILE with a nonempty file path")
      (_, _) | input == "-" -> pure (Left "payload must name a file")
      _ -> readPayload "default" input
    readPayload label path = do
      result <- eitherDecodeFileStrict' path
      pure (either (Left . Text.pack) (\descriptor -> Right (label, descriptor)) result)

loadCapabilitiesFor :: [CellDescriptor] -> IO (Either Text [Maybe CellCapabilities])
loadCapabilitiesFor descriptors = do
  directory <- fromMaybe ".dev/cells" <$> lookupEnv "KENSHOU_CELL_CAPABILITIES_DIR"
  sequence <$> traverse (loadCellCapabilities directory) descriptors

readJsonDocument :: (FromJSON value) => FilePath -> IO (Either String value)
readJsonDocument "-" = eitherDecode <$> LazyByteString.getContents
readJsonDocument path = eitherDecodeFileStrict' path

withControl :: CellLocation -> (ObjectStore -> CellRef -> CellSnapshot -> IO ExitCode) -> IO ExitCode
withControl (CellLocation name selectedBucket) operation = do
  configured <- lookupEnv "KENSHOU_CELL_CONTROL_BUCKET"
  let bucketName = fromMaybe (maybe "tan-nb-exp-cells-control" Text.pack configured) selectedBucket
  case validateBucket bucketName of
    Left problem -> usage problem
    Right bucket
      | not (validCellName name) -> usage "invalid cell name"
      | otherwise -> guardIO do
          store <- openStore bucket
          allowed <- maybe ["tan-nb-exp"] (map Text.strip . Text.splitOn "," . Text.pack) <$> lookupEnv "KENSHOU_GCP_ALLOWED_PROJECTS"
          let ref = CellRef name bucket
          snapshot <- readCellSnapshot store ref allowed
          case snapshot of
            Left problem -> unavailable problem
            Right observed -> operation store ref observed

holdLease :: IO Bool -> IO ExitCode
holdLease stillHeld = do
  held <- stillHeld
  if held then threadDelay 1000000 >> holdLease stillHeld else unavailable "lease was lost"

emitWatchEvent :: WatchEvent -> IO ()
emitWatchEvent event = case event of
  PhaseChanged phase -> TextIO.hPutStrLn stderr ("phase: " <> Text.pack (show phase))
  StdoutChunk bytes -> LazyByteString.hPut stdout bytes >> hFlush stdout
  StderrChunk bytes -> LazyByteString.hPut stderr bytes >> hFlush stderr

verifyTree :: FilePath -> IO ExitCode
verifyTree tree = do
  verified <- verifyCellRun tree
  case verified of
    Left problems -> failVerification (Text.pack (show (NonEmpty.toList problems)))
    Right manifest -> TextIO.putStrLn ("verified " <> renderRunId manifest.runId) >> pure ExitSuccess

openStore :: Bucket -> IO ObjectStore
openStore bucket = do
  selected <- lookupEnv "KENSHOU_CELL_STORE"
  case selected of
    Nothing -> newTokenProvider bucket >>= newGcsStore
    Just setting -> case Text.stripPrefix "file:" (Text.pack setting) of
      Just root | not (Text.null root) -> newFileStore (Text.unpack root)
      _ -> ioError (userError "KENSHOU_CELL_STORE must be file:<dir> or unset for GCS")

parseResultsUri :: Text -> Either Text (Bucket, RunId)
parseResultsUri suffix = case Text.splitOn "/" suffix of
  [bucket, "runs", identifier] -> do
    checked <- validateBucket bucket
    parsed <- parseRunId identifier
    pure (checked, parsed)
  _ -> Left "expected gs://BUCKET/runs/CELL_RUN_ID"

parsePayloadUri :: Text -> Either Text (Bucket, ObjectName)
parsePayloadUri uri = case Text.stripPrefix "gs://" uri of
  Nothing -> Left "payload bundle URI must use gs://"
  Just suffix -> case Text.breakOn "/" suffix of
    (bucketName, path) | not (Text.null path) -> do
      bucket <- validateBucket bucketName
      pure (bucket, ObjectName (Text.drop 1 path))
    _ -> Left "payload bundle URI must name an object"

validateBucket :: Text -> Either Text Bucket
validateBucket bucket
  | Text.null bucket || Text.any (\character -> not (character `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_."))) bucket = Left "invalid results bucket"
  | otherwise = Right (Bucket bucket)

guardIO :: IO ExitCode -> IO ExitCode
guardIO operation = do
  result <- try operation :: IO (Either SomeException ExitCode)
  case result of
    Left failure | Just async <- (fromException failure :: Maybe SomeAsyncException) -> throwIO async
    Left failure -> unavailable (Text.pack (displayException failure))
    Right code -> pure code

fetchFailure :: FetchError -> IO ExitCode
fetchFailure problem = case problem of
  Unsealed -> unavailable "cell run is not sealed"
  ObjectChanged _ -> unavailable (Text.pack (show problem))
  _ -> failVerification (Text.pack (show problem))

unavailable :: Text -> IO ExitCode
unavailable problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 4)

failVerification :: Text -> IO ExitCode
failVerification problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 1)

usage :: Text -> IO ExitCode
usage problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 2)
