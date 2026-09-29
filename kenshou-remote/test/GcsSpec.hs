module GcsSpec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket, finally)
import Control.Monad (forever, unless, void)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kenshou.Remote.Store (Bucket (..), ObjectMeta (..), ObjectName (..), ObjectStore (..), Precondition (..), PutOutcome (..))
import Kenshou.Remote.Store.Gcs (TokenProvider (..), newGcsStoreAt, newTokenProviderWith)
import Network.Socket (Family (AF_INET), SockAddr (SockAddrInet), SocketType (Stream), accept, bind, close, defaultProtocol, getSocketName, listen, socket, socketToHandle, tupleToHostAddress)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO (BufferMode (NoBuffering), Handle, IOMode (ReadWriteMode), hClose, hSetBuffering)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

data MockResponse = MockResponse !Int ![(ByteString.ByteString, ByteString.ByteString)] !LazyByteString.ByteString

spec :: Spec
spec = describe "GCS cell object store" do
  it "prefers the explicit token, then VM metadata, and caches gcloud tokens" do
    calls <- newIORef (0 :: Int)
    let cli = modifyIORef' calls (+ 1) >> pure "cli-token"
    explicit <- newTokenProviderWith (Bucket "control") (pure (Just "environment-token")) (pure (Just "metadata-token")) cli
    explicit.accessToken `shouldReturn` "environment-token"
    machine <- newTokenProviderWith (Bucket "control") (pure Nothing) (pure (Just "metadata-token")) cli
    machine.accessToken `shouldReturn` "metadata-token"
    laptop <- newTokenProviderWith (Bucket "control") (pure Nothing) (pure Nothing) cli
    laptop.accessToken `shouldReturn` "cli-token"
    laptop.accessToken `shouldReturn` "cli-token"
    readIORef calls `shouldReturn` 1

  it "encodes the object name and create-only precondition, and maps HTTP 412" do
    seen <- newIORef []
    withMock
      ( \_ target headers -> do
          modifyIORef' seen (<> [(target, lookup "Authorization" headers)])
          pure (MockResponse 412 [] "")
      )
      \port -> do
        store <- testStore port
        store.putObject (Bucket "control") (ObjectName "cells/alpha/lease space.json") "application/json" DoesNotExist "claim" `shouldReturn` PreconditionFailed
    readIORef seen `shouldReturn` [("/upload/storage/v1/b/control/o?uploadType=media&name=cells%2Falpha%2Flease%20space.json&ifGenerationMatch=0", Just "Bearer test-token")]

  it "pins media reads and downloads to the metadata generation" $ withSystemTempDirectory "kenshou-gcs" \root -> do
    seen <- newIORef []
    let object = ObjectName "cells/alpha/work"
        destination = root </> "nested" </> "work"
        metaPath = "/storage/v1/b/control/o/cells%2Falpha%2Fwork"
    withMock
      ( \_ target _ -> do
          modifyIORef' seen (<> [target])
          pure
            if "alt=media" `ByteString.isInfixOf` target
              then MockResponse 200 [] "hello"
              else MockResponse 200 [] objectMetadata
      )
      \port -> do
        store <- testStore port
        fmap fst <$> store.getObject (Bucket "control") object `shouldReturn` Just "hello"
        result <- store.downloadTo (Bucket "control") object destination
        result `shouldSatisfy` maybe False (const True)
    LazyByteString.readFile destination `shouldReturn` "hello"
    readIORef seen `shouldReturn` [metaPath, metaPath <> "?alt=media&generation=7", metaPath, metaPath <> "?alt=media&generation=7"]

  it "does not leave a truncated download as the destination" $ withSystemTempDirectory "kenshou-gcs" \root -> do
    let destination = root </> "work"
    withMock
      ( \_ target _ ->
          pure
            if "alt=media" `ByteString.isInfixOf` target
              then MockResponse 200 [] "short"
              else MockResponse 200 [] "{\"name\":\"cells/alpha/work\",\"generation\":\"7\",\"size\":\"6\",\"updated\":\"2026-09-27T00:00:00Z\"}"
      )
      \port -> do
        store <- testStore port
        store.downloadTo (Bucket "control") (ObjectName "cells/alpha/work") destination `shouldThrow` anyIOException
    doesFileExist destination `shouldReturn` False

  it "paginates listings and reads server time from the Date header" do
    withMock
      ( \_ target _ ->
          pure
            if target == "/storage/v1/b/control/o?maxResults=1"
              then MockResponse 200 [("Date", "Sun, 27 Sep 2026 12:34:56 GMT")] "{}"
              else
                if target == "/storage/v1/b/control/o?prefix=cells%2F&maxResults=1000"
                  then MockResponse 200 [] "{\"items\":[{\"name\":\"cells/a\",\"generation\":\"1\",\"size\":\"0\",\"updated\":\"2026-09-27T00:00:00Z\"}],\"nextPageToken\":\"page 2\"}"
                  else MockResponse 200 [] "{\"items\":[{\"name\":\"cells/b\",\"generation\":\"2\",\"size\":\"0\",\"updated\":\"2026-09-27T00:00:00Z\"}]}"
      )
      \port -> do
        store <- testStore port
        objects <- store.listObjects (Bucket "control") "cells/"
        sort (map fst objects) `shouldBe` [ObjectName "cells/a", ObjectName "cells/b"]
        store.serverTime `shouldReturn` UTCTime (fromGregorian 2026 9 27) (secondsToDiffTime (12 * 3600 + 34 * 60 + 56))

  it "retries a transient metadata HTTP 503" do
    calls <- newIORef (0 :: Int)
    withMock
      ( \_ _ _ -> do
          modifyIORef' calls (+ 1)
          count <- readIORef calls
          pure if count == 1 then MockResponse 503 [] "" else MockResponse 200 [] objectMetadata
      )
      \port -> do
        store <- testStore port
        store.statObject (Bucket "control") (ObjectName "cells/alpha/work") `shouldSatisfyIO` maybe False (const True)
    readIORef calls `shouldReturn` 2

  it "refreshes a cached gcloud token after HTTP 401" do
    calls <- newIORef (0 :: Int)
    seen <- newIORef []
    let cli = do
          modifyIORef' calls (+ 1)
          count <- readIORef calls
          pure (if count == 1 then "stale-token" else "fresh-token")
    withMock
      ( \_ _ headers -> do
          let authorization = lookup "Authorization" headers
          modifyIORef' seen (<> [authorization])
          pure if authorization == Just "Bearer stale-token" then MockResponse 401 [] "" else MockResponse 200 [] objectMetadata
      )
      \port -> do
        provider <- newTokenProviderWith (Bucket "control") (pure Nothing) (pure Nothing) cli
        store <- newGcsStoreAt ("http://127.0.0.1:" <> Text.pack (show port)) provider
        store.statObject (Bucket "control") (ObjectName "cells/alpha/work") `shouldSatisfyIO` maybe False (const True)
        store.statObject (Bucket "control") (ObjectName "cells/alpha/work") `shouldSatisfyIO` maybe False (const True)
    readIORef calls `shouldReturn` 2
    readIORef seen `shouldReturn` [Just "Bearer stale-token", Just "Bearer fresh-token", Just "Bearer fresh-token"]

  it "sends a large file in 8 MiB resumable chunks" $ withSystemTempDirectory "kenshou-gcs" \root -> do
    let source = root </> "payload.nar.zst"
        size = 8 * 1024 * 1024 + 5
    LazyByteString.writeFile source (LazyByteString.replicate size 120)
    ranges <- newIORef []
    withMock
      ( \port target headers ->
          if "uploadType=resumable" `ByteString.isInfixOf` target
            then pure (MockResponse 200 [("Location", Char8.pack ("http://127.0.0.1:" <> show port <> "/upload-session"))] "")
            else do
              modifyIORef' ranges (<> [lookup "Content-Range" headers])
              pure
                if lookup "Content-Range" headers == Just "bytes 0-8388607/8388613"
                  then MockResponse 308 [("Range", "bytes=0-8388607")] ""
                  else MockResponse 201 [] "{\"name\":\"payloads/sha256/abc.nar.zst\",\"generation\":\"9\",\"size\":\"8388613\",\"updated\":\"2026-09-27T00:00:00Z\"}"
      )
      \port -> do
        store <- testStore port
        result <- store.putFile (Bucket "control") (ObjectName "payloads/sha256/abc.nar.zst") "application/zstd" DoesNotExist source
        result `shouldSatisfy` \case
          Written meta -> meta.size == size
          _ -> False
    readIORef ranges `shouldReturn` [Just "bytes 0-8388607/8388613", Just "bytes 8388608-8388612/8388613"]

  it "queries resumable progress after HTTP 503 and resends an unpersisted chunk" $ withSystemTempDirectory "kenshou-gcs" \root -> do
    let source = root </> "payload.nar.zst"
    LazyByteString.writeFile source (LazyByteString.replicate (8 * 1024 * 1024 + 1) 120)
    ranges <- newIORef []
    withMock
      ( \port target headers ->
          if "uploadType=resumable" `ByteString.isInfixOf` target
            then pure (MockResponse 200 [("Location", Char8.pack ("http://127.0.0.1:" <> show port <> "/upload-session"))] "")
            else do
              let range = lookup "Content-Range" headers
              modifyIORef' ranges (<> [range])
              history <- readIORef ranges
              pure case range of
                Just "bytes */8388609" -> MockResponse 308 [] ""
                Just "bytes 0-8388607/8388609" | length history == 1 -> MockResponse 503 [] ""
                Just "bytes 0-8388607/8388609" -> MockResponse 308 [("Range", "bytes=0-8388607")] ""
                _ -> MockResponse 201 [] "{\"name\":\"payloads/sha256/abc.nar.zst\",\"generation\":\"9\",\"size\":\"8388609\",\"updated\":\"2026-09-27T00:00:00Z\"}"
      )
      \port -> do
        store <- testStore port
        result <- store.putFile (Bucket "control") (ObjectName "payloads/sha256/abc.nar.zst") "application/zstd" DoesNotExist source
        result `shouldSatisfy` \case
          Written _ -> True
          _ -> False
    readIORef ranges `shouldReturn` [Just "bytes 0-8388607/8388609", Just "bytes */8388609", Just "bytes 0-8388607/8388609", Just "bytes 8388608-8388608/8388609"]

