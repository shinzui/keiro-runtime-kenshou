module Kenshou.Remote.Store.File (newFileStore) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (bracket)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON (..), ToJSON, eitherDecodeFileStrict', encodeFile, withObject, (.!=), (.:), (.:?))
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getFileSize, listDirectory, renameFile)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.IO (LockRequest (..), OpenFileFlags (creat), OpenMode (ReadWrite), closeFd, defaultFileFlags, openFd, waitToSetLock)

data StoredMeta = StoredMeta
  { name :: !Text,
    generation :: !Int64,
    size :: !Int64,
    updated :: !UTCTime,
    present :: !Bool,
    contentType :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

instance FromJSON StoredMeta where
  parseJSON = withObject "cell object metadata" \value ->
    StoredMeta
      <$> value .: "name"
      <*> value .: "generation"
      <*> value .: "size"
      <*> value .: "updated"
      <*> value .: "present"
      <*> (value .:? "contentType" .!= "application/octet-stream")

newFileStore :: FilePath -> IO ObjectStore
newFileStore root = do
  let localLock = processLock
  let stat bucket object = withObjectLock localLock root bucket object \bucketRoot hash -> fmap public <$> readMeta bucketRoot object hash
      get bucket object = withObjectLock localLock root bucket object \bucketRoot hash -> do
        current <- readMeta bucketRoot object hash
        case current of
          Nothing -> pure Nothing
          Just meta -> do
            bytes <- ByteString.readFile (dataPath bucketRoot hash meta.generation)
            pure (Just (LazyByteString.fromStrict bytes, public meta))
      write bucket object media pre writeData = withObjectLock localLock root bucket object \bucketRoot hash -> do
        current <- readStoredMeta bucketRoot object hash
        if not (preconditionHolds current pre)
          then pure PreconditionFailed
          else do
            now <- getCurrentTime
            let next = maybe 1 ((+ 1) . (.generation)) current
                destination = dataPath bucketRoot hash next
            createDirectoryIfMissing True (takeDirectory destination)
            bytes <- writeData destination
            let meta = StoredMeta object.unObjectName next bytes now True media
            writeMeta bucketRoot hash meta
            pure (Written (public meta))
      delete bucket object pre = withObjectLock localLock root bucket object \bucketRoot hash -> do
        current <- readStoredMeta bucketRoot object hash
        if not (preconditionHolds current pre)
          then pure False
          else case current of
            Nothing -> pure True
            Just prior -> do
              now <- getCurrentTime
              writeMeta bucketRoot hash prior {generation = prior.generation + 1, updated = now, present = False}
              pure True
      list bucket prefix = withBucketLock localLock root bucket \bucketRoot -> do
        let metaDirectory = bucketRoot </> "meta"
        createDirectoryIfMissing True metaDirectory
        files <- filter ((== ".json") . takeExtension) <$> listDirectory metaDirectory
        records <- mapM (readMetaFile . (metaDirectory </>)) files
        pure (sortOn fst [(ObjectName meta.name, public meta) | meta <- records, meta.present, prefix `Text.isPrefixOf` meta.name])
  pure
    ObjectStore
      { getObject = get,
        statObject = stat,
        putObject = \bucket object media pre bytes -> write bucket object media pre \destination -> do
          LazyByteString.writeFile destination bytes
          pure (LazyByteString.length bytes),
        putFile = \bucket object media pre source -> write bucket object media pre \destination -> do
          copyFile source destination
          fromIntegral <$> getFileSize destination,
        downloadTo = \bucket object destination -> withObjectLock localLock root bucket object \bucketRoot hash -> do
          current <- readMeta bucketRoot object hash
          case current of
            Nothing -> pure Nothing
            Just meta -> do
              createDirectoryIfMissing True (takeDirectory destination)
              copyFile (dataPath bucketRoot hash meta.generation) destination
              pure (Just (public meta)),
        deleteObject = delete,
        listObjects = list,
        serverTime = getCurrentTime
      }

-- POSIX record locks are per process, so separate handles in one process also
-- share a local mutex before taking the cross-process lock.
{-# NOINLINE processLock #-}
processLock :: MVar ()
processLock = unsafePerformIO (newMVar ())

withObjectLock :: MVar () -> FilePath -> Bucket -> ObjectName -> (FilePath -> FilePath -> IO a) -> IO a
withObjectLock localLock root bucket object action = withBucketLock localLock root bucket \bucketRoot -> do
  validateName object
  action bucketRoot (key object)

withBucketLock :: MVar () -> FilePath -> Bucket -> (FilePath -> IO a) -> IO a
withBucketLock localLock root bucket action = do
  bucketRoot <- bucketPath root bucket
  createDirectoryIfMissing True bucketRoot
  modifyMVar localLock \state -> do
    result <- bracket (openFd (bucketRoot </> ".lock") ReadWrite defaultFileFlags {creat = Just 0o600}) closeFd \fd -> do
      waitToSetLock fd (WriteLock, AbsoluteSeek, 0, 0)
      action bucketRoot
    pure (state, result)

bucketPath :: FilePath -> Bucket -> IO FilePath
bucketPath root bucket
  | not (Text.null bucket.unBucket) && Text.all valid bucket.unBucket = pure (root </> "buckets" </> Text.unpack bucket.unBucket)
  | otherwise = ioError (userError "invalid cell bucket name")
  where
    valid character = ('a' <= character && character <= 'z') || ('A' <= character && character <= 'Z') || ('0' <= character && character <= '9') || character `elem` ['-', '_']

validateName :: ObjectName -> IO ()
validateName object
  | Text.null value || Text.any (== '\\') value || any invalid (Text.splitOn "/" value) = ioError (userError "invalid cell object name")
  | otherwise = pure ()
  where
    value = object.unObjectName
    invalid part = Text.null part || part == "." || part == ".."

key :: ObjectName -> FilePath
key = Text.unpack . Text.decodeUtf8 . Base16.encode . SHA256.hash . Text.encodeUtf8 . (.unObjectName)

metaPath :: FilePath -> FilePath -> FilePath
metaPath bucketRoot hash = bucketRoot </> "meta" </> hash <> ".json"

dataPath :: FilePath -> FilePath -> Int64 -> FilePath
dataPath bucketRoot hash generation = bucketRoot </> "objects" </> hash </> show generation

readStoredMeta :: FilePath -> ObjectName -> FilePath -> IO (Maybe StoredMeta)
readStoredMeta bucketRoot object hash = do
  let path = metaPath bucketRoot hash
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      meta <- readMetaFile path
      if meta.name == object.unObjectName
        then pure (Just meta)
        else ioError (userError "cell object metadata key collision")

readMeta :: FilePath -> ObjectName -> FilePath -> IO (Maybe StoredMeta)
readMeta bucketRoot object hash = do
  meta <- readStoredMeta bucketRoot object hash
  pure (meta >>= \record -> if record.present then Just record else Nothing)

readMetaFile :: FilePath -> IO StoredMeta
readMetaFile path = either (ioError . userError) pure =<< eitherDecodeFileStrict' path

writeMeta :: FilePath -> FilePath -> StoredMeta -> IO ()
writeMeta bucketRoot hash meta = do
  let destination = metaPath bucketRoot hash
      temporary = destination <> ".writing"
  createDirectoryIfMissing True (takeDirectory destination)
  encodeFile temporary meta
  renameFile temporary destination

public :: StoredMeta -> ObjectMeta
public meta = ObjectMeta meta.generation meta.size meta.updated meta.contentType

preconditionHolds :: Maybe StoredMeta -> Precondition -> Bool
preconditionHolds _ NoPrecondition = True
preconditionHolds current DoesNotExist = maybe True (not . (.present)) current
preconditionHolds current (GenerationIs expected) = maybe False (\meta -> meta.present && meta.generation == expected) current
