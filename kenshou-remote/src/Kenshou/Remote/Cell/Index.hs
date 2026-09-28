module Kenshou.Remote.Cell.Index
  ( CellManifestLink (..),
    EvidenceLink (..),
    RunLink (..),
    CellRunIndex (..),
    deriveCellRunIndex,
    writeCellRunIndex,
  )
where

import Control.Exception (bracket)
import Control.Monad (forM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON (..), ToJSON (..), Value, eitherDecode, encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, getCurrentTime)
import Kenshou.Core.Id (RunId, parseRunId, renderRunId)
import Kenshou.Core.Outcome (Outcome)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (..), CellRunResult (..), CellStatus)
import Kenshou.Remote.Cell.Fetch (VerifyProblem (..), effectiveOutcome, verifyCellRun, verifyCellRunWithStatus)
import Kenshou.Remote.Store (Bucket (..))
import System.Directory (doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openBinaryTempFile)

data CellManifestLink = CellManifestLink
  { path :: !Text,
    sha256 :: !Text,
    bytes :: !Int64
  }
  deriving stock (Eq, Show)

data EvidenceLink = EvidenceLink
  { kind :: !Text,
    path :: !Text,
    sha256 :: !Text,
    bytes :: !Int64,
    mediaType :: !Text
  }
  deriving stock (Eq, Show)

