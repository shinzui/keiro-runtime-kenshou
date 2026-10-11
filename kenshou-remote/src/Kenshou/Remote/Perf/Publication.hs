module Kenshou.Remote.Perf.Publication (publishEvidence, verifyPublication) where

import Control.Exception (IOException, bracket, displayException, try)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict')
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Perf.Artifacts (verifyPerfManifest)
import Kenshou.Remote.Payload.Publish (digestFile)
import Kenshou.Remote.Store
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openBinaryTempFile)

-- Manifest is published last. Every object is create-only, and even existing
-- objects are retrieved and hashed. Successful upload metadata is insufficient.
publishEvidence :: ObjectStore -> Bucket -> Text -> FilePath -> IO (Either Text Text)
publishEvidence store bucket prefix directory = protected do
  validatePrefix prefix
  checked <- verifyPerfManifest directory >>= require
  checked `seq` pure ()
  files <- publicationFiles directory
  mapM_ publish files
  require =<< verifyPublication store bucket prefix directory
  pure ("gs://" <> bucket.unBucket <> "/" <> prefix <> "/manifest.json")
  where
    publish (relative, _, _, media) = do
      result <- store.putFile bucket (object relative) media DoesNotExist (directory </> relative)
      case result of
        Written _ -> pure ()
        PreconditionFailed -> pure ()
    object relative = ObjectName (prefix <> "/" <> Text.pack relative)

verifyPublication :: ObjectStore -> Bucket -> Text -> FilePath -> IO (Either Text ())
verifyPublication store bucket prefix directory = protected do
  validatePrefix prefix
  verifyPerfManifest directory >>= require
  files <- publicationFiles directory
  temporaryDirectory <- getTemporaryDirectory
  bracket (openBinaryTempFile temporaryDirectory "kenshou-perf-retrieval-") (removeFile . fst) \(temporary, handle) -> do
    hClose handle
    mapM_ (check temporary) files
  where
    check temporary (relative, expected, bytes, _) = do
      present <- store.downloadTo bucket (ObjectName (prefix <> "/" <> Text.pack relative)) temporary
      unless (present /= Nothing) (ioError (userError ("published artifact is missing: " <> relative)))
      (actual, actualBytes) <- digestFile temporary
      unless (actual == expected && toInteger actualBytes == bytes) (ioError (userError ("published artifact differs: " <> relative)))

publicationFiles :: FilePath -> IO [(FilePath, Text, Integer, Text)]
publicationFiles directory = do
  manifest <- eitherDecodeFileStrict' (directory </> "manifest.json") >>= either (ioError . userError) pure
  (digest, bytes) <- digestFile (directory </> "manifest.json")
  pure
    ( [(file.path, Text.drop 7 file.sha256, file.bytes, file.mediaType) | file <- (manifest :: Manifest).files]
        <> [("manifest.json", digest, toInteger bytes, "application/json")]
    )

validatePrefix :: Text -> IO ()
validatePrefix prefix =
  unless
    ( not (Text.null prefix)
        && all (\part -> not (Text.null part) && part `notElem` [".", ".."]) (Text.splitOn "/" prefix)
        && not (Text.any (`elem` ['\\', '\n', '\r', '?', '#']) prefix)
    )
    (ioError (userError "unsafe performance publication prefix"))

require :: Either Text a -> IO a
require = either (ioError . userError . Text.unpack) pure

protected :: IO a -> IO (Either Text a)
protected action = either (Left . Text.pack . displayException) Right <$> try @IOException action
