module Kenshou.Remote.Store.Gcs
  ( TokenProvider (..),
    newTokenProvider,
    newTokenProviderWith,
    newGcsStore,
    newGcsStoreAt,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (bracket, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), decode, eitherDecode, withObject, (.:), (.:?))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import Network.HTTP.Client (BodyReader, HttpException, Request (..), RequestBody (..), Response, brRead, httpLbs, newManager, parseRequest, responseBody, responseHeaders, responseStatus, responseTimeoutMicro, withResponse)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removeFile, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory)
import System.IO (Handle, IOMode (..), SeekMode (AbsoluteSeek), hClose, hIsClosed, hSeek, openBinaryTempFile, withBinaryFile)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

data TokenProvider = TokenProvider
  { controlBucket :: !Bucket,
    accessToken :: IO Text
  }

newTokenProvider :: Bucket -> IO TokenProvider
newTokenProvider bucket = do
  manager <- newManager tlsManagerSettings
  request <- parseRequest "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  newTokenProviderWith
    bucket
    (fmap Text.pack <$> lookupEnv "KENSHOU_GCS_TOKEN")
    ( do
        let metadataRequest = request {requestHeaders = [("Metadata-Flavor", "Google")], responseTimeout = responseTimeoutMicro 2000000}
        response <- try (httpLbs metadataRequest manager) :: IO (Either HttpException (Response LazyByteString.ByteString))
        pure case response of
          Right value | statusCode (responseStatus value) == 200 -> (\token -> token.tokenResponse) <$> (decode (responseBody value) :: Maybe MetadataToken)
          _ -> Nothing
    )
    ( do
        (exit, output, _) <- readProcessWithExitCode "gcloud" ["auth", "print-access-token"] ""
        unless (exit == ExitSuccess) (ioError (userError "gcloud access-token command failed"))
        pure (Text.strip (Text.pack output))
    )

-- | Injection seam for the three credential sources; only CLI tokens are cached.
newTokenProviderWith :: Bucket -> IO (Maybe Text) -> IO (Maybe Text) -> IO Text -> IO TokenProvider
newTokenProviderWith bucket environment metadata cli = do
  cache <- newMVar Nothing
  let choose = do
        environment >>= \case
          Just token | validToken token -> pure token
          Just _ -> ioError (userError "invalid GCS environment token")
          Nothing -> modifyMVar cache \cached -> do
            now <- getCurrentTime
            case cached of
              Just (expiry, token) | now < expiry -> pure (cached, token)
              _ ->
                metadata >>= \case
                  Just token | validToken token -> pure (Nothing, token)
                  Just _ -> ioError (userError "invalid GCS metadata token")
                  Nothing -> do
                    token <- cli
                    unless (validToken token) (ioError (userError "invalid gcloud access token"))
                    pure (Just (addUTCTime (45 * 60) now, token), token)
  pure (TokenProvider bucket choose)

newtype MetadataToken = MetadataToken {tokenResponse :: Text}

instance FromJSON MetadataToken where
  parseJSON = withObject "GCE access token" \value -> MetadataToken <$> value .: "access_token"

data GcsObject = GcsObject
  { objectName :: !Text,
    objectMeta :: !ObjectMeta
  }

instance FromJSON GcsObject where
  parseJSON = withObject "GCS object" \value -> do
    name <- value .: "name"
    generationText <- value .: "generation"
    sizeText <- value .: "size"
    generation <- maybe (fail "invalid GCS generation") pure (readMaybe (Text.unpack generationText))
    size <- maybe (fail "invalid GCS size") pure (readMaybe (Text.unpack sizeText))
    updated <- value .: "updated"
    contentType <- fromMaybe "application/octet-stream" <$> value .:? "contentType"
    pure (GcsObject name (ObjectMeta generation size updated contentType))

data GcsPage = GcsPage
  { items :: ![GcsObject],
    nextPageToken :: !(Maybe Text)
  }

instance FromJSON GcsPage where
  parseJSON = withObject "GCS objects page" \value -> GcsPage <$> (fromMaybe [] <$> value .:? "items") <*> value .:? "nextPageToken"

newGcsStore :: TokenProvider -> IO ObjectStore
newGcsStore = newGcsStoreAt "https://storage.googleapis.com"

