module Kenshou.Evidence.Store
  ( ObjectStat (..),
    ObjectStore (..),
    StoreError (..),
    PutResult (..),
    durableSchemes,
    validateObjectUri,
    directoryStore,
    memoryStore,
    gcloudStore,
    gcloudStoreWith,
  )
where

import Control.Concurrent.MVar (modifyMVar, newMVar, readMVar)
import Control.Exception (IOException, try)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kenshou.Evidence.Types (Sha256 (..), mkSha256, sha256Bytes)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempFile)
import System.Posix.Files (createLink)
import System.Process (proc, readCreateProcessWithExitCode)
import Text.Read (readMaybe)

data ObjectStat = ObjectStat
  { bytes :: !Natural,
    recordedSha256 :: !(Maybe Sha256)
  }
  deriving stock (Eq, Show)

data StoreError
  = InvalidObjectUri !Text
  | StoreIo !Text
  | ObjectConflict !Text
  deriving stock (Eq, Show)

data PutResult = ObjectCreated | ObjectPresent deriving stock (Eq, Show)

data ObjectStore = ObjectStore
  { statObject :: Text -> IO (Either StoreError (Maybe ObjectStat)),
    fetchObject :: Text -> FilePath -> IO (Either StoreError ()),
    putObjectIfAbsent :: FilePath -> Text -> Text -> IO (Either StoreError PutResult)
  }

durableSchemes :: [Text]
durableSchemes = ["gs"]

validateObjectUri :: Text -> Either StoreError ()
validateObjectUri = fmap (const ()) . objectPath ""

-- | The scratch store preserves the gs:// URI in records while keeping the
-- bytes under root/bucket/key. Create-only publication uses an atomic hard link.
directoryStore :: FilePath -> ObjectStore
directoryStore root =
  ObjectStore
    { statObject = \uri -> withPath uri $ \path -> ioResult do
        exists <- doesFileExist path
        if exists then Just . objectStat <$> ByteString.readFile path else pure Nothing,
      fetchObject = \uri target -> withPath uri $ \path ->
        joinEither <$> ioResult do
          exists <- doesFileExist path
          if not exists
            then pure (Left (StoreIo ("object does not exist: " <> uri)))
            else do
              createDirectoryIfMissing True (takeDirectory target)
              ByteString.readFile path >>= ByteString.writeFile target
              pure (Right ()),
      putObjectIfAbsent = \source uri _mediaType -> withPath uri $ \path -> do
        loaded <- ioResult (ByteString.readFile source)
        case loaded of
          Left err -> pure (Left err)
          Right contents ->
            joinEither <$> ioResult do
              let parent = takeDirectory path
              createDirectoryIfMissing True parent
              withTempFile parent ".kenshou-object-" $ \temporary handle -> do
                ByteString.hPut handle contents
                hFlush handle
                linked <- try (createLink temporary path)
                case linked of
                  Right () -> pure (Right ObjectCreated)
                  Left err
                    | isAlreadyExistsError err -> do
                        present <- ByteString.readFile path
                        pure $ if present == contents then Right ObjectPresent else Left (ObjectConflict uri)
                    | otherwise -> pure (Left (StoreIo (Text.pack (show (err :: IOException)))))
    }
  where
    withPath :: Text -> (FilePath -> IO (Either StoreError value)) -> IO (Either StoreError value)
    withPath uri action = case objectPath root uri of
      Left err -> pure (Left err)
      Right path -> action path

memoryStore :: IO ObjectStore
memoryStore = do
  objects <- newMVar Map.empty
  pure
    ObjectStore
      { statObject = \uri -> case objectPath "" uri of
          Left err -> pure (Left err)
          Right _ -> do
            contents <- Map.lookup uri <$> readMVar objects
            pure (Right (objectStat <$> contents)),
        fetchObject = \uri target -> case objectPath "" uri of
          Left err -> pure (Left err)
          Right _ -> do
            contents <- Map.lookup uri <$> readMVar objects
            case contents of
              Nothing -> pure (Left (StoreIo ("object does not exist: " <> uri)))
              Just bytes -> ioResult do
                createDirectoryIfMissing True (takeDirectory target)
                ByteString.writeFile target bytes,
        putObjectIfAbsent = \source uri _mediaType -> case objectPath "" uri of
          Left err -> pure (Left err)
          Right _ -> do
            loaded <- ioResult (ByteString.readFile source)
            case loaded of
              Left err -> pure (Left err)
              Right contents -> modifyMVar objects $ \current ->
                case Map.lookup uri current of
                  Nothing -> pure (Map.insert uri contents current, Right ObjectCreated)
                  Just old | old == contents -> pure (current, Right ObjectPresent)
                  Just _ -> pure (current, Left (ObjectConflict uri))
      }

-- | The production adapter accepts only the explicitly selected GCP project.
-- The executable seam lets tests exercise the command protocol without cloud
-- credentials or remote mutations.
gcloudStore :: Text -> ObjectStore
gcloudStore = gcloudStoreWith "gcloud"

