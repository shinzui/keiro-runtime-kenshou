module Kenshou.Evidence.Cli (recordCommand, evidenceCommand) where

import Control.Exception (IOException, try)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Cli (CliCommand (..), CliEnv, CliGroup (Evidence))
import Kenshou.Core.Cli.Config (ConfigInputs (..), configInputsParser)
import Kenshou.Evidence.Bundle (BundleWriteError (..))
import Kenshou.Evidence.Check (CheckError (..), CheckOptions (..), Finding (..), checkBundleWithStore)
import Kenshou.Evidence.Config (EvidenceDefaults (..), bundleRootKey, dataBaseUriKey, evidenceConfig, projectKey, resolveEvidenceDefaults)
import Kenshou.Evidence.Publish (PublishError (..), UploadMode (..))
import Kenshou.Evidence.Record (RecordError (..), RecordOptions (..), RecordOutcome (..), recordRun)
import Kenshou.Evidence.Source (SourceError (..))
import Kenshou.Evidence.Store (ObjectStore, StoreError (..), directoryStore, gcloudStore)
import Kenshou.Evidence.Types (Purpose (..), SubjectKind (..))
import Options.Applicative
import Settei (ResolveResult (..), describe, renderErrorsText)
import Settei.Env (envSnapshot)
import Settei.Optparse (namedOption, resolutionDiagnostic, schemaDiagnostic)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, makeRelative, splitDirectories)
import System.IO (stderr)
import System.Process (readProcess)

data RecordCli = RecordCli
  { runDirectory :: !FilePath,
    config :: !ConfigInputs,
    purpose :: !Purpose,
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
  { config :: !ConfigInputs,
    baseRef :: !(Maybe Text),
    network :: !Bool,
    deep :: !Bool,
    json :: !Bool
  }

checkParser :: Parser CheckCli
checkParser =
  CheckCli
    <$> configInputsParser
      ( (\bundle project -> [bundle, project])
          <$> namedOption "--bundle" bundleRootKey (long "bundle" <> metavar "DIR" <> help "OKF evidence bundle")
          <*> namedOption "--project" projectKey (long "project" <> metavar "PROJECT" <> help "GCP project for --network")
      )
    <*> parserOptionGroup "History scope" (optional (Text.pack <$> strOption (long "base" <> metavar "GIT-REF" <> help "Check committed changes from this base through HEAD")))
    <*> parserOptionGroup "Verification" (switch (long "network" <> help "Check recorded objects in GCS"))
    <*> parserOptionGroup "Verification" (switch (long "deep" <> help "Download objects and verify SHA-256"))
    <*> parserOptionGroup "Output" (switch (long "json" <> help "Emit one JSON result document"))

checkHandler :: CheckCli -> CliEnv -> IO ExitCode
checkHandler options _
  | options.deep && not options.network = checkResponse options.json 2 "--deep requires --network" []
  | Just output <- schemaDiagnostic options.config.diagnostic (describe evidenceConfig) = Text.IO.putStr output >> pure ExitSuccess
  | otherwise = do
      processEnvironment <- fmap (fmap (\(name, setting) -> (Text.pack name, Text.pack setting))) getEnvironment
      resolved <- resolveEvidenceDefaults (envSnapshot processEnvironment) options.config
      case resolved of
        Left message -> checkResponse options.json 2 message []
        Right result -> case result.answer of
          Left problems -> checkResponse options.json 2 (renderErrorsText problems) []
          Right defaults -> case resolutionDiagnostic options.config.diagnostic result of
            Just output -> Text.IO.putStr output >> pure ExitSuccess
            Nothing -> case (options.network, defaults.project) of
              (True, Nothing) -> checkResponse options.json 2 "--network requires --project or gcp.project" []
              _ -> do
                let store = if options.network then gcloudStore <$> defaults.project else Nothing
                checked <- checkBundleWithStore store (CheckOptions (Text.unpack defaults.bundleRoot) options.baseRef options.network options.deep)
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
    <*> configInputsParser
      ( (\bundle project baseUri -> [bundle, project, baseUri])
          <$> namedOption "--bundle" bundleRootKey (long "bundle" <> metavar "DIR" <> help "OKF evidence bundle")
          <*> namedOption "--project" projectKey (long "project" <> metavar "PROJECT" <> help "Explicit GCP project")
          <*> namedOption "--data-base-uri" dataBaseUriKey (long "data-base-uri" <> metavar "gs://BUCKET/PREFIX" <> help "Durable object prefix")
      )
    <*> parserOptionGroup "Evidence destination" (option (eitherReader parsePurpose) (long "purpose" <> metavar "nightly|release|baseline|investigation" <> help "Why this run is recorded"))
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
  | Just output <- schemaDiagnostic options.config.diagnostic (describe evidenceConfig) = Text.IO.putStr output >> pure ExitSuccess
  | otherwise = do
      processEnvironment <- fmap (fmap (\(name, value) -> (Text.pack name, Text.pack value))) getEnvironment
      resolved <- resolveEvidenceDefaults (envSnapshot processEnvironment) options.config
      case resolved of
        Left message -> respond options.json 2 message Nothing
        Right result -> case result.answer of
          Left problems -> respond options.json 2 (renderErrorsText problems) Nothing
          Right defaults -> case resolutionDiagnostic options.config.diagnostic result of
            Just output -> Text.IO.putStr output >> pure ExitSuccess
            Nothing -> case defaults.dataBaseUri of
              Nothing -> respond options.json 2 "--data-base-uri or evidence.data-base-uri is required" Nothing
              Just baseUri -> do
                selected <- selectStore options defaults
                case selected of
                  Left message -> respond options.json 2 message Nothing
                  Right store -> do
                    let mode = if options.verifyOnly then VerifyOnly else UploadMissing
                        recordOptions = RecordOptions (Text.unpack defaults.bundleRoot) baseUri options.purpose mode options.deepVerify options.allowDirty options.linkLogs ((,options.subjectKind) <$> options.subject) options.produced
                    recorded <- recordRun store recordOptions options.runDirectory
                    case recorded of
                      Left err -> respond options.json (recordExitCode err) (recordMessage err) Nothing
                      Right (Recorded path) -> respond options.json 0 "recorded" (Just path)
                      Right (AlreadyRecorded path) -> respond options.json 0 "already recorded" (Just path)

selectStore :: RecordCli -> EvidenceDefaults -> IO (Either Text ObjectStore)
selectStore options defaults = case options.storeRoot of
  Just root -> do
    allowed <- scratchBundleOutsideRepo (Text.unpack defaults.bundleRoot)
    pure $ if allowed then Right (directoryStore root) else Left "--store-root requires --bundle outside this repository"
  Nothing -> pure $ case defaults.project of
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
