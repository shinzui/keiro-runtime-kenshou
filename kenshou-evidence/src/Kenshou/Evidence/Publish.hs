module Kenshou.Evidence.Publish
  ( UploadMode (..),
    PublishOptions (..),
    PublishError (..),
    publishRunData,
    publishComparisonData,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.ByteString qualified as ByteString
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Evidence.Source (CellEvidence (..), ComparisonSource (..), ComparisonView (..), RunResultView (..), RunSource (..), VerifiedFile (..))
import Kenshou.Evidence.Store (ObjectStat (..), ObjectStore (..), StoreError, validateObjectUri)
import Kenshou.Evidence.Types (DataKind (..), DataLink (..), Sha256, sha256Bytes)
import Kenshou.Remote.Cell.Docs (CellManifest (..))
import Numeric.Natural (Natural)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

data UploadMode = UploadMissing | VerifyOnly deriving stock (Eq, Show)

data PublishOptions = PublishOptions
  { baseUri :: !Text,
    uploadMode :: !UploadMode,
    deepVerify :: !Bool,
    linkLogs :: !Bool
  }
  deriving stock (Eq, Show)

data PublishError
  = InvalidBaseUri !Text
  | PublishIo !Text
  | StoreFailure !StoreError
  | MissingObject !Text
  | ObjectMismatch !Text
  deriving stock (Eq, Show)

-- | Publish every file covered by the verified manifest, even if only a
-- subset will be linked directly. The manifest link pins the rest transitively.
publishRunData :: ObjectStore -> PublishOptions -> FilePath -> RunSource -> IO (Either PublishError [DataLink])
publishRunData store options root source = case cleanBase options.baseUri of
  Left err -> pure (Left err)
  Right base -> do
    completed <-
      try
        ( runExceptT do
            let runPrefix = base <> "/" <> renderRunId source.result.resultRunId
                entries = sortOn (.relativePath) source.files
            linked <- forM entries $ \entry -> do
              let uri = runPrefix <> "/" <> Text.pack entry.relativePath
                  path = root </> entry.relativePath
              publishOne store options path uri entry.mediaType entry.digest entry.bytes
              pure $ do
                kind <- kindForPath options.linkLogs (source.result.resultOutcome /= Passed) entry.relativePath
                pure DataLink {kind, uri, digest = entry.digest, mediaType = entry.mediaType, bytes = entry.bytes}
            manifestBytes <- lift (ByteString.readFile (root </> "manifest.json"))
            let manifestUri = runPrefix <> "/manifest.json"
                manifestDigest = sha256Bytes manifestBytes
                manifestSize = fromIntegral (ByteString.length manifestBytes)
            publishOne store options (root </> "manifest.json") manifestUri "application/json" manifestDigest manifestSize
            cellLinks <- case source.cellEvidence of
              Nothing -> pure []
              Just cell -> do
                let expectedSuffix = "/runs/" <> renderRunId cell.cellManifest.runId <> "/output"
                unless (expectedSuffix `Text.isSuffixOf` base) (throwE (InvalidBaseUri options.baseUri))
                let uri = Text.dropEnd (Text.length "/output") base <> "/manifest.json"
                    file = cell.cellManifestFile
                publishOne store (options {uploadMode = VerifyOnly}) cell.cellManifestPath uri "application/json" file.digest file.bytes
                pure [DataLink {kind = CellManifestData, uri, digest = file.digest, mediaType = "application/json", bytes = file.bytes}]
            pure $
              sortOn (\link -> (link.kind, link.uri)) $
                DataLink {kind = ManifestData, uri = manifestUri, digest = manifestDigest, mediaType = "application/json", bytes = manifestSize} : cellLinks <> catMaybes linked
        ) ::
        IO (Either IOException (Either PublishError [DataLink]))
    pure $ either (Left . PublishIo . Text.pack . show) id completed

publishComparisonData :: ObjectStore -> PublishOptions -> FilePath -> ComparisonSource -> IO (Either PublishError DataLink)
publishComparisonData store options path source = case cleanBase options.baseUri of
  Left err -> pure (Left err)
  Right base -> do
    let entry = source.file
        uri = base <> "/" <> renderRunId source.view.comparisonId <> "/comparison.json"
    completed <- try (runExceptT (publishOne store options path uri entry.mediaType entry.digest entry.bytes)) :: IO (Either IOException (Either PublishError ()))
    pure $ do
      either (Left . PublishIo . Text.pack . show) id completed
      pure DataLink {kind = ComparisonData, uri, digest = entry.digest, mediaType = entry.mediaType, bytes = entry.bytes}

cleanBase :: Text -> Either PublishError Text
cleanBase raw = do
  let base = Text.dropWhileEnd (== '/') raw
  case validateObjectUri (base <> "/probe") of
    Left _ -> Left (InvalidBaseUri raw)
    Right () -> Right base

publishOne :: ObjectStore -> PublishOptions -> FilePath -> Text -> Text -> Sha256 -> Natural -> ExceptT PublishError IO ()
publishOne store options source uri mediaType expectedDigest expectedSize = do
  contents <- lift (ByteString.readFile source)
  when (fromIntegral (ByteString.length contents) /= expectedSize || sha256Bytes contents /= expectedDigest) (throwE (ObjectMismatch uri))
  result <- lift $ withSystemTempDirectory "kenshou-evidence-publish" $ \scratch -> do
    let snapshot = scratch </> "snapshot"
    ByteString.writeFile snapshot contents
    runExceptT (publishSnapshot snapshot scratch)
  either throwE pure result
  where
    publishSnapshot snapshot scratch = do
      case options.uploadMode of
        UploadMissing -> do
          uploaded <- lift (store.putObjectIfAbsent snapshot uri mediaType)
          either (throwE . StoreFailure) (const (pure ())) uploaded
        VerifyOnly -> pure ()
      observed <- lift (store.statObject uri) >>= either (throwE . StoreFailure) pure
      stat <- maybe (throwE (MissingObject uri)) pure observed
      when (stat.bytes /= expectedSize || maybe False (/= expectedDigest) stat.recordedSha256) (throwE (ObjectMismatch uri))
      -- Cell-owned objects carry their SHA-256 in the sealed manifest, not
      -- GCS custom metadata. Verify their bytes when metadata is absent.
      when (options.deepVerify || stat.recordedSha256 == Nothing) do
        let target = scratch </> "downloaded"
        fetched <- lift (store.fetchObject uri target)
        either (throwE . StoreFailure) pure fetched
        downloaded <- lift (ByteString.readFile target)
        unless (fromIntegral (ByteString.length downloaded) == expectedSize && sha256Bytes downloaded == expectedDigest) (throwE (ObjectMismatch uri))

kindForPath :: Bool -> Bool -> FilePath -> Maybe DataKind
kindForPath linkLogs failed path
  | path == "run-spec.json" = Just RunSpecData
  | path == "run-result.json" = Just RunResultData
  | path == "cell/manifest.json" = Just CellManifestData
  | "samples/" `Text.isPrefixOf` item = Just SamplesData
  | "series/" `Text.isPrefixOf` item = Just SeriesData
  | "verdicts/" `Text.isPrefixOf` item = Just VerdictsData
  | "diagnosis/" `Text.isPrefixOf` item = Just DiagnosisData
  | "logs/" `Text.isPrefixOf` item && (linkLogs || failed) = Just LogsData
  | otherwise = Nothing
  where
    item = Text.pack path
