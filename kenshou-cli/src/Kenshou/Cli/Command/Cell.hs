module Kenshou.Cli.Command.Cell (cellCommand) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException, SomeException, displayException, finally, fromException, throwIO, try)
import Data.Aeson (FromJSON, eitherDecode, eitherDecodeFileStrict', encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (diffUTCTime, getCurrentTime)
import Kenshou.Core.Cli (CliCommand (..), CliEnv (..), CliGroup (..))
import Kenshou.Core.Id (RunId, parseRunId, renderRunId)
import Kenshou.Remote.Cell.Control (CellSnapshot (..), readCellSnapshot)
import Kenshou.Remote.Cell.Docs (CachePolicy (..), CellDescriptor (..), CellManifest (..), CellOutcome (..), CellStatus (..), Rejected (..))
import Kenshou.Remote.Cell.Exec (cellExec)
import Kenshou.Remote.Cell.Fetch (FetchError (..), fetchCellRun, verifyCellRun)
import Kenshou.Remote.Cell.Index (deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Cell.Lease (AcquireOutcome (..), CellRef (..), Lease (..), LeaseRequest (..), Quarantine (..), acquireLease, leaseSnapshot, reattachLease, releaseLease, validCellName, withHeartbeat)
import Kenshou.Remote.Cell.Prepare (PrepareOptions (..))
import Kenshou.Remote.Cell.RouteJson (RouteDocuments (..), routeWorkJson)
import Kenshou.Remote.Cell.RouteRules (defaultRoutingRules)
import Kenshou.Remote.Cell.Watch (WatchEvent (..), WatchTerminal (..), watchCellRun)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Remote.Store.Gcs (newGcsStore, newTokenProvider)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesPathExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)

data CellLocation = CellLocation !Text !(Maybe Text)

data LeaseCli = LeaseCli !CellLocation !Text !(Maybe Text) !Int !Int !Bool !Bool

data RouteCli = RouteCli ![Text] !(Maybe Text) !FilePath !(Maybe FilePath) !(Maybe FilePath) !FilePath !Bool !Bool

data CellAction
  = Fetch !Text !Text !FilePath
  | Verify !FilePath
  | Status !CellLocation !Bool
  | LeaseCell !LeaseCli
  | Release !CellLocation !Text
  | Watch !CellLocation !Text
  | Route !RouteCli
  | Exec !FilePath !FilePath

cellCommand :: CliCommand
cellCommand = CliCommand "cell" "Run and inspect leased verification cells" Execution False (runCell <$> cellParser)

cellParser :: Parser CellAction
cellParser =
  hsubparser $
    command "fetch" (info (fetchParser <**> helper) (progDesc "Fetch and verify one sealed cell run"))
      <> command "verify" (info (verifyParser <**> helper) (progDesc "Verify a fetched tree or a sealed GCS run"))
      <> command "status" (info (statusParser <**> helper) (progDesc "Inspect cell descriptor and lease state"))
      <> command "lease" (info (leaseParser <**> helper) (progDesc "Acquire a cell lease"))
      <> command "release" (info (releaseParser <**> helper) (progDesc "Release an owned cell lease"))
      <> command "watch" (info (watchParser <**> helper) (progDesc "Follow a cell run to its terminal status"))
      <> command "route" (info (routeParser <**> helper) (progDesc "Split a plan across compatible cells"))
      <> (command "exec" (info (cellExecParser <**> helper) (progDesc "Execute prepared work on a cell driver")) <> internal)

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

runCell :: CellAction -> CliEnv -> IO ExitCode
runCell selected cli = case selected of
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
              planResult <- readJsonDocument planFile
              rulesResult <- maybe (pure (Right defaultRoutingRules)) readJsonDocument rulesFile
              payloadResult <- traverse eitherDecodeFileStrict' payloadFile
              case (planResult, rulesResult, sequence payloadResult) of
                (Left failure, _, _) -> usage (Text.pack failure)
                (_, Left failure, _) -> usage (Text.pack failure)
                (_, _, Left failure) -> usage (Text.pack failure)
                (Right plan, Right rules, Right payload) ->
                  case routeWorkJson cli.registry ((observed.descriptor, Nothing) :| fmap (\snapshot -> (snapshot.descriptor, Nothing)) snapshots) rules (Map.singleton "default" <$> payload) (PrepareOptions coerce ephemeral [] Cold) plan of
                    Left problem -> usage problem
                    Right documents -> guardIO do
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
  Exec workFile outDir -> cellExec cli.registry workFile outDir

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
