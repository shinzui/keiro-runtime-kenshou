module Kenshou.Evidence.Cli (recordCommand, evidenceCommand) where

import Control.Exception (IOException, try)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Cli (CliCommand (..), CliEnv, CliGroup (Evidence))
import Kenshou.Evidence.Bundle (BundleWriteError (..))
import Kenshou.Evidence.Check (CheckError (..), CheckOptions (..), Finding (..), checkBundle)
import Kenshou.Evidence.Publish (PublishError (..), UploadMode (..))
import Kenshou.Evidence.Record (RecordError (..), RecordOptions (..), RecordOutcome (..), recordRun)
import Kenshou.Evidence.Source (SourceError (..))
import Kenshou.Evidence.Store (ObjectStore, StoreError (..), directoryStore, gcloudStore)
import Kenshou.Evidence.Types (Purpose (..), SubjectKind (..))
import Options.Applicative
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, makeRelative, splitDirectories)
import System.IO (stderr)
import System.Process (readProcess)

data RecordCli = RecordCli
  { runDirectory :: !FilePath,
    bundle :: !FilePath,
    baseUri :: !Text,
    purpose :: !Purpose,
    project :: !(Maybe Text),
    storeRoot :: !(Maybe FilePath),
    verifyOnly :: !Bool,
    deepVerify :: !Bool,
    allowDirty :: !Bool,
    linkLogs :: !Bool,
    subject :: !(Maybe Text),
    subjectKind :: !SubjectKind,
    produced :: ![Text],
    json :: !Bool
  }

recordCommand :: CliCommand
recordCommand = CliCommand "record" "Publish a finished run as an OKF evidence record" Evidence False (recordHandler <$> recordParser)

evidenceCommand :: CliCommand
evidenceCommand =
  CliCommand "evidence" "Check the historic OKF evidence bundle" Evidence False $
    hsubparser (command "check" (info (checkHandler <$> checkParser) (progDesc "Check record identity, local rules and immutability")))

data CheckCli = CheckCli
  { bundle :: !FilePath,
    baseRef :: !(Maybe Text),
    json :: !Bool
  }

checkParser :: Parser CheckCli
checkParser =
  CheckCli
    <$> parserOptionGroup "Bundle selection" (strOption (long "bundle" <> metavar "DIR" <> value "docs/verification" <> showDefault <> help "OKF evidence bundle"))
    <*> parserOptionGroup "History scope" (optional (Text.pack <$> strOption (long "base" <> metavar "GIT-REF" <> help "Check committed changes from this base through HEAD")))
    <*> parserOptionGroup "Output" (switch (long "json" <> help "Emit one JSON result document"))

checkHandler :: CheckCli -> CliEnv -> IO ExitCode
checkHandler options _ = do
  checked <- checkBundle (CheckOptions options.bundle options.baseRef)
  case checked of
    Left (CheckError message) -> checkResponse options.json 4 message []
    Right findings -> checkResponse options.json (if null findings then 0 else 1) (if null findings then "evidence clean" else "evidence findings") findings

checkResponse :: Bool -> Int -> Text -> [Finding] -> IO ExitCode
checkResponse machine code message findings = do
  if machine
    then LazyByteString.putStrLn (encode (object ["schema" .= ("kenshou.evidence-check/v1" :: Text), "status" .= (if code == 0 then "ok" else "error" :: Text), "message" .= message, "exitCode" .= code, "findings" .= map findingValue findings]))
    else
      if null findings
        then Text.IO.putStrLn message
        else mapM_ (Text.IO.hPutStrLn stderr . renderFinding) findings
  if code == 0
    then pure ExitSuccess
    else do
      if null findings then Text.IO.hPutStrLn stderr ("kenshou evidence check: " <> message) else pure ()
      pure (ExitFailure code)
  where
    findingValue finding = object ["concept" .= finding.concept, "rule" .= finding.rule, "message" .= finding.message]
    renderFinding finding = Text.pack finding.concept <> ": " <> finding.rule <> ": " <> finding.message

recordParser :: Parser RecordCli
recordParser =
  RecordCli
    <$> parserOptionGroup "Record source" (strArgument (metavar "RUN-DIR" <> help "Finished kenshou run directory"))
    <*> parserOptionGroup "Evidence destination" (strOption (long "bundle" <> metavar "DIR" <> value "docs/verification" <> showDefault <> help "OKF evidence bundle"))
    <*> parserOptionGroup "Evidence destination" (Text.pack <$> strOption (long "data-base-uri" <> metavar "gs://BUCKET/PREFIX" <> help "Durable object prefix"))
    <*> parserOptionGroup "Evidence destination" (option (eitherReader parsePurpose) (long "purpose" <> metavar "nightly|release|baseline|investigation" <> help "Why this run is recorded"))
    <*> parserOptionGroup "Evidence destination" (optional (Text.pack <$> strOption (long "project" <> metavar "PROJECT" <> help "Explicit GCP project")))
    <*> parserOptionGroup "Evidence destination" (optional (strOption (long "store-root" <> metavar "DIR" <> internal <> help "Scratch object store")))
    <*> parserOptionGroup "Verification" (switch (long "verify-only" <> help "Require every object to exist; upload none"))
    <*> parserOptionGroup "Verification" (switch (long "deep-verify" <> help "Download published objects and compare SHA-256"))
    <*> parserOptionGroup "Verification" (switch (long "allow-dirty" <> help "Record a dirty harness as investigation evidence"))
    <*> parserOptionGroup "Verification" (switch (long "link-logs" <> help "Link logs even for passing runs"))
    <*> parserOptionGroup "Record source" (optional (Text.pack <$> strOption (long "subject" <> metavar "MORI-URI" <> help "Canonical subject override")))
    <*> parserOptionGroup "Record source" (option (eitherReader parseSubjectKind) (long "subject-kind" <> metavar "project|package" <> value SubjectProject <> showDefaultWith (const "project") <> help "Kind of --subject"))
    <*> parserOptionGroup "Record source" (many (Text.pack <$> strOption (long "produced" <> metavar "MORI-URI" <> help "Report artifact produced by this run")))
    <*> parserOptionGroup "Output" (switch (long "json" <> help "Emit one JSON result document"))

