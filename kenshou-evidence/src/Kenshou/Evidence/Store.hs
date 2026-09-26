module Kenshou.Evidence.Store
  ( ObjectStat (..),
    ObjectStore (..),
    StoreError (..),
    PutResult (..),
    durableSchemes,
    directoryStore,
    memoryStore,
  )
where

import Control.Concurrent.MVar (modifyMVar, newMVar, readMVar)
import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Evidence.Types (Sha256, sha256Bytes)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempFile)
import System.Posix.Files (createLink)

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
    invalidSegment part = Text.null part || part == "." || part == ".." || Text.any (== '\\') part

ioResult :: IO value -> IO (Either StoreError value)
ioResult action = do
  result <- try action
  pure $ case result of
    Left err -> Left (StoreIo (Text.pack (show (err :: IOException))))
    Right value -> Right value

joinEither :: Either error (Either error value) -> Either error value
joinEither = either Left id
