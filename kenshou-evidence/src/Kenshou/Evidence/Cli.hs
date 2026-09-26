module Kenshou.Evidence.Cli (recordCommand, attestCommand, attestCommandWith, evidenceCommand) where

import Control.Exception (IOException, try)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Cli (CliCommand (..), CliEnv, CliGroup (Evidence))
import Kenshou.Core.Cli.Config (ConfigInputs (..), configInputsParser)
import Kenshou.Evidence.Attest (AttestError (..), AttestOptions (..), AttestResult (..), Recomputer, attest, coreRecomputers)
import Kenshou.Evidence.Bundle (BundleWriteError (..))
import Kenshou.Evidence.Check (CheckError (..), CheckOptions (..), Finding (..), checkBundleWithStore)
import Kenshou.Evidence.Config (EvidenceDefaults (..), bundleRootKey, dataBaseUriKey, evidenceConfig, projectKey, resolveEvidenceDefaults)
import Kenshou.Evidence.Publish (PublishError (..), UploadMode (..))
import Kenshou.Evidence.Record (RecordError (..), RecordOptions (..), RecordOutcome (..), recordComparison, recordRun)
import Kenshou.Evidence.Source (SourceError (..))
import Kenshou.Evidence.Store (ObjectStore, StoreError (..), directoryStore, gcloudStore)
import Kenshou.Evidence.Types (Purpose (..), SubjectKind (..))
import Options.Applicative
import Settei (ResolveResult (..), describe, renderErrorsText)
import Settei.Env (envSnapshot)
import Settei.Optparse (namedOption, resolutionDiagnostic, schemaDiagnostic)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, makeRelative, splitDirectories)
import System.IO (hIsTerminalDevice, stderr, stdin)
import System.Process (readProcess)

