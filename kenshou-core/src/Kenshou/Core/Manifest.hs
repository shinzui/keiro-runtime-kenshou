module Kenshou.Core.Manifest
  ( ManifestFile (..),
    Manifest (..),
    ManifestProblem (..),
    writeManifest,
    verifyManifest,
  )
where

import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (RunId)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (makeRelative, takeExtension, (</>))

data ManifestFile = ManifestFile {path :: FilePath, sha256 :: Text, bytes :: Integer, mediaType :: Text} deriving stock (Eq, Show)

data Manifest = Manifest {runId :: RunId, createdAt :: UTCTime, files :: [ManifestFile]} deriving stock (Eq, Show)

newtype ManifestProblem = ManifestProblem Text deriving stock (Eq, Show)

instance ToJSON ManifestFile where
  toJSON file = object ["path" .= file.path, "sha256" .= file.sha256, "bytes" .= file.bytes, "mediaType" .= file.mediaType]

instance FromJSON ManifestFile where
  parseJSON = withObject "ManifestFile" \value -> ManifestFile <$> value .: "path" <*> value .: "sha256" <*> value .: "bytes" <*> value .: "mediaType"

instance ToJSON Manifest where
  toJSON manifest = object ["schema" .= ("kenshou.artifact-manifest/v1" :: Text), "runId" .= manifest.runId, "createdAt" .= manifest.createdAt, "algorithm" .= ("sha256" :: Text), "files" .= manifest.files]

instance FromJSON Manifest where
  parseJSON = withObject "Manifest" \value -> do
    schema <- value .: "schema"
    algorithm <- value .: "algorithm"
    if schema /= ("kenshou.artifact-manifest/v1" :: Text) || algorithm /= ("sha256" :: Text) then fail "unsupported artifact manifest" else pure ()
    Manifest <$> value .: "runId" <*> value .: "createdAt" <*> value .: "files"

writeManifest :: FilePath -> RunId -> Map FilePath Text -> IO Manifest
writeManifest root runId mediaTypes = do
  paths <- filter (/= "manifest.json") . sort <$> regularFiles root
  files <- traverse fileRecord paths
  createdAt <- getCurrentTime
  pure Manifest {runId, createdAt, files}
  where
    fileRecord relativePath = do
      content <- ByteString.readFile (root </> relativePath)
      pure ManifestFile {path = relativePath, sha256 = sha256Hex content, bytes = fromIntegral (ByteString.length content), mediaType = Map.findWithDefault (mediaTypeFor relativePath) relativePath mediaTypes}

verifyManifest :: FilePath -> IO (Either (NonEmpty ManifestProblem) ())
verifyManifest root = do
  decoded <- eitherDecodeFileStrict' (root </> "manifest.json") :: IO (Either String Manifest)
  case decoded of
    Left err -> pure (Left (ManifestProblem ("manifest.json: " <> Text.pack err) :| []))
    Right manifest -> do
      problems <- concat <$> traverse checkFile manifest.files
      pure case problems of [] -> Right (); first : rest -> Left (first :| rest)
  where
    checkFile :: ManifestFile -> IO [ManifestProblem]
    checkFile file = do
      let fullPath = root </> file.path
      exists <- doesFileExist fullPath
      if not exists
        then pure [ManifestProblem (Text.pack file.path <> ": missing")]
        else do
          content <- ByteString.readFile fullPath
          pure [ManifestProblem (Text.pack file.path <> ": digest mismatch") | sha256Hex content /= file.sha256]

regularFiles :: FilePath -> IO [FilePath]
regularFiles root = go root
  where
    go directory = do
      names <- listDirectory directory
      concat <$> traverse (visit directory) names
    visit directory name = do
      let path = directory </> name
      isDirectory <- doesDirectoryExist path
      if isDirectory then go path else pure [makeRelative root path]

mediaTypeFor :: FilePath -> Text
mediaTypeFor path = case takeExtension path of
  ".json" -> "application/json"
  ".jsonl" -> "application/x-ndjson"
  ".csv" -> "text/csv"
  ".log" -> "text/plain"
  ".txt" -> "text/plain"
  _ -> "application/octet-stream"