gcloudStoreWith :: FilePath -> Text -> ObjectStore
gcloudStoreWith executable project = store
  where
    store =
      ObjectStore
        { statObject = \uri -> do
            ready <- preflight
            case ready of
              Left err -> pure (Left err)
              Right () -> stat uri,
          fetchObject = \uri target -> do
            ready <- preflight
            case ready of
              Left err -> pure (Left err)
              Right () -> case validateObjectUri uri of
                Left err -> pure (Left err)
                Right () -> do
                  prepared <- ioResult (createDirectoryIfMissing True (takeDirectory target))
                  case prepared of
                    Left err -> pure (Left err)
                    Right () -> do
                      result <- command ["storage", "cp", Text.unpack uri, target, projectFlag, "--quiet"]
                      pure $ case result of
                        Left err -> Left err
                        Right _ -> Right (),
          putObjectIfAbsent = \source uri mediaType -> do
            ready <- preflight
            case ready of
              Left err -> pure (Left err)
              Right () -> case validateObjectUri uri of
                Left err -> pure (Left err)
                Right () -> do
                  local <- ioResult (ByteString.readFile source)
                  case local of
                    Left err -> pure (Left err)
                    Right contents -> do
                      let expected = objectStat contents
                      existing <- stat uri
                      case existing of
                        Left err -> pure (Left err)
                        Right (Just observed) -> pure (if observed == expected then Right ObjectPresent else Left (ObjectConflict uri))
                        Right Nothing -> do
                          let Sha256 digest = sha256Bytes contents
                          uploaded <- command ["storage", "cp", source, Text.unpack uri, "--if-generation-match=0", "--custom-metadata=kenshou-sha256=" <> Text.unpack digest, "--content-type=" <> Text.unpack mediaType, projectFlag, "--quiet"]
                          after <- stat uri
                          pure case after of
                            Left err -> Left err
                            Right (Just observed)
                              | observed == expected -> Right (if either (const False) (const True) uploaded then ObjectCreated else ObjectPresent)
                              | otherwise -> Left (ObjectConflict uri)
                            Right Nothing -> either Left (const (Left (StoreIo ("uploaded object is not visible: " <> uri)))) uploaded
        }

    projectFlag = "--project=" <> Text.unpack project

    preflight = do
      if Text.null project
        then pure (Left (StoreIo "GCP project must be explicit"))
        else do
          active <- command ["config", "get-value", "project"]
          pure case active of
            Left err -> Left err
            Right value
              | Text.strip value == project -> Right ()
              | otherwise -> Left (StoreIo ("active GCP project differs from requested project " <> project))

    stat uri = case validateObjectUri uri of
      Left err -> pure (Left err)
      Right () -> do
        result <- command ["storage", "objects", "describe", Text.unpack uri, "--format=json", projectFlag, "--quiet"]
        pure case result of
          Left (StoreIo message) | missingObject message -> Right Nothing
          Left err -> Left err
          Right output -> Just <$> parseGcloudStat output

    command arguments = do
      executed <- try (readCreateProcessWithExitCode (proc executable arguments) "") :: IO (Either IOException (ExitCode, String, String))
      pure case executed of
        Left err -> Left (StoreIo (Text.pack (show err)))
        Right (ExitSuccess, output, _) -> Right (Text.pack output)
        Right (ExitFailure code, _, stderrText) -> Left (StoreIo ("gcloud exited " <> Text.pack (show code) <> ": " <> Text.take 1200 (Text.pack stderrText)))

missingObject :: Text -> Bool
missingObject message = any (`Text.isInfixOf` Text.toCaseFold message) ["not_found", "not found", "404", "no urls matched"]

parseGcloudStat :: Text -> Either StoreError ObjectStat
parseGcloudStat output = do
  value <- either (Left . StoreIo . Text.pack) Right (eitherDecodeStrict' (Text.encodeUtf8 output))
  case value of
    Object fields -> do
      sizeValue <- maybe (Left (StoreIo "gcloud object description has no size")) Right (KeyMap.lookup "size" fields)
      size <- case sizeValue of
        String raw -> parseSize raw
        Number _ -> case (fromJSON sizeValue :: Result Integer) of
          Success number | number >= 0 -> Right (fromInteger number)
          _ -> Left (StoreIo "gcloud object size is invalid")
        _ -> Left (StoreIo "gcloud object size is not numeric")
      let customMetadata = case KeyMap.lookup "custom_fields" fields of
            Just metadataValue -> Just metadataValue
            Nothing -> KeyMap.lookup "metadata" fields
      digest <- case customMetadata of
        Nothing -> Right Nothing
        Just (Object metadata) -> case KeyMap.lookup "kenshou-sha256" metadata of
          Nothing -> Right Nothing
          Just (String raw) -> Just <$> either (Left . StoreIo) Right (mkSha256 raw)
          _ -> Left (StoreIo "gcloud object digest metadata is not text")
        _ -> Left (StoreIo "gcloud object custom metadata is not an object")
      Right ObjectStat {bytes = size, recordedSha256 = digest}
    _ -> Left (StoreIo "gcloud object description is not an object")
  where
    parseSize raw = case readMaybe (Text.unpack raw) :: Maybe Integer of
      Just value | value >= 0 -> Right (fromInteger value)
      _ -> Left (StoreIo "gcloud object size is invalid")

objectStat :: ByteString -> ObjectStat
objectStat contents =
  ObjectStat
    { bytes = fromIntegral (ByteString.length contents),
      recordedSha256 = Just (sha256Bytes contents)
    }

objectPath :: FilePath -> Text -> Either StoreError FilePath
objectPath root uri = do
  rest <- maybe (Left (InvalidObjectUri uri)) Right (Text.stripPrefix "gs://" uri)
  let segments = Text.splitOn "/" rest
  if length segments < 2 || any invalidSegment segments
    then Left (InvalidObjectUri uri)
    else Right (foldl (</>) root (Text.unpack <$> segments))
  where
    invalidSegment part =
      Text.null part
        || part == "."
        || part == ".."
        || Text.any (`elem` ['\\', '?', '#']) part

ioResult :: IO value -> IO (Either StoreError value)
ioResult action = do
  result <- try action
  pure $ case result of
    Left err -> Left (StoreIo (Text.pack (show (err :: IOException))))
    Right value -> Right value

joinEither :: Either error (Either error value) -> Either error value
joinEither = either Left id
