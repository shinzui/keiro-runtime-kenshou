module Kenshou.Evidence.Attest
  ( Recomputation (..),
    Recomputer (..),
    AttestOptions (..),
    AttestResult (..),
    AttestError (..),
    coreRecomputers,
    attest,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (find, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Kenshou.Core.Cohort (CohortIdentity (..), PlanHash (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Core.Id (newRunId, parseRunId, renderRunId, renderScenarioId)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Core.Outcome (Outcome (Passed))
import Kenshou.Core.RunSpec (CohortExpectation (..), RunSpec (..))
import Kenshou.Evidence.Bundle (BundleWriteError, BundleWriteResult (..), writeAttestationRecord)
import Kenshou.Evidence.Frontmatter (AttestationCheck (..), AttestationEvidence (..), EvidenceRecord (..), recordFromDocument)
import Kenshou.Evidence.Record (RecordInput (..), buildRunRecord)
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..), loadRunSource)
import Kenshou.Evidence.Store (ObjectStore (..))
import Kenshou.Evidence.Types (ComponentRef (..), ComponentSource (FromGit), DataKind (..), DataLink (..), Revision (..), Sha256 (..), mkRevision, sha256Bytes)
import Okf.Actor (Actor (ProcessActor))
import Okf.Document (OKFDocument (..), Verification (..), frontmatterLookup, parseDocument, readVerified, serializeDocument, setVerified)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, normalise, splitDirectories, takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

data Recomputation = Recomputation
  { agreesWithDocuments :: !Bool,
    outcome :: !(Maybe Outcome),
    comparisonVerdict :: !(Maybe Text),
    detail :: !Text
  }
  deriving stock (Eq, Show)

data Recomputer = Recomputer
  { algorithm :: !Text,
    algorithmVersion :: !Integer,
    recompute :: FilePath -> IO (Either Text Recomputation)
  }

data AttestOptions = AttestOptions
  { bundleRoot :: !FilePath,
    offline :: !Bool,
    linkedOnly :: !Bool,
    acceptedAnomaly :: !(Maybe (Text, Text))
  }
  deriving stock (Eq, Show)

data AttestResult = AttestResult
  { path :: !FilePath,
    verdict :: !Text
  }
  deriving stock (Eq, Show)

data AttestError
  = InvalidTarget !Text
  | AttestIo !Text
  | AttestBundle !BundleWriteError
  deriving stock (Eq, Show)

-- A generic run result does not contain enough information to replay its
-- scenario oracle. The fixed self-test is the one core scenario with an
-- independent outcome that can be derived from its identity alone.
coreRecomputers :: [Recomputer]
coreRecomputers = [selftestOutcomeRecomputer]

selftestOutcomeRecomputer :: Recomputer
selftestOutcomeRecomputer = Recomputer "run-outcome" 1 $ \root -> do
  loaded <- loadRunSource root
  pure case loaded of
    Left err -> Left (Text.pack (show err))
    Right source
      | renderScenarioId source.result.resultScenario == "selftest/kernel/correctness/always-pass" ->
          Right
            Recomputation
              { agreesWithDocuments = source.spec.scenario == source.result.resultScenario && source.result.resultOutcome == Passed,
                outcome = Just Passed,
                comparisonVerdict = Nothing,
                detail = "the fixed always-pass self-test independently requires a passed outcome"
              }
      | otherwise -> Left "no domain outcome oracle is registered for this scenario"

attest :: ObjectStore -> [Recomputer] -> AttestOptions -> Text -> IO (Either AttestError AttestResult)
attest store recomputers options rawTarget = do
  attempted <- try $ do
    resolved <- resolveTarget options.bundleRoot rawTarget
    case resolved of
      Left err -> pure (Left err)
      Right relative -> attestRun store recomputers options relative
  pure $ either (Left . AttestIo . Text.pack . show) id (attempted :: Either IOException (Either AttestError AttestResult))

resolveTarget :: FilePath -> Text -> IO (Either AttestError FilePath)
resolveTarget root rawTarget = do
  let relative = Text.unpack (Text.dropWhile (== '/') rawTarget)
      segments = splitDirectories relative
  if safeRelative relative && length segments == 5 && take 1 segments == ["runs"] && takeExtension relative == ".md"
    then pure (Right relative)
    else case parseRunId rawTarget of
      Left _ -> pure (Left (InvalidTarget "attestation target must be a run concept path or run ID"))
      Right _ -> do
        let runs = root </> "runs"
        layers <- ifMDirectory runs listDirectory
        matches <- fmap concat $ forM layers $ \layer -> do
          years <- ifMDirectory (runs </> layer) listDirectory
          fmap concat $ forM years $ \year -> do
            months <- ifMDirectory (runs </> layer </> year) listDirectory
            fmap concat $ forM months $ \month -> do
              let folder = runs </> layer </> year </> month
              names <- ifMDirectory folder listDirectory
              pure ["runs" </> layer </> year </> month </> name | name <- names, name == Text.unpack rawTarget <> ".md"]
        pure case matches of
          [path] -> Right path
          [] -> Left (InvalidTarget "run ID is not present in the evidence bundle")
          _ -> Left (InvalidTarget "run ID matches more than one run concept")

ifMDirectory :: FilePath -> (FilePath -> IO [FilePath]) -> IO [FilePath]
ifMDirectory path action = do
  exists <- doesDirectoryExist path
  if exists then action path else pure []

attestRun :: ObjectStore -> [Recomputer] -> AttestOptions -> FilePath -> IO (Either AttestError AttestResult)
attestRun store recomputers options relative = do
  content <- Text.IO.readFile (options.bundleRoot </> relative)
  let decoded = do
        document <- either (Left . Text.pack . show) Right (parseDocument content)
        either (Left . Text.pack . show) Right (recordFromDocument document)
  case decoded of
    Left err -> pure (Left (InvalidTarget err))
    Right record -> withSystemTempDirectory "kenshou-attest" $ \scratch -> do
      now <- getCurrentTime
      (digestCheck, matchedDigests, source) <- verifyData store options.linkedOnly scratch record
      if null matchedDigests
        then pure (Left (AttestIo "no linked object could be fetched and checked"))
        else do
          revision <- currentAttesterRevision
          case revision of
            Left err -> pure (Left err)
            Right (attesterRevision, attesterDirty) -> do
              revisions <- checkRevisions options.offline scratch record source
              let cohort = checkCohort now record source
                  environment = checkEnvironment now record source
                  clean = checkClean record source attesterDirty
              recomputed <- checkRecomputation options.bundleRoot recomputers scratch record source
              let checks = [digestCheck, revisions, cohort, recomputed, environment, clean]
                  verdict = deriveVerdict checks
                  run = "/" <> Text.pack relative
              identifier <- renderRunId <$> newRunId
              let attestation =
                    AttestationEvidence
                      { title = "Attestation of " <> record.runId <> " — " <> verdict,
                        description = "The kenshou attester checked the linked data and recorded " <> verdict <> ".",
                        generatedAt = utcText now,
                        attestationId = identifier,
                        run,
                        attesterRevision,
                        attestedAt = utcText now,
                        verdict,
                        checks,
                        dataDigests = sort (nub matchedDigests),
                        exception = fmap (\(authority, reason) -> object ["authority" .= authority, "reason" .= reason]) options.acceptedAnomaly,
                        body = "The attester recorded " <> verdict <> " for [the run](" <> run <> ").\n"
                      }
              amended <-
                if verdict == "confirmed"
                  then appendVerification (options.bundleRoot </> relative) content (utcText now)
                  else pure (Right Nothing)
              case amended of
                Left err -> pure (Left err)
                Right oldContent -> do
                  written <- writeAttestationRecord options.bundleRoot attestation
                  case written of
                    Left _ | Just old <- oldContent -> Text.IO.writeFile (options.bundleRoot </> relative) old
                    _ -> pure ()
                  pure case written of
                    Left err -> Left (AttestBundle err)
                    Right (RecordCreated path) -> Right (AttestResult path verdict)
                    Right (RecordPresent path) -> Right (AttestResult path verdict)

appendVerification :: FilePath -> Text -> Text -> IO (Either AttestError (Maybe Text))
appendVerification path original at = do
  current <- Text.IO.readFile path
  if current /= original
    then pure (Left (AttestIo "run record changed while attesting"))
    else case parseDocument current of
      Left err -> pure (Left (InvalidTarget (Text.pack (show err))))
      Right document -> do
        let actor = ProcessActor "kenshou-attester/0.1.0.0"
            existing = readVerified document.frontmatter
        if any (\entry -> entry.verificationBy == actor) existing
          then pure (Right Nothing)
          else do
            let updated = document {frontmatter = setVerified (existing <> [Verification actor (Just at)]) document.frontmatter}
            Text.IO.writeFile path (serializeDocument updated)
            pure (Right (Just original))

verifyData :: ObjectStore -> Bool -> FilePath -> EvidenceRecord -> IO (AttestationCheck, [Sha256], Maybe RunSource)
verifyData store linkedOnly root record = do
  linked <- forM record.dataLinks (fetchLink store root record.runId)
  let matched = [digest | Right digest <- linked]
      failures = [reason | Left reason <- linked]
  if not (null failures)
    then pure (check "digests-match" "failed" (Text.intercalate "; " failures), matched, Nothing)
    else
      if linkedOnly
        then pure (check "digests-match" "skipped" "only linked objects were checked", matched, Nothing)
        else do
          manifestBytes <- ByteString.readFile (root </> "manifest.json")
          case (eitherDecodeStrict' manifestBytes :: Either String Manifest) of
            Left message -> pure (check "digests-match" "failed" (Text.pack message), matched, Nothing)
            Right manifest -> do
              extra <- forM manifest.files (fetchManifestFile store root record.runId record.dataLinks)
              let allDigests = matched <> [digest | Right (Just digest) <- extra]
                  extraFailures = [reason | Left reason <- extra]
              if not (null extraFailures)
                then pure (check "digests-match" "failed" (Text.intercalate "; " extraFailures), allDigests, Nothing)
                else do
                  loaded <- loadRunSource root
                  case loaded of
                    Left err -> pure (check "digests-match" "failed" (Text.pack (show err)), allDigests, Nothing)
                    Right source -> pure (check "digests-match" "passed" "linked objects and manifest files match their SHA-256 and size", allDigests, Just source)

fetchLink :: ObjectStore -> FilePath -> Text -> DataLink -> IO (Either Text Sha256)
fetchLink store root runId link = case relativeObjectPath runId link.uri of
  Nothing -> pure (Left ("unsafe data URI: " <> link.uri))
  Just relative -> do
    let path = root </> relative
    fetched <- store.fetchObject link.uri path
    case fetched of
      Left err -> pure (Left (Text.pack (show err)))
      Right () -> do
        contents <- ByteString.readFile path
        let actual = sha256Bytes contents
        pure $
          if actual == link.digest && fromIntegral (ByteString.length contents) == link.bytes
            then Right actual
            else Left ("object differs from recorded digest or size: " <> link.uri)

fetchManifestFile :: ObjectStore -> FilePath -> Text -> [DataLink] -> ManifestFile -> IO (Either Text (Maybe Sha256))
fetchManifestFile store root runId links file
  | not (safeRelative file.path) = pure (Left ("unsafe manifest path: " <> Text.pack file.path))
  | any (\link -> relativeObjectPath runId link.uri == Just file.path) links = pure (Right Nothing)
  | otherwise = case [Text.dropEnd (Text.length "manifest.json") link.uri | link <- links, link.kind == ManifestData] of
      base : _ -> do
        let uri = base <> Text.pack file.path
            path = root </> file.path
        fetched <- store.fetchObject uri path
        case fetched of
          Left err -> pure (Left (Text.pack (show err)))
          Right () -> do
            contents <- ByteString.readFile path
            let digest = sha256Bytes contents
            let Sha256 digestText = digest
            pure $
              if "sha256:" <> digestText == file.sha256 && fromIntegral (ByteString.length contents) == file.bytes
                then Right (Just digest)
                else Left ("manifest object differs: " <> uri)
      [] -> pure (Left "manifest link is missing")

relativeObjectPath :: Text -> Text -> Maybe FilePath
relativeObjectPath runId uri = do
  let marker = "/" <> runId <> "/"
      (prefix, suffix) = Text.breakOnEnd marker uri
      path = Text.unpack suffix
  if Text.null prefix || not (safeRelative path) then Nothing else Just path

safeRelative :: FilePath -> Bool
safeRelative path =
  not (null path)
    && not (isAbsolute path)
    && normalise path == path
    && all (`notElem` ["", ".", ".."]) (splitDirectories path)

checkRevisions :: Bool -> FilePath -> EvidenceRecord -> Maybe RunSource -> IO AttestationCheck
checkRevisions offline scratch record source = do
  harness <- gitCommitExists Nothing record.harnessRevision
  componentChecks <- forM (zip [0 :: Int ..] [component | component <- record.components, component.source == FromGit]) $ \(index, component) -> do
    local <- moriCheckout component.project
    foundLocally <- maybe (pure False) (\path -> maybe (pure False) (gitCommitExists (Just path)) component.revision) local
    if foundLocally
      then pure Nothing
      else
        if offline
          then pure (Just component.package)
          else case (component.revision, source >>= componentLocation component) of
            (Just revision, Just location) -> do
              fetched <- fetchRevision (scratch </> "revision-" <> show index) location revision
              pure (if fetched then Nothing else Just component.package)
            _ -> pure (Just component.package)
  let unresolved = [name | Just name <- componentChecks]
      problems = ["harness revision is absent from this checkout" | not harness] <> ["component revision unresolved: " <> name | name <- unresolved]
  pure $
    if null problems
      then check "revisions-resolve" "passed" "harness and git component commits resolve"
      else check "revisions-resolve" "skipped" (Text.intercalate "; " problems)

componentLocation :: ComponentRef -> RunSource -> Maybe Text
componentLocation component source = do
  cohortComponent <- find (\candidate -> candidate.resolvedComponentMoriUri == component.project) source.result.resultCohort.identityComponents
  package <- find (\candidate -> candidate.resolvedPackageName == component.package) cohortComponent.resolvedComponentPackages
  case package.resolvedPackageSource of
    Cohort.FromGit location _ _ -> Just location
    _ -> Nothing

moriCheckout :: Text -> IO (Maybe FilePath)
moriCheckout project = do
  response <- try (readProcessWithExitCode "mori" ["path", Text.unpack project] "") :: IO (Either IOException (ExitCode, String, String))
  case response of
    Right (ExitSuccess, output, _) -> case reverse (lines output) of
      path : _ -> do
        present <- doesDirectoryExist path
        pure (if present then Just path else Nothing)
      [] -> pure Nothing
    _ -> pure Nothing

gitCommitExists :: Maybe FilePath -> Revision -> IO Bool
gitCommitExists location (Revision revision) = do
  let args = maybe [] (\path -> ["-C", path]) location <> ["cat-file", "-e", Text.unpack revision <> "^{commit}"]
  response <- try (readProcessWithExitCode "git" args "") :: IO (Either IOException (ExitCode, String, String))
  pure $ case response of
    Right (ExitSuccess, _, _) -> True
    _ -> False

fetchRevision :: FilePath -> Text -> Revision -> IO Bool
fetchRevision root location revision@(Revision sha) = do
  prepared <- noPromptGit ["init", "--bare", root]
  if not prepared
    then pure False
    else do
      fetched <- noPromptGit ["-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=never", "-C", root, "fetch", "--depth=1", Text.unpack location, Text.unpack sha]
      if fetched then gitCommitExists (Just root) revision else pure False

noPromptGit :: [String] -> IO Bool
noPromptGit args = do
  environment <- getEnvironment
  let process = (proc "git" args) {env = Just (("GIT_TERMINAL_PROMPT", "0") : filter ((/= "GIT_TERMINAL_PROMPT") . fst) environment)}
  response <- try (readCreateProcessWithExitCode process "") :: IO (Either IOException (ExitCode, String, String))
  pure $ case response of
    Right (ExitSuccess, _, _) -> True
    _ -> False

checkCohort :: UTCTime -> EvidenceRecord -> Maybe RunSource -> AttestationCheck
checkCohort _ _ Nothing = check "cohort-matches-plan" "skipped" "source documents are unavailable"
checkCohort now record (Just source) = case buildRunRecord (RecordInput record.purpose now True (Just (record.subject, record.subjectKind)) record.produced record.previousRun) source record.dataLinks of
  Left err -> check "cohort-matches-plan" "failed" (Text.pack (show err))
  Right expected ->
    let expectationMatches = case source.spec.cohortExpectation of
          Nothing -> True
          Just expectation ->
            expectation.planHash == unPlanHash source.result.resultCohort.identityPlanHash
              && maybe True (== record.cohort) expectation.name
     in if expectationMatches && (record.cohort, record.solverPlanHash, record.components) == (expected.cohort, expected.solverPlanHash, expected.components)
          then check "cohort-matches-plan" "passed" "cohort identity and run-spec expectation agree"
          else check "cohort-matches-plan" "failed" "cohort identity or run-spec expectation differs"

checkEnvironment :: UTCTime -> EvidenceRecord -> Maybe RunSource -> AttestationCheck
checkEnvironment _ _ Nothing = check "environment-captured" "skipped" "source documents are unavailable"
checkEnvironment now record (Just source) = case buildRunRecord (RecordInput record.purpose now True (Just (record.subject, record.subjectKind)) record.produced record.previousRun) source record.dataLinks of
  Left err -> check "environment-captured" "failed" (Text.pack (show err))
  Right expected ->
    if record.environment == expected.environment && record.placement == expected.placement
      then check "environment-captured" "passed" "recorded environment matches the run result"
      else check "environment-captured" "failed" "recorded environment differs from the run result"

checkClean :: EvidenceRecord -> Maybe RunSource -> Bool -> AttestationCheck
checkClean record source attesterDirty =
  let sourceDirty =
        source
          >>= ( \run -> case run.result.resultFingerprint of
                  Object fields -> case KeyMap.lookup "kenshou" fields of
                    Just (Object kenshou) -> case KeyMap.lookup "dirty" kenshou of Just (Bool value) -> Just value; _ -> Nothing
                    _ -> Nothing
                  _ -> Nothing
              )
   in if record.harnessDirty || sourceDirty == Just True || attesterDirty
        then check "clean-worktree" "failed" "the run or attester worktree is dirty"
        else
          if sourceDirty == Just False
            then check "clean-worktree" "passed" "run and attester worktrees are clean"
            else check "clean-worktree" "skipped" "run dirty state is unavailable"

checkRecomputation :: FilePath -> [Recomputer] -> FilePath -> EvidenceRecord -> Maybe RunSource -> IO AttestationCheck
checkRecomputation _ _ _ _ Nothing = pure (check "verdict-recomputed" "skipped" "source documents are unavailable")
checkRecomputation bundle recomputers root record _ = do
  definitions <- computationDefinitions bundle
  let configured =
        [ (handle, lookup handle definitions >>= \(name, version) -> find (\candidate -> candidate.algorithm == name && candidate.algorithmVersion == version) recomputers)
        | handle <- record.computations
        ]
      missing = [handle | (handle, Nothing) <- configured]
  results <- forM [(handle, recomputer) | (handle, Just recomputer) <- configured] $ \(handle, recomputer) -> do
    result <- recomputer.recompute root
    pure (handle, result)
  let contradictions =
        [ handle
        | (handle, Right result) <- results,
          not result.agreesWithDocuments || maybe False (/= record.outcome) result.outcome
        ]
      unavailable = missing <> [handle | (handle, Left _) <- results]
  pure $
    if not (null contradictions)
      then check "verdict-recomputed" "failed" ("recomputation disagrees with the record: " <> Text.intercalate ", " contradictions)
      else
        if null configured
          then check "verdict-recomputed" "skipped" "run names no computation definitions"
          else
            if not (null unavailable)
              then check "verdict-recomputed" "skipped" ("recomputer unavailable for " <> Text.intercalate ", " unavailable)
              else check "verdict-recomputed" "passed" "registered recomputers agree with the source documents"

computationDefinitions :: FilePath -> IO [(Text, (Text, Integer))]
computationDefinitions bundle = do
  let folder = bundle </> "computations"
  names <- ifMDirectory folder listDirectory
  fmap concat $ forM [name | name <- names, takeExtension name == ".md"] $ \name -> do
    content <- Text.IO.readFile (folder </> name)
    pure case parseDocument content of
      Left _ -> []
      Right document -> case (frontmatterLookup "computationId" document.frontmatter, frontmatterLookup "algorithm" document.frontmatter, frontmatterLookup "algorithmVersion" document.frontmatter) of
        (Just (String handle), Just (String algorithm), Just rawVersion) -> case fromJSON rawVersion of
          Success version -> [(handle, (algorithm, version))]
          Error _ -> []
        _ -> []

deriveVerdict :: [AttestationCheck] -> Text
deriveVerdict checks
  | any (\item -> item.result == "failed" && item.name `elem` ["digests-match", "cohort-matches-plan", "verdict-recomputed"]) checks = "refuted"
  | all (\item -> item.result == "passed") checks = "confirmed"
  | otherwise = "incomplete"

check :: Text -> Text -> Text -> AttestationCheck
check name result detail = AttestationCheck name result (Just detail)

currentAttesterRevision :: IO (Either AttestError (Revision, Bool))
currentAttesterRevision = do
  (revisionExit, rawRevision, revisionError) <- readProcessWithExitCode "git" ["rev-parse", "HEAD"] ""
  (statusExit, status, statusError) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
  pure do
    if revisionExit /= ExitSuccess then Left (AttestIo (Text.pack revisionError)) else Right ()
    if statusExit /= ExitSuccess then Left (AttestIo (Text.pack statusError)) else Right ()
    revision <- either (Left . AttestIo) Right (mkRevision (Text.strip (Text.pack rawRevision)))
    Right (revision, not (null status))

utcText :: UTCTime -> Text
utcText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"
