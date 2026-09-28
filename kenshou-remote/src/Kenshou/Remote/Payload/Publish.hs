module Kenshou.Remote.Payload.Publish
  ( BundlePublishError (..),
    publishBundle,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (eitherDecode, encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import System.IO (IOMode (..), withBinaryFile)

data BundlePublishError
  = InvalidPayloadDescriptor !Text
  | BundleOutsideControlBucket !Text
  | BundleBytesMismatch !Int64 !Int64
  | BundleDigestMismatch !Text !Text
  | ExistingBundleSizeMismatch !Int64 !Int64
  deriving stock (Eq, Show)

-- The caller supplies a finished export file and descriptor. The object name is
-- derived from the checked digest, so a retry can only target the same key.
publishBundle :: ObjectStore -> Bucket -> PayloadDescriptor -> FilePath -> IO (Either BundlePublishError PayloadDescriptor)
publishBundle store bucket descriptor source = case eitherDecode (encode descriptor) :: Either String PayloadDescriptor of
  Left failure -> pure (Left (InvalidPayloadDescriptor (Text.pack failure)))
  Right _ -> do
    let bundle = descriptor.cell.bundle
        expectedUri = "gs://" <> bucket.unBucket <> "/payloads/sha256/" <> bundle.sha256 <> ".nar.zst"
        object = ObjectName ("payloads/sha256/" <> bundle.sha256 <> ".nar.zst")
    if bundle.uri /= expectedUri
      then pure (Left (BundleOutsideControlBucket bundle.uri))
      else do
        (actualDigest, actualBytes) <- digestFile source
        if actualBytes /= bundle.bytes
          then pure (Left (BundleBytesMismatch bundle.bytes actualBytes))
          else
            if actualDigest /= bundle.sha256
              then pure (Left (BundleDigestMismatch bundle.sha256 actualDigest))
              else do
                uploaded <- store.putFile bucket object "application/zstd" DoesNotExist source
                case uploaded of
                  Written meta -> pure (checkSize bundle.bytes meta.size)
                  PreconditionFailed -> do
                    existing <- store.statObject bucket object
                    pure case existing of
                      Just meta -> checkSize bundle.bytes meta.size
                      Nothing -> Left (ExistingBundleSizeMismatch bundle.bytes (-1))
  where
    checkSize expected actual
      | actual == expected = Right descriptor
      | otherwise = Left (ExistingBundleSizeMismatch expected actual)

digestFile :: FilePath -> IO (Text, Int64)
digestFile path = withBinaryFile path ReadMode (go SHA256.init 0)
  where
    go context size handle = do
      chunk <- ByteString.hGetSome handle (1024 * 1024)
      if ByteString.null chunk
        then pure (TextEncoding.decodeUtf8 (Base16.encode (SHA256.finalize context)), size)
        else go (SHA256.update context chunk) (size + fromIntegral (ByteString.length chunk)) handle