recordHandler :: RecordCli -> CliEnv -> IO ExitCode
recordHandler options _
  | options.subject == Nothing && options.subjectKind == SubjectPackage = respond options.json 2 "--subject-kind package requires --subject" Nothing
  | otherwise = do
      selected <- selectStore options
      case selected of
        Left message -> respond options.json 2 message Nothing
        Right store -> do
          let mode = if options.verifyOnly then VerifyOnly else UploadMissing
              recordOptions = RecordOptions options.bundle options.baseUri options.purpose mode options.deepVerify options.allowDirty options.linkLogs ((,options.subjectKind) <$> options.subject) options.produced
          recorded <- recordRun store recordOptions options.runDirectory
          case recorded of
            Left err -> respond options.json (recordExitCode err) (recordMessage err) Nothing
            Right (Recorded path) -> respond options.json 0 "recorded" (Just path)
            Right (AlreadyRecorded path) -> respond options.json 0 "already recorded" (Just path)

selectStore :: RecordCli -> IO (Either Text ObjectStore)
selectStore options = case options.storeRoot of
  Just root -> do
    allowed <- scratchBundleOutsideRepo options.bundle
    pure $ if allowed then Right (directoryStore root) else Left "--store-root requires --bundle outside this repository"
  Nothing -> pure $ case options.project of
    Just project | not (Text.null project) -> Right (gcloudStore project)
    _ -> Left "--project is required for GCS storage"

scratchBundleOutsideRepo :: FilePath -> IO Bool
scratchBundleOutsideRepo bundle = do
  exists <- doesDirectoryExist bundle
  if not exists
    then pure False
    else do
      result <-
        try
          ( do
              repo <- Text.unpack . Text.strip . Text.pack <$> readProcess "git" ["rev-parse", "--show-toplevel"] ""
              repoPath <- canonicalizePath repo
              bundlePath <- canonicalizePath bundle
              let relative = makeRelative repoPath bundlePath
              pure $
                isAbsolute relative || case splitDirectories relative of
                  ".." : _ -> True
                  _ -> False
          ) ::
          IO (Either IOException Bool)
      pure (either (const False) id result)

respond :: Bool -> Int -> Text -> Maybe FilePath -> IO ExitCode
respond machine code message path = do
  if machine
    then LazyByteString.putStrLn (encode (object (["schema" .= ("kenshou.record-result/v1" :: Text), "status" .= (if code == 0 then "ok" else "error" :: Text), "message" .= message, "exitCode" .= code] <> maybe [] (\value -> ["path" .= value]) path)))
    else case path of
      Just value -> Text.IO.putStrLn (message <> ": " <> Text.pack value)
      Nothing -> pure ()
  if code == 0 then pure ExitSuccess else Text.IO.hPutStrLn stderr ("kenshou record: " <> message) >> pure (ExitFailure code)

recordExitCode :: RecordError -> Int
recordExitCode = \case
  RecordError _ -> 2
  SourceFailure _ -> 1
  PublishFailure err -> case err of
    InvalidBaseUri _ -> 2
    PublishIo _ -> 4
    StoreFailure (StoreIo _) -> 4
    StoreFailure _ -> 1
    MissingObject _ -> 1
    ObjectMismatch _ -> 1
  BundleFailure err -> case err of
    InvalidRecordIdentity _ -> 2
    RecordConflict _ -> 1
    BundleInvalid _ -> 1
    BundleIo _ -> 4

recordMessage :: RecordError -> Text
recordMessage = \case
  RecordError message -> message
  SourceFailure (SourceError message) -> message
  PublishFailure err -> Text.pack (show err)
  BundleFailure err -> Text.pack (show err)

parsePurpose :: String -> Either String Purpose
parsePurpose "nightly" = Right Nightly
parsePurpose "release" = Right Release
parsePurpose "baseline" = Right Baseline
parsePurpose "investigation" = Right Investigation
parsePurpose other = Left ("unknown purpose " <> other)

parseSubjectKind :: String -> Either String SubjectKind
parseSubjectKind "project" = Right SubjectProject
parseSubjectKind "package" = Right SubjectPackage
parseSubjectKind other = Left ("unknown subject kind " <> other)
