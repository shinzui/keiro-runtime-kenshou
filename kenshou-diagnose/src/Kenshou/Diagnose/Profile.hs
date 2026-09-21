module Kenshou.Diagnose.Profile
  ( ProfileMode (..),
    ProfileRequest (..),
    ProfileReport (..),
    rtsFlags,
    runProfileSession,
    reexecWithWorkerRts,
    markPhase,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (Exception, throwIO)
import Data.Aeson (ToJSON (..), object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAlphaNum, toUpper)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Word (Word64)
import Debug.Trace (traceMarkerIO)
import Kenshou.Diagnose.Document (Diagnosis (..), DiagnosisKind (ProfileDiagnosis), Generator (..), encodeDiagnosis)
import System.Directory
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.Posix.Process (executeFile, getProcessID)
import System.Process
import Text.Read (readMaybe)

data ProfileMode = ClosureType | InfoTable | Eventlog ![Char] | Profiled !Char
  deriving stock (Eq, Show)

data ProfileRequest = ProfileRequest
  { mode :: !ProfileMode,
    scenario :: !Text,
    runArgs :: ![String],
    sessionRoot :: !FilePath,
    censusIntervalSeconds :: !Double,
    eventlogMaxBytes :: !Word64,
    workerRole :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data ProfileReport = ProfileReport
  { sessionDirectory :: !FilePath,
    mode :: !ProfileMode,
    variant :: !Text,
    flags :: ![String],
    binary :: !FilePath,
    runDirectory :: !(Maybe FilePath),
    manifestSha256 :: !(Maybe Text),
    eventlogBytes :: !Word64,
    truncated :: !Bool,
    exitCode :: !Int
  }
  deriving stock (Eq, Show)

newtype ProfileError = ProfileError Text deriving stock (Show)

instance Exception ProfileError

rtsFlags :: ProfileMode -> FilePath -> Double -> [String]
rtsFlags mode eventlog interval = profileFlags <> [eventFlags, "-ol" <> eventlog, "--eventlog-flush-interval=5"]
  where
    profileFlags = case mode of
      ClosureType -> ["-hT", "-i" <> show interval]
      InfoTable -> ["-hi", "-i" <> show interval]
      Eventlog _ -> []
      Profiled breakdown -> ["-h" <> [breakdown], "-i" <> show interval]
    eventFlags = case mode of
      Eventlog classes -> "-l-a" <> if null classes then "gu" else classes
      _ -> "-l-agu"

runProfileSession :: ProfileRequest -> IO ProfileReport
runProfileSession request = do
  now <- getCurrentTime
  let session = request.sessionRoot </> ("profile-" <> formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now <> "-" <> modeSlug request.mode)
      eventlog = session </> "kenshou.eventlog"
      flags = rtsFlags request.mode eventlog request.censusIntervalSeconds
      variant = variantName request.mode
  createDirectoryIfMissing True session
  ensureDiskSpace session request.eventlogMaxBytes
  binary <- locateBinary request.mode
  baseEnvironment <- getEnvironment
  let profileEnvironment = case request.workerRole of
        Nothing -> [("KENSHOU_EVENTLOG_PATH", eventlog), ("KENSHOU_EVENTLOG_MAX_BYTES", show request.eventlogMaxBytes)]
        Just role -> workerVariables session request.eventlogMaxBytes flags role
      environment = replaceEnvironment profileEnvironment baseEnvironment
      mainRts = if request.workerRole == Nothing then ["+RTS"] <> flags <> ["-RTS"] else []
      arguments = ["run", Text.unpack request.scenario, "--out", session </> "run"] <> request.runArgs <> mainRts
  (_, _, _, process) <- createProcess (proc binary arguments) {env = Just environment}
  outcome <- race (waitForProcess process) (watchBackstop eventlog request.eventlogMaxBytes)
  (code, parentTruncated) <- case outcome of
    Left code -> pure (code, False)
    Right () -> terminateProcess process >> (,True) <$> waitForProcess process
  truncatedByChild <- doesFileExist (eventlog <> ".truncated")
  bytes <- fileBytes eventlog
  runDirectory <- findRunDirectory (session </> "run")
  manifestSha256 <- traverse hashManifest runDirectory
  let report = ProfileReport session request.mode variant flags binary runDirectory manifestSha256 bytes (parentTruncated || truncatedByChild) (exitCodeNumber code)
      runId = maybe "" (Text.pack . takeFileName) runDirectory
      document = Diagnosis ProfileDiagnosis runId request.scenario now (Generator "kenshou-diagnose" "0.1.0.0" "profile-session-v1") (toJSON report)
  LazyByteString.writeFile (session </> "profile.json") (encodeDiagnosis document)
  pure report

locateBinary :: ProfileMode -> IO FilePath
locateBinary mode = do
  let (arguments, buildCommand) = case mode of
        InfoTable -> (["--project-file=cabal.diagnose-info-table.project", "--builddir=dist-diagnose/info-table", "list-bin", "kenshou-cli:exe:kenshou"], "just diagnose-build-info-table")
        Profiled _ -> (["--project-file=cabal.diagnose-profiled.project", "--builddir=dist-diagnose/profiled", "list-bin", "kenshou-cli:exe:kenshou"], "just diagnose-build-profiled")
        _ -> (["list-bin", "kenshou-cli:exe:kenshou"], "cabal build kenshou-cli:exe:kenshou")
  (code, output, err) <- readProcessWithExitCode "cabal" arguments ""
  case code of
    ExitSuccess -> pure (trim output)
    _ -> throwIO (ProfileError ("profiling binary is unavailable; run `" <> buildCommand <> "`: " <> Text.pack err))

ensureDiskSpace :: FilePath -> Word64 -> IO ()
ensureDiskSpace path limit = do
  (code, output, err) <- readProcessWithExitCode "df" ["-Pk", path] ""
  case code of
    ExitSuccess -> case reverse (lines output) of
      row : _ -> case words row of
        _filesystem : _blocks : _used : available : _ -> case readMaybe available :: Maybe Integer of
          Just availableKiB | availableKiB * 1024 >= fromIntegral limit * 4 -> pure ()
          _ -> throwIO (ProfileError "profiling requires free disk space of at least four times the event-log limit")
        _ -> throwIO (ProfileError "unable to parse df output")
      [] -> throwIO (ProfileError "df returned no output")
    _ -> throwIO (ProfileError ("unable to inspect free disk space: " <> Text.pack err))

watchBackstop :: FilePath -> Word64 -> IO ()
watchBackstop path limit = do
  bytes <- fileBytes path
  if bytes >= limit * 2 then pure () else threadDelay 1_000_000 >> watchBackstop path limit

reexecWithWorkerRts :: Text -> IO ()
reexecWithWorkerRts role = do
  let variable = workerVariable role
  flags <- lookupEnv variable
  inherited <- lookupEnv "GHCRTS"
  directory <- lookupEnv "KENSHOU_WORKER_EVENTLOG_DIR"
  case (flags, inherited, directory) of
    (Just rawFlags, Nothing, Just eventlogDirectory) -> do
      executable <- getExecutablePath
      arguments <- getArgs
      environment <- getEnvironment
      pid <- getProcessID
      let eventlog = eventlogDirectory </> ("worker-" <> Text.unpack role <> "-" <> show pid <> ".eventlog")
          ghcRts = unwords [rawFlags, "-ol" <> eventlog]
          replacements = [("GHCRTS", ghcRts), ("KENSHOU_EVENTLOG_PATH", eventlog)]
          cleaned = filter ((`notElem` [variable, "KENSHOU_WORKER_EVENTLOG_DIR"]) . fst) environment
      executeFile executable False arguments (Just (replaceEnvironment replacements cleaned))
    _ -> pure ()

markPhase :: Text -> IO ()
markPhase = traceMarkerIO . Text.unpack . ("kenshou.phase:" <>)

workerVariables :: FilePath -> Word64 -> [String] -> Text -> [(String, String)]
workerVariables session limit flags role =
  [ (workerVariable role, unwords (filter (not . isPrefixOf "-ol") flags)),
    ("KENSHOU_WORKER_EVENTLOG_DIR", session),
    ("KENSHOU_EVENTLOG_MAX_BYTES", show limit)
  ]

workerVariable :: Text -> String
workerVariable role = "KENSHOU_WORKER_GHCRTS_" <> fmap normalize (Text.unpack role)
  where
    normalize character | isAlphaNum character = toUpper character
    normalize _ = '_'

variantName :: ProfileMode -> Text
variantName InfoTable = "info-table"
variantName (Profiled _) = "profiled"
variantName _ = "ordinary"

modeSlug :: ProfileMode -> String
modeSlug ClosureType = "closure-type"
modeSlug InfoTable = "info-table"
modeSlug (Eventlog _) = "eventlog"
modeSlug (Profiled _) = "profiled"

fileBytes :: FilePath -> IO Word64
fileBytes path = do
  exists <- doesFileExist path
  if exists then fromIntegral <$> getFileSize path else pure 0

findRunDirectory :: FilePath -> IO (Maybe FilePath)
findRunDirectory root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure Nothing
    else do
      entries <- listDirectory root
      findM (doesFileExist . (</> "manifest.json")) [root </> entry | entry <- entries]

hashManifest :: FilePath -> IO Text
hashManifest runDirectory = do
  (code, output, err) <- readProcessWithExitCode "shasum" ["-a", "256", runDirectory </> "manifest.json"] ""
  case (code, words output) of
    (ExitSuccess, digest : _) -> pure (Text.pack digest)
    _ -> throwIO (ProfileError ("unable to hash run manifest: " <> Text.pack err))

replaceEnvironment :: [(String, String)] -> [(String, String)] -> [(String, String)]
replaceEnvironment replacements original = replacements <> filter ((`notElem` fmap fst replacements) . fst) original

findM :: (value -> IO Bool) -> [value] -> IO (Maybe value)
findM _ [] = pure Nothing
findM predicate (value : rest) = predicate value >>= \matches -> if matches then pure (Just value) else findM predicate rest

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ']) . reverse

exitCodeNumber :: ExitCode -> Int
exitCodeNumber ExitSuccess = 0
exitCodeNumber (ExitFailure code) = code

instance ToJSON ProfileMode where
  toJSON mode = case mode of
    ClosureType -> object ["name" .= ("closure-type" :: Text)]
    InfoTable -> object ["name" .= ("info-table" :: Text)]
    Eventlog classes -> object ["name" .= ("eventlog" :: Text), "classes" .= classes]
    Profiled breakdown -> object ["name" .= ("profiled" :: Text), "breakdown" .= [breakdown]]

instance ToJSON ProfileReport where
  toJSON report = object ["schema" .= ("kenshou.profile/v1" :: Text), "sessionDirectory" .= report.sessionDirectory, "mode" .= report.mode, "variant" .= report.variant, "flags" .= report.flags, "binary" .= report.binary, "runDirectory" .= report.runDirectory, "manifestSha256" .= report.manifestSha256, "eventlogBytes" .= report.eventlogBytes, "truncated" .= report.truncated, "exitCode" .= report.exitCode]