data RunLink = RunLink
  { runId :: !RunId,
    path :: !Text,
    scenario :: !Text,
    manifestSha256 :: !Text,
    recordedOutcome :: !Outcome,
    effectiveOutcome :: !Outcome,
    overrideReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data CellRunIndex = CellRunIndex
  { cellRun :: !RunId,
    cell :: !Text,
    leaseId :: !RunId,
    leaseSequence :: !Int,
    resultsBaseUri :: !Text,
    dataBaseUri :: !Text,
    cellManifest :: !CellManifestLink,
    cellOutcome :: !CellOutcome,
    reasons :: ![Text],
    entryExitCode :: !(Maybe Int),
    evidence :: ![EvidenceLink],
    runs :: ![RunLink],
    verifiedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON CellManifestLink where
  toJSON link = object ["path" .= link.path, "sha256" .= link.sha256, "bytes" .= link.bytes]

instance FromJSON CellManifestLink where
  parseJSON = withObject "cell manifest link" \value -> CellManifestLink <$> value .: "path" <*> value .: "sha256" <*> value .: "bytes"

instance ToJSON EvidenceLink where
  toJSON link = object ["kind" .= link.kind, "path" .= link.path, "sha256" .= link.sha256, "bytes" .= link.bytes, "mediaType" .= link.mediaType]

instance FromJSON EvidenceLink where
  parseJSON = withObject "cell evidence link" \value -> EvidenceLink <$> value .: "kind" <*> value .: "path" <*> value .: "sha256" <*> value .: "bytes" <*> value .: "mediaType"

instance ToJSON RunLink where
  toJSON run = object ["runId" .= run.runId, "path" .= run.path, "scenario" .= run.scenario, "manifestSha256" .= run.manifestSha256, "recordedOutcome" .= run.recordedOutcome, "effectiveOutcome" .= run.effectiveOutcome, "overrideReason" .= run.overrideReason]

instance FromJSON RunLink where
  parseJSON = withObject "cell nested run" \value -> RunLink <$> value .: "runId" <*> value .: "path" <*> value .: "scenario" <*> value .: "manifestSha256" <*> value .: "recordedOutcome" <*> value .: "effectiveOutcome" <*> value .:? "overrideReason"

instance ToJSON CellRunIndex where
  toJSON index =
    object
      [ "schema" .= ("kenshou.cell-run/v1" :: Text),
        "cellRun" .= index.cellRun,
        "cell" .= index.cell,
        "leaseId" .= index.leaseId,
        "leaseSequence" .= index.leaseSequence,
        "resultsBaseUri" .= index.resultsBaseUri,
        "dataBaseUri" .= index.dataBaseUri,
        "cellManifest" .= index.cellManifest,
        "cellOutcome" .= index.cellOutcome,
        "reasons" .= index.reasons,
        "entryExitCode" .= index.entryExitCode,
        "evidence" .= index.evidence,
        "runs" .= index.runs,
        "verifiedAt" .= index.verifiedAt
      ]

instance FromJSON CellRunIndex where
  parseJSON = withObject "cell run index" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.cell-run/v1" :: Text) then fail "unsupported cell run index" else pure ()
    CellRunIndex <$> value .: "cellRun" <*> value .: "cell" <*> value .: "leaseId" <*> value .: "leaseSequence" <*> value .: "resultsBaseUri" <*> value .: "dataBaseUri" <*> value .: "cellManifest" <*> value .: "cellOutcome" <*> value .: "reasons" <*> value .:? "entryExitCode" <*> value .: "evidence" <*> value .: "runs" <*> value .: "verifiedAt"

deriveCellRunIndex :: Bucket -> Maybe CellStatus -> FilePath -> IO (Either (NonEmpty VerifyProblem) CellRunIndex)
deriveCellRunIndex bucket status tree = do
  verified <- case status of
    Nothing -> verifyCellRun tree
    Just sealed -> verifyCellRunWithStatus sealed tree
  case verified of
    Left problems -> pure (Left problems)
    Right manifest -> do
      resultBytes <- LazyByteString.readFile (tree </> "cell" </> "result.json")
      case eitherDecode resultBytes :: Either String CellRunResult of
        Left failure -> pure (Left (InvalidManifest ("cell/result.json: " <> Text.pack failure) :| []))
        Right cellResult -> do
          manifestBytes <- LazyByteString.readFile (tree </> "manifest.json")
          let base = "gs://" <> bucket.unBucket <> "/runs/" <> renderRunId manifest.runId
              linked = CellManifestLink "manifest.json" (digest manifestBytes) (LazyByteString.length manifestBytes)
              evidence = [EvidenceLink kind artifact.path artifact.sha256 artifact.bytes artifact.mediaType | artifact <- manifest.artifacts, Just kind <- [evidenceKind artifact.path]]
          indexed <- forM (nestedRuns manifest.artifacts) \(identifier, nestedPath) -> do
            bytes <- LazyByteString.readFile (tree </> Text.unpack nestedPath </> "run-result.json")
            nestedManifest <- LazyByteString.readFile (tree </> Text.unpack nestedPath </> "manifest.json")
            pure case runFields bytes of
              Left failure -> Left (RunResultMismatch (nestedPath <> ": " <> failure))
              Right (scenario, recorded) ->
                let effective = effectiveOutcome manifest.outcome True recorded
                    override = if manifest.outcome == InfrastructureFailure || effective /= recorded then Just (reasonFor cellResult.reasons) else Nothing
                 in Right (RunLink identifier nestedPath scenario (digest nestedManifest) recorded effective override)
          case sequence indexed of
            Left problem -> pure (Left (problem :| []))
            Right runs -> do
              now <- getCurrentTime
              pure (Right (CellRunIndex manifest.runId manifest.cell manifest.leaseId manifest.leaseSequence base (base <> "/output") linked manifest.outcome cellResult.reasons cellResult.entryExitCode evidence runs now))

writeCellRunIndex :: FilePath -> CellRunIndex -> IO FilePath
writeCellRunIndex tree index = do
  let destination = takeDirectory tree </> "cell-run.json"
  bracket (openBinaryTempFile (takeDirectory tree) ".kenshou-cell-run-") cleanup \(temporary, handle) -> do
    hClose handle
    LazyByteString.writeFile temporary (encode index)
    renameFile temporary destination
    pure destination
  where
    cleanup (temporary, _) = do
      exists <- doesFileExist temporary
      if exists then removeFile temporary else pure ()

nestedRuns :: [Artifact] -> [(RunId, Text)]
nestedRuns artifacts =
  [ (identifier, "output/" <> renderRunId identifier)
  | artifact <- artifacts,
    ["output", rendered, "manifest.json"] <- [Text.splitOn "/" artifact.path],
    Right identifier <- [parseRunId rendered]
  ]

runFields :: LazyByteString.ByteString -> Either Text (Text, Outcome)
runFields bytes = case eitherDecode bytes :: Either String Value of
  Left failure -> Left (Text.pack failure)
  Right (Aeson.Object fields) -> case (KeyMap.lookup "scenario" fields, KeyMap.lookup "outcome" fields) of
    (Just (Aeson.String scenario), Just verdict) -> case Aeson.fromJSON verdict of
      Aeson.Success outcome -> Right (scenario, outcome)
      Aeson.Error failure -> Left (Text.pack failure)
    _ -> Left "scenario or outcome is missing"
  Right _ -> Left "run result is not an object"

evidenceKind :: Text -> Maybe Text
evidenceKind "cell/fingerprint.json" = Just "cell-fingerprint"
evidenceKind "cell/health.json" = Just "cell-health"
evidenceKind "cell/reset-evidence.json" = Just "cell-reset-evidence"
evidenceKind "metrics/export.jsonl.zst" = Just "cell-metrics-export"
evidenceKind _ = Nothing

reasonFor :: [Text] -> Text
reasonFor [] = "cell-infrastructure-failure"
reasonFor reasons = Text.intercalate "; " reasons

digest :: LazyByteString.ByteString -> Text
digest = TextEncoding.decodeUtf8 . Base16.encode . SHA256.hashlazy
