module Kenshou.Evidence.Source
  ( SourceError (..),
    VerifiedFile (..),
    RunResultView (..),
    CellEvidence (..),
    RunSource (..),
    ComparisonView (..),
    ComparisonSource (..),
    loadRunSource,
    loadComparisonSource,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Word (Word64)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort (CohortIdentity)
import Kenshou.Core.Id (RunId, ScenarioId, renderRunId, unSeed)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Core.Outcome (Outcome)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Evidence.Types (Sha256, sha256Bytes)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..))
import Kenshou.Remote.Cell.Fetch qualified as CellFetch
import Kenshou.Remote.Cell.Index (CellManifestLink (..), CellRunIndex (..), RunLink (..))
import Numeric.Natural (Natural)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName, (</>))

newtype SourceError = SourceError Text deriving stock (Eq, Show)

data VerifiedFile = VerifiedFile
  { relativePath :: !FilePath,
    digest :: !Sha256,
    bytes :: !Natural,
    mediaType :: !Text
  }
  deriving stock (Eq, Show)

-- RunResult has no FromJSON instance in the kernel. This reader keeps the
-- evidence-facing fields typed while leaving the large diagnostic payload to
-- the versioned run-result document itself.
data RunResultView = RunResultView
  { resultRunId :: !RunId,
    resultScenario :: !ScenarioId,
    resultOutcome :: !Outcome,
    resultTier :: !Text,
    resultSeed :: !Word64,
    resultSpecSha256 :: !Text,
    resultStartedAt :: !UTCTime,
    resultEndedAt :: !UTCTime,
    resultCohort :: !CohortIdentity,
    resultFingerprint :: !Value,
    resultCompatibility :: !Value,
    resultSummaries :: !(Maybe Value),
    resultKnownDefect :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

instance FromJSON RunResultView where
  parseJSON = withObject "RunResult" \value -> do
    schema <- value .: "schema"
    unless (schema == ("kenshou.run-result/v1" :: Text)) (fail "unsupported run-result schema")
    spec <- value .: "spec"
    timings <- value .: "timings"
    RunResultView
      <$> value .: "runId"
      <*> value .: "scenario"
      <*> value .: "outcome"
      <*> value .: "tier"
      <*> value .: "seed"
      <*> spec .: "sha256"
      <*> timings .: "startedAt"
      <*> timings .: "endedAt"
      <*> value .: "cohort"
      <*> value .: "fingerprint"
      <*> value .: "compatibility"
      <*> value .:? "summaries"
      <*> value .:? "knownDefect"

data CellEvidence = CellEvidence
  { cellManifest :: !CellManifest,
    cellManifestPath :: !FilePath,
    cellManifestFile :: !VerifiedFile,
    cellEffectiveOutcome :: !Outcome
  }
  deriving stock (Eq, Show)

data RunSource = RunSource
  { manifest :: !Manifest,
    spec :: !RunSpec,
    result :: !RunResultView,
    files :: ![VerifiedFile],
    cellEvidence :: !(Maybe CellEvidence)
  }
  deriving stock (Eq, Show)

data ComparisonView = ComparisonView
  { comparisonId :: !RunId,
    baselineRuns :: ![RunId],
    candidateRuns :: ![RunId],
    startedAt :: !UTCTime,
    finishedAt :: !UTCTime,
    harnessRevision :: !(Maybe Text),
    harnessDirty :: !(Maybe Bool),
    design :: !Text,
    variedFactors :: ![Text],
    pairCount :: !Int,
    verdict :: !Text
  }
  deriving stock (Eq, Show)

data ComparisonSource = ComparisonSource
  { view :: !ComparisonView,
    file :: !VerifiedFile
  }
  deriving stock (Eq, Show)

instance FromJSON ComparisonView where
  parseJSON = withObject "Comparison" \value -> do
    schema <- value .: "schema"
    unless (schema == ("kenshou.comparison/v1" :: Text)) (fail "unsupported comparison schema")
    ComparisonView
      <$> value .: "comparisonId"
      <*> value .: "baselineRuns"
      <*> value .: "candidateRuns"
      <*> value .: "startedAt"
      <*> value .: "finishedAt"
      <*> value .:? "harnessRevision"
      <*> value .:? "harnessDirty"
      <*> value .: "design"
      <*> value .: "variedFactors"
      <*> value .: "pairCount"
      <*> value .: "verdict"

loadComparisonSource :: FilePath -> IO (Either SourceError ComparisonSource)
loadComparisonSource path = do
  loaded <- try (runExceptT (loadComparison path)) :: IO (Either IOException (Either SourceError ComparisonSource))
  pure $ either (Left . SourceError . Text.pack . show) id loaded

loadComparison :: FilePath -> ExceptT SourceError IO ComparisonSource
loadComparison path = do
  symlink <- lift (pathIsSymbolicLink path)
  when symlink (reject "comparison document is a symbolic link")
  contents <- lift (ByteString.readFile path)
  view <- either (reject . Text.pack) pure (eitherDecodeStrict' contents)
  when (view.pairCount <= 0 || view.pairCount /= length view.baselineRuns || view.pairCount /= length view.candidateRuns) (reject "comparison pair count and arm IDs disagree")
  when (view.startedAt > view.finishedAt) (reject "comparison ends before it starts")
  when (null view.variedFactors) (reject "comparison has no varied factor")
  when (view.design `notElem` ["abba", "baab", "sequential"]) (reject "comparison has an unknown design")
  when (view.verdict `notElem` ["pass", "regression", "inconclusive", "infrastructure-failure"]) (reject "comparison has an unknown verdict")
  when (Set.size (Set.fromList (view.baselineRuns <> view.candidateRuns)) /= view.pairCount * 2) (reject "comparison repeats a run ID")
  let file = VerifiedFile "comparison.json" (sha256Bytes contents) (fromIntegral (ByteString.length contents)) "application/json"
  pure ComparisonSource {view, file}

loadRunSource :: FilePath -> IO (Either SourceError RunSource)
loadRunSource root = do
  loaded <- try (runExceptT (load root)) :: IO (Either IOException (Either SourceError RunSource))
  pure $ either (Left . SourceError . Text.pack . show) id loaded

load :: FilePath -> ExceptT SourceError IO RunSource
load root = do
  manifest <- readJson (root </> "manifest.json")
  spec <- readJson (root </> "run-spec.json")
  files <- verifyFiles root manifest (spec.environment.placement == RunOnCell)
  result <- readJson (root </> "run-result.json")
  when (manifest.runId /= result.resultRunId) (reject "manifest and run result identify different runs")
  when (spec.runId /= Just result.resultRunId) (reject "run spec and run result identify different runs")
  when (spec.scenario /= result.resultScenario) (reject "run spec and run result identify different scenarios")
  when (fmap unSeed spec.seed /= Just result.resultSeed) (reject "run spec and run result use different seeds")
  when (result.resultStartedAt > result.resultEndedAt) (reject "run result ends before it starts")
  specBytes <- lift (ByteString.readFile (root </> "run-spec.json"))
  when (result.resultSpecSha256 /= sha256Hex specBytes) (reject "run result does not match run-spec.json")
  cellEvidence <- case spec.environment.placement of
    RunLocal -> pure Nothing
    RunOnCell -> Just <$> loadCellEvidence root result
  pure RunSource {manifest, spec, result, files, cellEvidence}

loadCellEvidence :: FilePath -> RunResultView -> ExceptT SourceError IO CellEvidence
loadCellEvidence root result = do
  realRoot <- lift (canonicalizePath root)
  let sidecar = root </> "cell-manifest.json"
      fetched = takeDirectory (takeDirectory realRoot) </> "manifest.json"
  hasSidecar <- lift (doesFileExist sidecar)
  hasFetched <- lift (doesFileExist fetched)
  path <- case (hasSidecar, hasFetched) of
    (True, _) -> pure sidecar
    (_, True) -> pure fetched
    _ -> reject "cell run has no outer cell manifest"
  symlink <- lift (pathIsSymbolicLink path)
  when symlink (reject "outer cell manifest is a symbolic link")
  bytes <- lift (ByteString.readFile path)
  cellManifest <- either (reject . Text.pack) pure (eitherDecodeStrict' bytes)
  (namedCell, namedRun) <- case result.resultFingerprint of
    Object fields -> case KeyMap.lookup "cell" fields of
      Just (Object cellFields) -> do
        cell <- parseField "fingerprint.cell.cell" =<< maybe (reject "fingerprint.cell.cell is missing") pure (KeyMap.lookup "cell" cellFields)
        cellRun <- parseField "fingerprint.cell.cellRun" =<< maybe (reject "fingerprint.cell.cellRun is missing") pure (KeyMap.lookup "cellRun" cellFields)
        pure (cell, cellRun)
      _ -> reject "cell run has no fingerprint.cell"
    _ -> reject "cell run has no fingerprint object"
  when (cellManifest.cell /= namedCell || cellManifest.runId /= namedRun) (reject "outer cell manifest differs from nested cell fingerprint")
  let nestedPrefix = "output/" <> renderRunId result.resultRunId <> "/"
  forM_ ["manifest.json", "run-result.json", "run-spec.json"] \name -> do
    let nestedPath = root </> Text.unpack name
    nestedBytes <- lift (ByteString.readFile nestedPath)
    case [artifact | artifact <- cellManifest.artifacts, artifact.path == nestedPrefix <> name] of
      [artifact]
        | Just artifact.sha256 == Text.stripPrefix "sha256:" (sha256Hex nestedBytes) && artifact.bytes == fromIntegral (ByteString.length nestedBytes) -> pure ()
      _ -> reject ("outer cell manifest does not pin nested " <> name)
  let cellManifestFile = VerifiedFile "cell-manifest.json" (sha256Bytes bytes) (fromIntegral (ByteString.length bytes)) "application/json"
      cellEffectiveOutcome = CellFetch.effectiveOutcome cellManifest.outcome True result.resultOutcome
      indexPath = takeDirectory (takeDirectory (takeDirectory realRoot)) </> "cell-run.json"
  hasIndex <- lift (doesFileExist indexPath)
  when hasIndex do
    index <- readJson indexPath :: ExceptT SourceError IO CellRunIndex
    when (index.cellRun /= cellManifest.runId || index.cell /= cellManifest.cell || index.cellManifest.sha256 /= Text.drop 7 (sha256Hex bytes)) (reject "cell-run index disagrees with the outer manifest")
    case [run | run <- index.runs, run.runId == result.resultRunId] of
      [run] | run.recordedOutcome == result.resultOutcome && run.effectiveOutcome == cellEffectiveOutcome -> pure ()
      _ -> reject "cell-run index disagrees with the nested effective outcome"
  pure CellEvidence {cellManifest, cellManifestPath = path, cellManifestFile, cellEffectiveOutcome}
  where
    parseField :: (FromJSON value) => Text -> Value -> ExceptT SourceError IO value
    parseField label value = case Aeson.fromJSON value of
      Aeson.Error problem -> reject (label <> ": " <> Text.pack problem)
      Aeson.Success parsed -> pure parsed

readJson :: (FromJSON value) => FilePath -> ExceptT SourceError IO value
readJson path = do
  contents <- lift (ByteString.readFile path)
  either (\message -> reject (Text.pack (takeFileName path) <> ": " <> Text.pack message)) pure (eitherDecodeStrict' contents)

verifyFiles :: FilePath -> Manifest -> Bool -> ExceptT SourceError IO [VerifiedFile]
verifyFiles root manifest cellRun = do
  let listed = map (.path) manifest.files
  when (length listed /= Set.size (Set.fromList listed)) (reject "manifest has duplicate file paths")
  verified <- forM manifest.files $ \file -> do
    unless (safeRelative file.path) (reject ("unsafe manifest path: " <> Text.pack file.path))
    let path = root </> file.path
    symlink <- lift (pathIsSymbolicLink path)
    when symlink (reject ("manifest path is a symbolic link: " <> Text.pack file.path))
    exists <- lift (doesFileExist path)
    unless exists (reject ("manifest file is missing: " <> Text.pack file.path))
    contents <- lift (ByteString.readFile path)
    when (file.sha256 /= sha256Hex contents) (reject ("digest mismatch: " <> Text.pack file.path))
    when (file.bytes /= fromIntegral (ByteString.length contents)) (reject ("size mismatch: " <> Text.pack file.path))
    when (Text.null file.mediaType) (reject ("missing media type: " <> Text.pack file.path))
    pure VerifiedFile {relativePath = file.path, digest = sha256Bytes contents, bytes = fromIntegral (ByteString.length contents), mediaType = file.mediaType}
  actual <- scanFiles root ""
  let sidecars = if cellRun then ["cell-manifest.json"] else []
  unless (sort listed == sort (filter (`notElem` ("manifest.json" : sidecars)) actual)) (reject "manifest does not enumerate every run file exactly once")
  pure verified

scanFiles :: FilePath -> FilePath -> ExceptT SourceError IO [FilePath]
scanFiles root relative = do
  let directory = root </> relative
  names <- lift (listDirectory directory)
  concat <$> forM names (visit directory)
  where
    visit directory name = do
      let relativePath = if null relative then name else relative </> name
          path = directory </> name
      unless (safeRelative relativePath) (reject ("unsafe run file path: " <> Text.pack relativePath))
      symlink <- lift (pathIsSymbolicLink path)
      when symlink (reject ("run directory contains a symbolic link: " <> Text.pack relativePath))
      isDirectory <- lift (doesDirectoryExist path)
      if isDirectory
        then scanFiles root relativePath
        else do
          regular <- lift (doesFileExist path)
          unless regular (reject ("run directory contains a non-file: " <> Text.pack relativePath))
          pure [relativePath]

safeRelative :: FilePath -> Bool
safeRelative path =
  not (null path)
    && not (isAbsolute path)
    && normalise path == path
    && all (\segment -> segment /= "" && segment /= "." && segment /= "..") (splitDirectories path)
    && '\\' `notElem` path

reject :: Text -> ExceptT SourceError IO value
reject = throwE . SourceError
