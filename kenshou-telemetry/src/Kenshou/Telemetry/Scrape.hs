module Kenshou.Telemetry.Scrape
  ( EndpointSummary (..),
    ScraperHandle (..),
    startScraperInProcess,
    runScraperInProcess,
    runScraperRole,
    SlotLeakResult (..),
    wsSlotLeakProbe,
  )
where

import Control.Concurrent.Async (Async, async, cancel, mapConcurrently_, waitCatch)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeAsyncException, SomeException, displayException, finally, fromException, throwIO, try)
import Control.Monad (forM_, replicateM_, void)
import Data.Aeson (FromJSON (..), ToJSON (..), encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe, (.!=), (.:?))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), WorkerInit (..), WorkerMessage (..))
import Kenshou.Measure.Clock (Origin (..), captureOrigin, sleepUntilNs)
import Kenshou.Telemetry.Endpoint
import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Network.WebSockets qualified as WebSockets
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), Handle, IOMode (WriteMode), hClose, hPutStrLn, hSetBuffering, openFile)
import Text.Read (readMaybe)

data ScrapeSample = ScrapeSample
  { status :: Int,
    latencyNs :: Integer,
    bodyBytes :: Integer,
    skipped :: Int,
    errorMessage :: Maybe Text
  }

data EndpointSummary = EndpointSummary
  { endpoint :: Text,
    kind :: EndpointKind,
    scrapes :: Int,
    failures :: Int,
    skippedTicks :: Int,
    latencyP50Ns :: Integer,
    latencyP99Ns :: Integer,
    latencyMaxNs :: Integer,
    meanBodyBytes :: Double,
    maxBodyBytes :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON EndpointSummary where
  toJSON summary =
    object
      [ "endpoint" .= summary.endpoint,
        "kind" .= summary.kind,
        "scrapes" .= summary.scrapes,
        "failures" .= summary.failures,
        "skippedTicks" .= summary.skippedTicks,
        "latencyNs" .= object ["p50" .= summary.latencyP50Ns, "p99" .= summary.latencyP99Ns, "max" .= summary.latencyMaxNs],
        "bodyBytes" .= object ["mean" .= summary.meanBodyBytes, "max" .= summary.maxBodyBytes]
      ]

instance FromJSON EndpointSummary where
  parseJSON = withObject "EndpointSummary" \value -> do
    latency <- value .: "latencyNs"
    body <- value .: "bodyBytes"
    EndpointSummary
      <$> value .: "endpoint"
      <*> value .: "kind"
      <*> value .: "scrapes"
      <*> value .: "failures"
      <*> value .: "skippedTicks"
      <*> latency .: "p50"
      <*> latency .: "p99"
      <*> latency .: "max"
      <*> body .: "mean"
      <*> body .: "max"

data ScraperHandle = ScraperHandle
  { register :: Endpoint -> IO (),
    finish :: IO [EndpointSummary]
  }

data ScraperState = ScraperState
  { manager :: Manager,
    outputDir :: FilePath,
    intervalNs :: Integer,
    wsSubscribers :: Int,
    workers :: IORef [(Endpoint, Async ())],
    endpoints :: IORef [Endpoint],
    samples :: IORef (Map Text [ScrapeSample])
  }

startScraperInProcess :: FilePath -> Int -> Int -> IO ScraperHandle
startScraperInProcess outputDir intervalMs wsSubscribers = do
  createDirectoryIfMissing True (outputDir </> "series")
  manager <- newManager defaultManagerSettings
  workers <- newIORef []
  endpoints <- newIORef []
  samples <- newIORef Map.empty
  let state = ScraperState manager outputDir (fromIntegral intervalMs * 1_000_000) wsSubscribers workers endpoints samples
  pure (ScraperHandle (registerEndpoint state) (finishScraper state))

runScraperInProcess :: FilePath -> Int -> Int -> [Endpoint] -> IO (IO [EndpointSummary])
runScraperInProcess outputDir intervalMs wsSubscribers endpoints = do
  scraper <- startScraperInProcess outputDir intervalMs wsSubscribers
  traverse_ scraper.register endpoints
  pure scraper.finish

runScraperRole :: RoleContext -> IO ()
runScraperRole context = do
  let (intervalMs, subscribers) = maybe (15_000, 0) id (parseMaybe parseConfig context.init.args)
  scraper <- startScraperInProcess context.init.outDir intervalMs subscribers
  context.send WrkReady
  loop scraper
  where
    loop scraper =
      context.receive >>= \case
        Just (CtlCustom "endpoint" payload) -> case parseMaybe parseJSON payload of
          Nothing -> context.send (WrkError "invalid scraper endpoint") >> loop scraper
          Just endpoint -> scraper.register endpoint >> loop scraper
        Just (CtlCustom "finish" _) -> scraper.finish >>= context.send . WrkCustom "scrape-summary" . toJSON >> loop scraper
        Just (CtlStop _) -> void scraper.finish
        Just _ -> loop scraper
        Nothing -> void scraper.finish
    parseConfig = withObject "scraper config" (\value -> (,) <$> value .: "intervalMs" <*> value .:? "wsSubscribers" .!= 0)

registerEndpoint :: ScraperState -> Endpoint -> IO ()
registerEndpoint state endpoint = do
  modifyIORef' state.endpoints (<> [endpoint])
  if endpoint.kind == WebSocketPush
    then do
      modifyIORef' state.samples (Map.insertWith (<>) endpoint.name [])
      if state.wsSubscribers <= 0
        then pure ()
        else do
          worker <- async (websocketSubscribers state endpoint)
          modifyIORef' state.workers (<> [(endpoint, worker)])
    else do
      worker <- async (scrapeLoop state endpoint)
      modifyIORef' state.workers (<> [(endpoint, worker)])

scrapeLoop :: ScraperState -> Endpoint -> IO ()
scrapeLoop state endpoint = do
  request <- parseRequest (Text.unpack endpoint.url)
  handle <- openFile (state.outputDir </> "series" </> ("scrape-" <> Text.unpack endpoint.name <> ".csv")) WriteMode
  hSetBuffering handle LineBuffering
  hPutStrLn handle "t_wall_ns,endpoint,kind,status,latency_ns,body_bytes,skipped,error"
  started <- getMonotonicTimeNSec
  let loop tick = do
        sleepUntilNs (started + fromIntegral tick * fromIntegral state.intervalNs)
        origin <- captureOrigin
        callStarted <- getMonotonicTimeNSec
        result <- trySync (httpLbs request state.manager)
        callEnded <- getMonotonicTimeNSec
        let elapsed = fromIntegral (callEnded - callStarted)
            behind = max 0 (fromIntegral (callEnded - started) `div` state.intervalNs - tick)
            sample = case result of
              Left exception -> ScrapeSample 0 elapsed 0 (fromIntegral behind) (Just (Text.pack (displayException exception)))
              Right response -> ScrapeSample (statusCode (responseStatus response)) elapsed (fromIntegral (LazyByteString.length (responseBody response))) (fromIntegral behind) Nothing
        modifyIORef' state.samples (Map.insertWith (<>) endpoint.name [sample])
        hPutStrLn handle (csvRow origin endpoint sample)
        loop (tick + 1 + behind)
  loop 1 `finally` hClose handle

websocketSubscribers :: ScraperState -> Endpoint -> IO ()
websocketSubscribers state endpoint = do
  (host, port, path) <- either (ioError . userError . Text.unpack) pure (parseWebSocketUrl endpoint.url)
  handle <- openFile (state.outputDir </> "series" </> ("scrape-" <> Text.unpack endpoint.name <> "-ws.csv")) WriteMode
  hSetBuffering handle LineBuffering
  hPutStrLn handle "t_wall_ns,subscriber,event,frames,bytes,gap_ns,error"
  lock <- newMVar ()
  mapConcurrently_ (subscriber host port path handle lock) [1 .. state.wsSubscribers] `finally` hClose handle
  where
    subscriber host port path handle lock subscriberId = do
      outcome <- trySync $ WebSockets.runClient (Text.unpack host) port (Text.unpack path) \connection -> do
        traverse_ (WebSockets.sendTextData connection . encode) endpoint.wsHello
        writeWsRow handle lock subscriberId "connect" 0 0 0 Nothing
        previous <- newIORef Nothing
        let loop frames = do
              payload <- WebSockets.receiveData connection :: IO LazyByteString.ByteString
              now <- getMonotonicTimeNSec
              prior <- atomicModifyIORef' previous (\value -> (Just now, value))
              writeWsRow handle lock subscriberId "frame" frames (fromIntegral (LazyByteString.length payload)) (maybe 0 (fromIntegral . (now -)) prior) Nothing
              loop (frames + 1)
        loop 1
      case outcome of
        Left exception -> writeWsRow handle lock subscriberId "error" 0 0 0 (Just (Text.pack (displayException exception)))
        Right () -> writeWsRow handle lock subscriberId "close" 0 0 0 Nothing

writeWsRow :: Handle -> MVar () -> Int -> Text -> Int -> Integer -> Integer -> Maybe Text -> IO ()
writeWsRow handle lock subscriberId event frames bytes gap errorMessage = withMVar lock \_ -> do
  origin <- captureOrigin
  hPutStrLn handle . Text.unpack . Text.intercalate "," $
    [ Text.pack (show origin.wallUnixNs),
      Text.pack (show subscriberId),
      event,
      Text.pack (show frames),
      Text.pack (show bytes),
      Text.pack (show gap),
      maybe "" (Text.replace "," ";" . Text.replace "\n" " ") errorMessage
    ]

finishScraper :: ScraperState -> IO [EndpointSummary]
finishScraper state = do
  workers <- readIORef state.workers
  forM_ workers (cancel . snd)
  forM_ workers (void . waitCatch . snd)
  captured <- readIORef state.samples
  endpoints <- readIORef state.endpoints
  pure [summarize endpoint (Map.findWithDefault [] endpoint.name captured) | endpoint <- endpoints]

summarize :: Endpoint -> [ScrapeSample] -> EndpointSummary
summarize endpoint samples =
  EndpointSummary
    { endpoint = endpoint.name,
      kind = endpoint.kind,
      scrapes = length samples,
      failures = length [() | sample <- samples, sample.status < 200 || sample.status >= 300 || sample.errorMessage /= Nothing],
      skippedTicks = sum (fmap (.skipped) samples),
      latencyP50Ns = quantile 0.50 latencies,
      latencyP99Ns = quantile 0.99 latencies,
      latencyMaxNs = maybe 0 last nonEmptyLatencies,
      meanBodyBytes = if null samples then 0 else fromIntegral (sum (fmap (.bodyBytes) samples)) / fromIntegral (length samples),
      maxBodyBytes = maybe 0 last nonEmptyBodies
    }
  where
    latencies = sort (fmap (.latencyNs) samples)
    bodies = sort (fmap (.bodyBytes) samples)
    nonEmptyLatencies = if null latencies then Nothing else Just latencies
    nonEmptyBodies = if null bodies then Nothing else Just bodies

quantile :: Double -> [Integer] -> Integer
quantile _ [] = 0
quantile fraction values = values !! min (length values - 1) (floor (fraction * fromIntegral (length values - 1)))

data SlotLeakResult = SlotLeakResult
  { attempted :: Int,
    freshAccepted :: Bool
  }
  deriving stock (Eq, Show)

instance ToJSON SlotLeakResult where
  toJSON result = object ["attempted" .= result.attempted, "freshAccepted" .= result.freshAccepted]

wsSlotLeakProbe :: Endpoint -> Int -> IO SlotLeakResult
wsSlotLeakProbe endpoint attempts = case parseWebSocketUrl endpoint.url of
  Left _ -> pure (SlotLeakResult attempts False)
  Right (host, port, path) -> do
    replicateM_ attempts (void (trySync (connect host port path)))
    fresh <- trySync (connect host port path)
    pure (SlotLeakResult attempts (either (const False) (const True) fresh))
  where
    connect host port path = WebSockets.runClient (Text.unpack host) port (Text.unpack path) (const (pure ()))

parseWebSocketUrl :: Text -> Either Text (Text, Int, Text)
parseWebSocketUrl url = do
  remainder <- maybe (Left "WebSocket URL must start with ws://") Right (Text.stripPrefix "ws://" url)
  let (authority, rawPath) = Text.breakOn "/" remainder
      path = if Text.null rawPath then "/" else rawPath
      pieces = Text.splitOn ":" authority
  case pieces of
    [host] -> Right (host, 80, path)
    [host, rawPort] -> maybe (Left "WebSocket URL has an invalid port") (\port -> Right (host, port, path)) (readMaybe (Text.unpack rawPort))
    _ -> Left "WebSocket URL has an invalid authority"

csvRow :: Origin -> Endpoint -> ScrapeSample -> String
csvRow origin endpoint sample =
  Text.unpack . Text.intercalate "," $
    [ Text.pack (show origin.wallUnixNs),
      endpoint.name,
      Text.pack (show endpoint.kind),
      Text.pack (show sample.status),
      Text.pack (show sample.latencyNs),
      Text.pack (show sample.bodyBytes),
      Text.pack (show sample.skipped),
      maybe "" sanitize sample.errorMessage
    ]
  where
    sanitize = Text.replace "," ";" . Text.replace "\n" " "

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

trySync :: IO value -> IO (Either SomeException value)
trySync action = do
  outcome <- tryAny action
  case outcome of
    Left exception -> case fromException exception :: Maybe SomeAsyncException of
      Just _ -> throwIO exception
      Nothing -> pure outcome
    Right _ -> pure outcome