-- | The endpoint seam keeps the HTTP protocol testable against a local server.
newGcsStoreAt :: Text -> TokenProvider -> IO ObjectStore
newGcsStoreAt endpoint provider = do
  unless ("http://" `Text.isPrefixOf` endpoint || "https://" `Text.isPrefixOf` endpoint) (ioError (userError "invalid GCS endpoint"))
  manager <- newManager tlsManagerSettings
  let base = Text.dropWhileEnd (== '/') endpoint
      runRequest verb url body headers = do
        token <- provider.accessToken
        unless (validToken token) (ioError (userError "invalid GCS token"))
        initial <- parseRequest (Text.unpack url)
        retryResponse $
          httpLbs
            initial
              { method = verb,
                requestHeaders = ("Authorization", "Bearer " <> TextEncoding.encodeUtf8 token) : headers,
                requestBody = body
              }
            manager
      metadata bucket object = do
        url <- objectUrl base bucket object
        response <- runRequest "GET" url (RequestBodyBS ByteString.empty) []
        case statusCode (responseStatus response) of
          404 -> pure Nothing
          200 -> Just . (\item -> item.objectMeta) <$> decodeObject object (responseBody response)
          code -> badStatus "reading GCS metadata" code
      get bucket object = do
        current <- metadata bucket object
        case current of
          Nothing -> pure Nothing
          Just meta -> do
            url <- objectUrl base bucket object
            response <- runRequest "GET" (url <> "?alt=media&generation=" <> tshow meta.generation) (RequestBodyBS ByteString.empty) []
            case statusCode (responseStatus response) of
              200 -> do
                let bytes = responseBody response
                unless (LazyByteString.length bytes == meta.size) (ioError (userError "GCS media length differs from metadata"))
                pure (Just (bytes, meta))
              code -> badStatus "reading GCS media" code
      upload bucket object media pre body = do
        url <- uploadUrl base bucket object pre "media"
        response <- runRequest "POST" url body [("Content-Type", TextEncoding.encodeUtf8 media)]
        putResponse object response
      download bucket object destination = do
        current <- metadata bucket object
        case current of
          Nothing -> pure Nothing
          Just meta -> do
            url <- objectUrl base bucket object
            token <- provider.accessToken
            unless (validToken token) (ioError (userError "invalid GCS token"))
            initial <- parseRequest (Text.unpack (url <> "?alt=media&generation=" <> tshow meta.generation))
            createDirectoryIfMissing True (takeDirectory destination)
            bracket
              (openBinaryTempFile (takeDirectory destination) ".kenshou-gcs-download")
              ( \(temporary, handle) -> do
                  closed <- hIsClosed handle
                  unless closed (hClose handle)
                  exists <- doesFileExist temporary
                  if exists then removeFile temporary else pure ()
              )
              \(temporary, handle) -> do
                (code, bytes) <- retryStatus $ withResponse initial {requestHeaders = [("Authorization", "Bearer " <> TextEncoding.encodeUtf8 token)]} manager \response -> do
                  let code = statusCode (responseStatus response)
                  if code == 200
                    then (\count -> (code, count)) <$> copyBody (responseBody response) handle
                    else pure (code, 0)
                unless (code == 200) (badStatus "downloading GCS media" code)
                unless (bytes == meta.size) (ioError (userError "GCS downloaded length differs from metadata"))
                hClose handle
                renameFile temporary destination
            pure (Just meta)
      putLargeFile bucket object media pre source size = do
        url <- uploadUrl base bucket object pre "resumable"
        response <- runRequest "POST" url (RequestBodyBS ByteString.empty) [("X-Upload-Content-Type", TextEncoding.encodeUtf8 media), ("X-Upload-Content-Length", ByteString.Char8.pack (show size))]
        case statusCode (responseStatus response) of
          412 -> pure PreconditionFailed
          code | code >= 200 && code < 300 -> do
            location <- maybe (ioError (userError "GCS resumable upload omitted Location")) (pure . TextEncoding.decodeUtf8) (lookup "Location" (responseHeaders response))
            token <- provider.accessToken
            unless (validToken token) (ioError (userError "invalid GCS token"))
            initial <- parseRequest (Text.unpack location)
            let headers = [("Authorization", "Bearer " <> TextEncoding.encodeUtf8 token), ("Content-Type", TextEncoding.encodeUtf8 media)]
                sendChunk offset failures = do
                  let lengthBytes = min (8 * 1024 * 1024) (size - offset)
                      lastByte = offset + lengthBytes - 1
                      range = "bytes " <> tshow offset <> "-" <> tshow lastByte <> "/" <> tshow size
                  result <- httpLbs initial {method = "PUT", requestHeaders = ("Content-Range", TextEncoding.encodeUtf8 range) : headers, requestBody = streamFileChunk source offset lengthBytes} manager
                  case statusCode (responseStatus result) of
                    200 -> putResponse object result
                    201 -> putResponse object result
                    412 -> pure PreconditionFailed
                    308 -> continueFrom offset failures result
                    transient | transient == 429 || transient >= 500 && transient <= 599 -> do
                      statusResult <- retryResponse $ httpLbs initial {method = "PUT", requestHeaders = ("Content-Range", "bytes */" <> ByteString.Char8.pack (show size)) : headers, requestBody = RequestBodyBS ByteString.empty} manager
                      case statusCode (responseStatus statusResult) of
                        200 -> putResponse object statusResult
                        201 -> putResponse object statusResult
                        308 -> continueFrom offset failures statusResult
                        other -> badStatus "querying GCS resumable upload" other
                    other -> badStatus "sending GCS resumable chunk" other
                continueFrom offset failures result = do
                  next <- case lookup "Range" (responseHeaders result) of
                    Nothing -> pure 0
                    Just value -> maybe (ioError (userError "invalid GCS resumable Range")) pure (parseRangeNext value)
                  unless (next <= size) (ioError (userError "GCS resumable Range exceeds file size"))
                  let stalled = if next <= offset then failures + 1 else 0
                  unless (stalled < 4) (ioError (userError "GCS resumable upload made no progress"))
                  unless (next < size) (ioError (userError "GCS resumable upload lacks final metadata"))
                  sendChunk next stalled
            sendChunk 0 (0 :: Int)
          code -> badStatus "starting GCS resumable upload" code
      list bucket prefix = do
        listUrl <- bucketUrl base bucket
        let loop token accumulated = do
              let parameters = "?prefix=" <> encodeComponent prefix <> "&maxResults=1000" <> maybe "" ("&pageToken=" <>) (encodeComponent <$> token)
              response <- runRequest "GET" (listUrl <> parameters) (RequestBodyBS ByteString.empty) []
              case statusCode (responseStatus response) of
                200 -> do
                  page <- decodeJson "GCS object list" (responseBody response) :: IO GcsPage
                  let entries = [(ObjectName item.objectName, item.objectMeta) | item <- page.items]
                  maybe (pure (accumulated <> entries)) (\next -> loop (Just next) (accumulated <> entries)) page.nextPageToken
                code -> badStatus "listing GCS objects" code
        loop Nothing []
      clock = do
        url <- bucketUrl base provider.controlBucket
        response <- runRequest "GET" (url <> "?maxResults=1") (RequestBodyBS ByteString.empty) []
        case statusCode (responseStatus response) of
          200 -> do
            date <- maybe (ioError (userError "GCS response omitted Date")) pure (lookup "Date" (responseHeaders response))
            maybe (ioError (userError "invalid GCS Date header")) pure (parseTimeM True defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" (ByteString.Char8.unpack date))
          code -> badStatus "reading GCS server time" code
  pure
    ObjectStore
      { getObject = get,
        statObject = metadata,
        putObject = \bucket object media pre bytes -> upload bucket object media pre (RequestBodyLBS bytes),
        putFile = \bucket object media pre source -> do
          size <- getFileSize source
          if size <= 8 * 1024 * 1024
            then do
              bytes <- LazyByteString.readFile source
              upload bucket object media pre (RequestBodyLBS bytes)
            else putLargeFile bucket object media pre source (fromIntegral size),
        downloadTo = download,
        deleteObject = \bucket object pre -> do
          url <- objectUrl base bucket object
          response <- runRequest "DELETE" (url <> preconditionQuery pre) (RequestBodyBS ByteString.empty) []
          case statusCode (responseStatus response) of
            204 -> pure True
            200 -> pure True
            404 -> pure False
            412 -> pure False
            code -> badStatus "deleting GCS object" code,
        listObjects = list,
        serverTime = clock
      }

putResponse :: ObjectName -> Response LazyByteString.ByteString -> IO PutOutcome
putResponse object response = case statusCode (responseStatus response) of
  412 -> pure PreconditionFailed
  code | code == 200 || code == 201 -> (\item -> Written item.objectMeta) <$> decodeObject object (responseBody response)
  code -> badStatus "uploading GCS object" code

retryResponse :: IO (Response body) -> IO (Response body)
retryResponse action = retryStatus ((\response -> (statusCode (responseStatus response), response)) <$> action) >>= pure . snd

retryStatus :: IO (Int, value) -> IO (Int, value)
retryStatus action = go (0 :: Int)
  where
    go attempts = do
      result@(code, _) <- action
      if attempts < 4 && (code == 429 || code >= 500 && code <= 599)
        then threadDelay (100000 * (2 ^ attempts)) >> go (attempts + 1)
        else pure result

decodeObject :: ObjectName -> LazyByteString.ByteString -> IO GcsObject
decodeObject object body = do
  result <- decodeJson "GCS object" body
  unless (result.objectName == object.unObjectName) (ioError (userError "GCS returned a different object name"))
  pure result

decodeJson :: (FromJSON value) => Text -> LazyByteString.ByteString -> IO value
decodeJson label bytes = either (ioError . userError . ((Text.unpack label <> ": ") <>)) pure (eitherDecode bytes)

badStatus :: Text -> Int -> IO value
badStatus operation code = ioError (userError (Text.unpack operation <> ": HTTP " <> show code))

bucketUrl :: Text -> Bucket -> IO Text
bucketUrl endpoint bucket = do
  unless (not (Text.null bucket.unBucket) && Text.all validBucketCharacter bucket.unBucket) (ioError (userError "invalid GCS bucket name"))
  pure (endpoint <> "/storage/v1/b/" <> bucket.unBucket <> "/o")

objectUrl :: Text -> Bucket -> ObjectName -> IO Text
objectUrl endpoint bucket object = do
  validateName object
  (<> "/" <> encodeComponent object.unObjectName) <$> bucketUrl endpoint bucket

uploadUrl :: Text -> Bucket -> ObjectName -> Precondition -> Text -> IO Text
uploadUrl endpoint bucket object pre uploadType = do
  validateName object
  root <- bucketUrl endpoint bucket
  pure (Text.replace "/storage/v1/" "/upload/storage/v1/" root <> "?uploadType=" <> uploadType <> "&name=" <> encodeComponent object.unObjectName <> preconditionSuffix pre)

preconditionQuery :: Precondition -> Text
preconditionQuery NoPrecondition = ""
preconditionQuery pre = "?" <> Text.drop 1 (preconditionSuffix pre)

preconditionSuffix :: Precondition -> Text
preconditionSuffix NoPrecondition = ""
preconditionSuffix DoesNotExist = "&ifGenerationMatch=0"
preconditionSuffix (GenerationIs generation) = "&ifGenerationMatch=" <> tshow generation

validateName :: ObjectName -> IO ()
validateName object = unless (not (Text.null value) && all validPart (Text.splitOn "/" value) && not (Text.any (== '\\') value)) (ioError (userError "invalid GCS object name"))
  where
    value = object.unObjectName
    validPart part = not (Text.null part) && part /= "." && part /= ".."

validBucketCharacter :: Char -> Bool
validBucketCharacter character = ('a' <= character && character <= 'z') || ('A' <= character && character <= 'Z') || ('0' <= character && character <= '9') || character `elem` ['.', '_', '-']

encodeComponent :: Text -> Text
encodeComponent = Text.concatMap encodeByte . TextEncoding.decodeLatin1 . TextEncoding.encodeUtf8
  where
    encodeByte character
      | ('a' <= character && character <= 'z') || ('A' <= character && character <= 'Z') || ('0' <= character && character <= '9') || character `elem` ['-', '_', '.', '~'] = Text.singleton character
      | otherwise = let raw = showHex (fromEnum character) "" in "%" <> Text.toUpper (Text.justifyRight 2 '0' (Text.pack raw))

validToken :: Text -> Bool
validToken token = not (Text.null (Text.strip token)) && not (Text.any (`elem` ['\r', '\n']) token)

tshow :: (Show value) => value -> Text
tshow = Text.pack . show

streamFileChunk :: FilePath -> Int64 -> Int64 -> RequestBody
streamFileChunk source offset size = RequestBodyStream size \consume -> withBinaryFile source ReadMode \handle -> do
  hSeek handle AbsoluteSeek (fromIntegral offset)
  remaining <- newIORef size
  consume do
    left <- readIORef remaining
    if left == 0
      then pure ByteString.empty
      else do
        chunk <- ByteString.hGetSome handle (fromIntegral (min left (1024 * 1024)))
        whenEmpty chunk
        writeIORef remaining (left - fromIntegral (ByteString.length chunk))
        pure chunk
  where
    whenEmpty chunk = unless (not (ByteString.null chunk)) (ioError (userError "GCS upload source shrank during transfer"))

parseRangeNext :: ByteString.ByteString -> Maybe Int64
parseRangeNext value = do
  suffix <- ByteString.Char8.stripPrefix "bytes=0-" value
  lastByte <- readMaybe (ByteString.Char8.unpack suffix)
  if lastByte >= 0 then Just (lastByte + 1) else Nothing

copyBody :: BodyReader -> Handle -> IO Int64
copyBody reader handle = go 0
  where
    go total = do
      chunk <- brRead reader
      if ByteString.null chunk
        then pure total
        else ByteString.hPut handle chunk >> go (total + fromIntegral (ByteString.length chunk))
