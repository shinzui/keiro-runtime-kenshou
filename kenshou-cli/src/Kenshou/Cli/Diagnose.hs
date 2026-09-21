module Kenshou.Cli.Diagnose
  ( diagnoseCommand,
  )
where

import Control.Exception (SomeException, bracket, displayException, try)
import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (getCurrentTime)
import Data.Word (Word64)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Kenshou.Core.Cli
import Kenshou.Diagnose.Document
import Kenshou.Diagnose.Leak
import Kenshou.Diagnose.LockGraph (buildGraph, renderDot)
import Kenshou.Diagnose.Postgres
import Kenshou.Diagnose.Profile
import Kenshou.Diagnose.Render
import Kenshou.Diagnose.Stall.Classify (classify)
import Kenshou.Diagnose.Stall.Types
import Kenshou.Diagnose.Threads (dumpThreads)
import Options.Applicative hiding (Success)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO (stderr)
import System.Process (callProcess)

data DiagnoseOptions = DiagnoseLeak LeakOptions | DiagnoseStall StallOptions | DiagnoseProfile ProfileOptions

data LeakOptions = LeakOptions
  { runDirectory :: !FilePath,
    policy :: !(Maybe InputSource),
    seed :: !Word64,
    output :: !(Maybe FilePath),
    json :: !Bool
  }

data StallOptions = StallOptions
  { runDirectory :: !(Maybe FilePath),
    live :: !Bool,
    connection :: !(Maybe Text),
    reclassify :: !Bool,
    dotOutput :: !(Maybe FilePath),
    output :: !(Maybe FilePath),
    json :: !Bool
  }

data ProfileOptions = ProfileOptions
  { scenario :: !Text,
    modeName :: !Text,
    classes :: !String,
    breakdown :: !Char,
    intervalSeconds :: !Double,
    eventlogMaxBytes :: !Word64,
    worker :: !(Maybe Text),
    outputRoot :: !FilePath,
    knobs :: ![String],
    dimensions :: ![String]
  }

diagnoseCommand :: CliCommand
diagnoseCommand = CliCommand "diagnose" "Diagnose leaks, stalls, and profiles" Analysis False (runDiagnose <$> diagnoseParser)

diagnoseParser :: Parser DiagnoseOptions
diagnoseParser = hsubparser (command "leak" (info (DiagnoseLeak <$> leakParser) (progDesc "Re-judge sampled series for resource leaks")) <> command "stall" (info (DiagnoseStall <$> stallParser) (progDesc "Render or capture a concurrency stall")) <> command "profile" (info (DiagnoseProfile <$> profileParser) (progDesc "Run a scenario under heap or event-log profiling")))

leakParser :: Parser LeakOptions
leakParser =
  LeakOptions
    <$> strArgument (metavar "RUN_DIR")
    <*> optional (parseInputSource <$> strOption (long "policy" <> metavar "FILE" <> help "Leak policy file, or - for stdin"))
    <*> option auto (long "seed" <> metavar "N" <> value 0 <> showDefault)
    <*> optional (strOption (long "out" <> metavar "FILE"))
    <*> switch (long "json")

stallParser :: Parser StallOptions
stallParser =
  StallOptions
    <$> optional (strArgument (metavar "RUN_DIR"))
    <*> switch (long "live" <> help "Capture PostgreSQL and local threads now")
    <*> optional (Text.pack <$> strOption (long "connection" <> metavar "CONNECTION"))
    <*> switch (long "reclassify")
    <*> optional (strOption (long "dot" <> metavar "FILE"))
    <*> optional (strOption (long "out" <> metavar "FILE"))
    <*> switch (long "json")

profileParser :: Parser ProfileOptions
profileParser =
  ProfileOptions
    <$> (Text.pack <$> strArgument (metavar "SCENARIO"))
    <*> (Text.pack <$> strOption (long "mode" <> metavar "closure-type|info-table|eventlog|profiled"))
    <*> strOption (long "classes" <> metavar "CLASSES" <> value "gu" <> showDefault)
    <*> option (eitherReader parseBreakdown) (long "breakdown" <> metavar "c|r|d|y" <> value 'c' <> showDefault)
    <*> option auto (long "interval-s" <> metavar "SECONDS" <> value 10 <> showDefault)
    <*> option auto (long "eventlog-max-bytes" <> metavar "BYTES" <> value 536870912 <> showDefault)
    <*> optional (Text.pack <$> strOption (long "worker" <> metavar "ROLE"))
    <*> strOption (long "out" <> metavar "DIR" <> value ".dev/profiles" <> showDefault)
    <*> many (strOption (long "set" <> metavar "NAME=VALUE"))
    <*> many (strOption (long "dim" <> metavar "NAME=VALUE"))