data RecordCli = RecordCli
  { runDirectory :: !(Maybe FilePath),
    comparisonFile :: !(Maybe FilePath),
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
recordCommand = CliCommand "record" "Publish a finished run or comparison as an OKF evidence record" Evidence False (recordHandler <$> recordParser)

attestCommand :: CliCommand
attestCommand = attestCommandWith coreRecomputers

attestCommandWith :: [Recomputer] -> CliCommand
attestCommandWith recomputers = CliCommand "attest" "Verify a recorded run and append an attestation" Evidence False (attestHandler recomputers <$> attestParser)

data AttestCli = AttestCli
  { target :: !Text,
    config :: !ConfigInputs,
    storeRoot :: !(Maybe FilePath),
    offline :: !Bool,
    linkedOnly :: !Bool,
    acceptAnomaly :: !Bool,
    authority :: !(Maybe Text),
    reason :: !(Maybe Text),
    json :: !Bool
  }

attestParser :: Parser AttestCli
attestParser =
  AttestCli
    <$> parserOptionGroup "Attestation target" (Text.pack <$> strArgument (metavar "RUN-RECORD-OR-ID" <> help "Bundle path or run ID of a recorded run concept"))
    <*> configInputsParser
      ( (\bundle project -> [bundle, project])
          <$> namedOption "--bundle" bundleRootKey (long "bundle" <> metavar "DIR" <> help "OKF evidence bundle")
          <*> namedOption "--project" projectKey (long "project" <> metavar "PROJECT" <> help "GCP project for object retrieval")
      )
    <*> parserOptionGroup "Attestation source" (optional (strOption (long "store-root" <> metavar "DIR" <> internal <> help "Scratch object store")))
    <*> parserOptionGroup "Verification" (switch (long "offline" <> help "Skip revision resolution requiring network"))
    <*> parserOptionGroup "Verification" (switch (long "linked-only" <> help "Fetch linked objects without manifest expansion"))
    <*> parserOptionGroup "Human exception" (switch (long "accept-anomaly" <> help "Record a human acceptance without changing the computed verdict"))
    <*> parserOptionGroup "Human exception" (optional (Text.pack <$> strOption (long "authority" <> metavar "human:ID" <> help "Human accepting the anomaly")))
    <*> parserOptionGroup "Human exception" (optional (Text.pack <$> strOption (long "reason" <> metavar "TEXT" <> help "Reason for accepting the anomaly")))
    <*> parserOptionGroup "Output" (switch (long "json" <> help "Emit one JSON attestation result"))

attestHandler :: [Recomputer] -> AttestCli -> CliEnv -> IO ExitCode
attestHandler recomputers options _
  | Just output <- schemaDiagnostic options.config.diagnostic (describe evidenceConfig) = Text.IO.putStr output >> pure ExitSuccess
  | otherwise = do
      processEnvironment <- fmap (fmap (\(name, setting) -> (Text.pack name, Text.pack setting))) getEnvironment
      resolved <- resolveEvidenceDefaults (envSnapshot processEnvironment) options.config
      case resolved of
        Left message -> attestResponse options.json 2 message Nothing
        Right result -> case result.answer of
          Left problems -> attestResponse options.json 2 (renderErrorsText problems) Nothing
          Right defaults -> case resolutionDiagnostic options.config.diagnostic result of
            Just output -> Text.IO.putStr output >> pure ExitSuccess
            Nothing -> do
              acceptance <- validateAnomaly options
              case acceptance of
                Left message -> attestResponse options.json 2 message Nothing
                Right accepted -> do
                  selected <- case options.storeRoot of
                    Just root -> do
                      allowed <- scratchBundleOutsideRepo (Text.unpack defaults.bundleRoot)
                      pure $ if allowed then Right (directoryStore root) else Left "--store-root requires --bundle outside this repository"
                    Nothing -> pure $ case defaults.project of
                      Just project | not (Text.null project) -> Right (gcloudStore project)
                      _ -> Left "--project is required for GCS storage"
                  case selected of
                    Left message -> attestResponse options.json 2 message Nothing
                    Right store -> do
                      attested <- attest store recomputers (AttestOptions (Text.unpack defaults.bundleRoot) options.offline options.linkedOnly accepted) options.target
                      case attested of
                        Left err -> attestResponse options.json (attestExitCode err) (Text.pack (show err)) Nothing
                        Right observed -> attestResponse options.json (case observed.verdict of "confirmed" -> 0; "refuted" -> 1; _ -> 3) observed.verdict (Just observed.path)

validateAnomaly :: AttestCli -> IO (Either Text (Maybe (Text, Text)))
validateAnomaly options
  | not options.acceptAnomaly =
      pure $
        if options.authority == Nothing && options.reason == Nothing
          then Right Nothing
          else Left "--authority and --reason require --accept-anomaly"
  | otherwise = do
      ci <- lookupEnv "CI"
      terminal <- hIsTerminalDevice stdin
      pure $
        if ci /= Nothing || not terminal
          then Left "--accept-anomaly requires an interactive terminal outside CI"
          else case (options.authority, options.reason) of
            (Just authority, Just reason)
              | Just identifier <- Text.stripPrefix "human:" authority,
                not (Text.null identifier),
                not (Text.null (Text.strip reason)) ->
                  Right (Just (authority, reason))
            _ -> Left "--accept-anomaly requires --authority human:ID and a nonempty --reason"

attestExitCode :: AttestError -> Int
attestExitCode = \case
  InvalidTarget _ -> 2
  AttestIo _ -> 4
  AttestBundle _ -> 1

attestResponse :: Bool -> Int -> Text -> Maybe FilePath -> IO ExitCode
attestResponse machine code message path = do
  if machine
    then LazyByteString.putStrLn (encode (object (["schema" .= ("kenshou.attest-result/v1" :: Text), "status" .= (if path == Nothing then "error" else message), "message" .= message, "exitCode" .= code] <> maybe [] (\item -> ["path" .= item]) path)))
    else case path of
      Just item -> Text.IO.putStrLn (message <> ": " <> Text.pack item)
      Nothing -> Text.IO.hPutStrLn stderr ("kenshou attest: " <> message)
  pure $ if code == 0 then ExitSuccess else ExitFailure code

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
    <$> parserOptionGroup "Record source" (optional (strArgument (metavar "RUN-DIR" <> help "Finished kenshou run directory")))
    <*> parserOptionGroup "Record source" (optional (strOption (long "comparison" <> metavar "FILE" <> help "Finished kenshou comparison document")))
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
  | (options.runDirectory == Nothing) == (options.comparisonFile == Nothing) = respond options.json 2 "provide exactly one RUN-DIR or --comparison FILE" Nothing
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
                    recorded <- case (options.runDirectory, options.comparisonFile) of
                      (Just directory, Nothing) -> recordRun store recordOptions directory
                      (Nothing, Just file) -> recordComparison store recordOptions file
                      _ -> pure (Left (RecordError "provide exactly one RUN-DIR or --comparison FILE"))
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