testStore :: Int -> IO ObjectStore
testStore port = newGcsStoreAt ("http://127.0.0.1:" <> Text.pack (show port)) (TokenProvider (Bucket "control") (pure "test-token") (pure ()))

objectMetadata :: LazyByteString.ByteString
objectMetadata = "{\"name\":\"cells/alpha/work\",\"generation\":\"7\",\"size\":\"5\",\"updated\":\"2026-09-27T00:00:00Z\",\"contentType\":\"application/octet-stream\"}"

withMock :: (Int -> ByteString.ByteString -> [(ByteString.ByteString, ByteString.ByteString)] -> IO MockResponse) -> (Int -> IO value) -> IO value
withMock respond action = bracket open close \listener -> do
  port <-
    getSocketName listener >>= \case
      SockAddrInet number _ -> pure (fromIntegral number)
      _ -> error "expected IPv4 listener"
  thread <-
    forkIO
      ( forever do
          (connection, _) <- accept listener
          void (forkIO (bracket (socketToHandle connection ReadWriteMode) hClose (serve (respond port))))
      )
  action port `finally` killThread thread
  where
    open = do
      listener <- socket AF_INET Stream defaultProtocol
      bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
      listen listener 16
      pure listener

serve :: (ByteString.ByteString -> [(ByteString.ByteString, ByteString.ByteString)] -> IO MockResponse) -> Handle -> IO ()
serve handler connection = do
  hSetBuffering connection NoBuffering
  requestLine <- stripCr <$> Char8.hGetLine connection
  requestHeaders <- readHeaders connection
  let lengthBytes = maybe 0 (read . Char8.unpack) (lookup "Content-Length" requestHeaders)
  consumeBody connection lengthBytes
  MockResponse status headers body <- handler (requestTarget requestLine) requestHeaders
  let statusText = case status of
        200 -> "OK"
        201 -> "Created"
        204 -> "No Content"
        412 -> "Precondition Failed"
        _ -> "Error"
      responseHeaders = headers <> [("Content-Length", Char8.pack (show (LazyByteString.length body))), ("Connection", "close")]
  Char8.hPutStr connection ("HTTP/1.1 " <> Char8.pack (show status) <> " " <> statusText <> "\r\n")
  mapM_ (\(name, value) -> Char8.hPutStr connection (name <> ": " <> value <> "\r\n")) responseHeaders
  Char8.hPutStr connection "\r\n"
  LazyByteString.hPut connection body

requestTarget :: ByteString.ByteString -> ByteString.ByteString
requestTarget line = case Char8.words line of
  _ : target : _ -> target
  _ -> error "invalid mock request line"

readHeaders :: Handle -> IO [(ByteString.ByteString, ByteString.ByteString)]
readHeaders connection = do
  line <- stripCr <$> Char8.hGetLine connection
  if ByteString.null line
    then pure []
    else do
      let (name, rest) = Char8.break (== ':') line
      ((name, Char8.dropWhile (== ' ') (ByteString.drop 1 rest)) :) <$> readHeaders connection

stripCr :: ByteString.ByteString -> ByteString.ByteString
stripCr = Char8.dropWhileEnd (== '\r')

consumeBody :: Handle -> Int -> IO ()
consumeBody connection remaining = unless (remaining == 0) do
  chunk <- ByteString.hGetSome connection (min remaining (64 * 1024))
  unless (not (ByteString.null chunk)) (error "mock request body ended early")
  consumeBody connection (remaining - ByteString.length chunk)

shouldSatisfyIO :: (Show value) => IO value -> (value -> Bool) -> IO ()
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)
