module Kenshou.Evidence.Source
  ( SourceError (..),
    VerifiedFile (..),
    RunResultView (..),
    RunSource (..),
    loadRunSource,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Aeson (FromJSON (..), Value, eitherDecodeStrict', withObject, (.:), (.:?))
import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Word (Word64)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort (CohortIdentity)
import Kenshou.Core.Id (RunId, ScenarioId, unSeed)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Core.Outcome (Outcome)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Evidence.Types (Sha256, sha256Bytes)
import Numeric.Natural (Natural)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (isAbsolute, normalise, splitDirectories, takeFileName, (</>))

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
      <*> value .:? "knownDefect"

data RunSource = RunSource
  { manifest :: !Manifest,
    spec :: !RunSpec,
    result :: !RunResultView,
    files :: ![VerifiedFile]
  }
  deriving stock (Eq, Show)

loadRunSource :: FilePath -> IO (Either SourceError RunSource)
loadRunSource root = do
  loaded <- try (runExceptT (load root)) :: IO (Either IOException (Either SourceError RunSource))
  pure $ either (Left . SourceError . Text.pack . show) id loaded

load :: FilePath -> ExceptT SourceError IO RunSource
load root = do
  manifest <- readJson (root </> "manifest.json")
  files <- verifyFiles root manifest
  spec <- readJson (root </> "run-spec.json")
  result <- readJson (root </> "run-result.json")
  when (manifest.runId /= result.resultRunId) (reject "manifest and run result identify different runs")
  when (spec.runId /= Just result.resultRunId) (reject "run spec and run result identify different runs")
  when (spec.scenario /= result.resultScenario) (reject "run spec and run result identify different scenarios")
  when (fmap unSeed spec.seed /= Just result.resultSeed) (reject "run spec and run result use different seeds")
  when (result.resultStartedAt > result.resultEndedAt) (reject "run result ends before it starts")
  specBytes <- lift (ByteString.readFile (root </> "run-spec.json"))
  when (result.resultSpecSha256 /= sha256Hex specBytes) (reject "run result does not match run-spec.json")
  pure RunSource {manifest, spec, result, files}

readJson :: (FromJSON value) => FilePath -> ExceptT SourceError IO value
readJson path = do
  contents <- lift (ByteString.readFile path)
  either (\message -> reject (Text.pack (takeFileName path) <> ": " <> Text.pack message)) pure (eitherDecodeStrict' contents)

verifyFiles :: FilePath -> Manifest -> ExceptT SourceError IO [VerifiedFile]
verifyFiles root manifest = do
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
  unless (sort listed == sort (filter (/= "manifest.json") actual)) (reject "manifest does not enumerate every run file exactly once")
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