runDiagnose :: DiagnoseOptions -> CliEnv -> IO ExitCode
runDiagnose (DiagnoseLeak options) _ = runLeak options
runDiagnose (DiagnoseStall options) _ = runStall options
runDiagnose (DiagnoseProfile options) _ = runProfile options

runLeak :: LeakOptions -> IO ExitCode
runLeak options = do
  attempted <- try @SomeException do
    spec <- loadPolicy options.policy
    analyseRunDirectory options.runDirectory spec options.seed
  case attempted of
    Left err -> diagnostic "leak" (Text.pack (displayException err)) >> pure (ExitFailure 4)
    Right (Left err) -> diagnostic "leak" (Text.pack (show err)) >> pure (ExitFailure 4)
    Right (Right report) -> do
      now <- getCurrentTime
      let document = Diagnosis LeakDiagnosis (Text.pack (takeFileName options.runDirectory)) "offline" now (Generator "kenshou-diagnose" "0.1.0.0" "theil-sen+moving-block-bootstrap/1") (toJSON report)
      emit options.json options.output document (renderLeakReport report)
      pure case report.verdict of
        Stable -> ExitSuccess
        LeakSuspected -> ExitFailure 1
        InsufficientData -> ExitFailure 3

loadPolicy :: Maybe InputSource -> IO LeakSpec
loadPolicy Nothing = pure defaultLeakSpec
loadPolicy (Just source) = do
  bytes <- readInputSource source
  either (ioError . userError) pure (eitherDecodeStrict' bytes)

runStall :: StallOptions -> IO ExitCode
runStall options
  | options.live = runLiveStall options
  | otherwise = case options.runDirectory of
      Nothing -> diagnostic "stall" "provide RUN_DIR, or use --live --connection CONNECTION" >> pure (ExitFailure 2)
      Just runDirectory -> do
        attempted <- try @SomeException (loadStallReports runDirectory)
        case attempted of
          Left err -> diagnostic "stall" (Text.pack (displayException err)) >> pure (ExitFailure 4)
          Right reports -> do
            let rendered = fmap (if options.reclassify then reclassified else id) reports
            traverse_ (writeDot options.dotOutput) (take 1 rendered)
            if null rendered
              then Text.IO.putStrLn "no stall diagnoses" >> pure ExitSuccess
              else do
                now <- getCurrentTime
                let body = toJSON rendered
                    document = Diagnosis StallDiagnosis (Text.pack (takeFileName runDirectory)) "offline" now (Generator "kenshou-diagnose" "0.1.0.0" "stall-render-v1") body
                emit options.json options.output document (Text.intercalate "\n" (fmap renderStallReport rendered))
                pure (ExitFailure 1)

runLiveStall :: StallOptions -> IO ExitCode
runLiveStall options = case options.connection of
  Nothing -> diagnostic "stall" "--live requires --connection CONNECTION" >> pure (ExitFailure 2)
  Just connectionString -> do
    attempted <- try @SomeException $ bracket (acquire connectionString) Connection.release \connection -> do
      postgres <- capturePostgres connection 2
      threads <- dumpThreads False
      now <- getCurrentTime
      let graph = buildGraph postgres.activity postgres.locks
          snapshot = StallSnapshot 0 [] threads (Just postgres) graph [] Null (SpinEvidence 0 (maybe 0 (.callsPerSecond) postgres.statementRate))
          (primary, secondary, reasons) = classify snapshot
      pure (StallReport now 1 primary secondary reasons snapshot)
    case attempted of
      Left err -> diagnostic "stall" (Text.pack (displayException err)) >> pure (ExitFailure 4)
      Right report -> do
        writeDot options.dotOutput report
        let document = Diagnosis StallDiagnosis "live" "live" report.detectedAt (Generator "kenshou-diagnose" "0.1.0.0" "live-stall-v1") (toJSON report)
        emit options.json options.output document (renderStallReport report)
        pure if report.classification == Unknown then ExitSuccess else ExitFailure 1

acquire :: Text -> IO Connection.Connection
acquire connectionString = Connection.acquire (Settings.connectionString connectionString <> Settings.applicationName "kenshou-diagnose-live") >>= either (ioError . userError . show) pure

loadStallReports :: FilePath -> IO [StallReport]
loadStallReports runDirectory = do
  exists <- doesDirectoryExist runDirectory
  if not exists then ioError (userError ("run directory does not exist: " <> runDirectory)) else pure ()
  let diagnosisDirectory = runDirectory </> "diagnosis"
  diagnosisExists <- doesDirectoryExist diagnosisDirectory
  if not diagnosisExists
    then pure []
    else do
      names <- sort <$> listDirectory diagnosisDirectory
      traverse (loadOne . (diagnosisDirectory </>)) [name | name <- names, "stall-" `isPrefixOf` name, ".json" `isSuffixOf` name]
  where
    loadOne path = do
      decoded <- eitherDecodeFileStrict' path :: IO (Either String Diagnosis)
      document <- either (ioError . userError) pure decoded
      case fromJSON document.body of
        Error err -> ioError (userError (path <> ": " <> err))
        Success report -> pure report

reclassified :: StallReport -> StallReport
reclassified report =
  let (primary, secondary, reasons) = classify report.snapshot
   in StallReport report.detectedAt report.captureNumber primary secondary reasons report.snapshot

writeDot :: Maybe FilePath -> StallReport -> IO ()
writeDot Nothing _ = pure ()
writeDot (Just path) report = Text.IO.writeFile path (renderDot report.snapshot.graph)

runProfile :: ProfileOptions -> IO ExitCode
runProfile options = case parseMode options of
  Left message -> diagnostic "profile" message >> pure (ExitFailure 2)
  Right mode -> do
    let arguments = concatMap (\assignment -> ["--set", assignment]) options.knobs <> concatMap (\assignment -> ["--dim", assignment]) options.dimensions
        request = ProfileRequest mode options.scenario arguments options.outputRoot options.intervalSeconds options.eventlogMaxBytes options.worker
    attempted <- try @SomeException (runProfileSession request >>= postprocessProfile)
    case attempted of
      Left err -> diagnostic "profile" (Text.pack (displayException err)) >> pure (ExitFailure 4)
      Right report -> Text.IO.putStr (renderProfileReport report) >> pure (toExitCode report.exitCode)

postprocessProfile :: ProfileReport -> IO ProfileReport
postprocessProfile report = do
  let tool = ".dev/bin/eventlog2html"
      eventlog = report.sessionDirectory </> "kenshou.eventlog"
  available <- doesFileExist tool
  eventlogExists <- doesFileExist eventlog
  if available && eventlogExists then callProcess tool [eventlog] else pure ()
  pure report

parseMode :: ProfileOptions -> Either Text ProfileMode
parseMode options = case options.modeName of
  "closure-type" -> Right ClosureType
  "info-table" -> Right InfoTable
  "eventlog" -> Right (Eventlog options.classes)
  "profiled" -> Right (Profiled options.breakdown)
  other -> Left ("unknown profile mode " <> other)

parseBreakdown :: String -> Either String Char
parseBreakdown [breakdown] | breakdown `elem` ("crdy" :: String) = Right breakdown
parseBreakdown _ = Left "breakdown must be c, r, d, or y"

emit :: (ToJSON value) => Bool -> Maybe FilePath -> value -> Text -> IO ()
emit json output document rendered = do
  let bytes = encode document <> "\n"
  traverse_ (\path -> LazyByteString.writeFile path bytes) output
  case (json, output) of
    (True, Nothing) -> LazyByteString.putStr bytes
    (True, Just _) -> pure ()
    (False, _) -> Text.IO.putStr rendered

diagnostic :: Text -> Text -> IO ()
diagnostic commandName message = Text.IO.hPutStrLn stderr ("kenshou diagnose " <> commandName <> ": " <> message)

toExitCode :: Int -> ExitCode
toExitCode 0 = ExitSuccess
toExitCode code = ExitFailure code
