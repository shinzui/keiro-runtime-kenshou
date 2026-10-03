module Kenshou.Suite.Keiro.Queue.Metrics
  ( QueueMetrics,
    WorkerCounts (..),
    withQueueTelemetry,
    withQueueTelemetryAt,
    registerWorker,
    checkpoint,
    probeEndpoints,
    metricsMatch,
    prometheusMatch,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Control.Exception (bracket, mask, throwIO)
import Control.Monad (forM, forM_, forever, when)
import Data.Aeson (ToJSON (..), Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Context (ArtifactDir (..), RunContext, SummarySection (..), artifactPath, putSummary)
import Kenshou.Telemetry (TelemetryHandles (..), TelemetrySpec (..), withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..), reserveFreePort)
import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics (MetricsMap, ProcessorId (..), ProcessorMetrics (..), ProcessorState (..), StreamStats (..))
import Shibuya.Metrics.Server qualified as Server
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), Handle, IOMode (WriteMode), hClose, hSetBuffering, openFile)
import Text.Read (readMaybe)

data WorkerCounts = WorkerCounts
  { received :: Int,
    processed :: Int,
    failed :: Int,
    inFlight :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON WorkerCounts where
  toJSON counts = object ["received" .= counts.received, "processed" .= counts.processed, "failed" .= counts.failed, "inFlight" .= counts.inFlight]

data Source = Source {label :: Text, master :: Master, port :: Maybe Int}

data QueueMetrics = QueueMetrics
  { path :: ArtifactDir -> FilePath -> IO FilePath,
    report :: Value -> IO (),
    sources :: IORef [Source],
    servers :: IORef [Server.MetricsServer],
    collectors :: IORef [Async ()],
    series :: MVar (Maybe Handle)
  }

withQueueTelemetry :: RunContext -> TelemetrySpec -> (TelemetryHandles -> QueueMetrics -> IO a) -> IO a
withQueueTelemetry context = withQueueTelemetryUsing (artifactPath context) (putSummary context Telemetry "queue-worker-metrics")

withQueueTelemetryAt :: FilePath -> (Value -> IO ()) -> TelemetrySpec -> (TelemetryHandles -> QueueMetrics -> IO a) -> IO a
withQueueTelemetryAt directory = withQueueTelemetryUsing path
  where
    path kind name = do
      let root = directory </> (if kind == SeriesDir then "series" else "logs")
      createDirectoryIfMissing True root
      pure (root </> name)

withQueueTelemetryUsing :: (ArtifactDir -> FilePath -> IO FilePath) -> (Value -> IO ()) -> TelemetrySpec -> (TelemetryHandles -> QueueMetrics -> IO a) -> IO a
withQueueTelemetryUsing path report spec action = bracket acquire release \resources ->
  withTelemetry spec \telemetry -> do
    result <- action telemetry resources
    tasks <- readIORef resources.collectors
    forM_ tasks \task ->
      poll task >>= \case
        Nothing -> pure ()
        Just (Left err) -> throwIO err
        Just (Right ()) -> fail "queue metrics collector exited unexpectedly"
    pure result
  where
    acquire = QueueMetrics path report <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newMVar Nothing
    release resources = do
      readIORef resources.collectors >>= mapM_ cancel
      readIORef resources.servers >>= mapM_ Server.stopMetricsServer
      modifyMVar_ resources.series (\handle -> mapM_ hClose handle >> pure Nothing)

registerWorker :: TelemetryHandles -> QueueMetrics -> Int -> Text -> Master -> IO ()
registerWorker telemetry resources intervalMs label master = when telemetry.metricsLive $ mask \restore -> do
  port <-
    if telemetry.servesEndpoints
      then do
        selected <- reserveFreePort
        server <- Server.startMetricsServer Server.defaultConfig {Server.port = selected, Server.enableWebSocket = False} master
        atomicModifyIORef' resources.servers (\servers -> (server : servers, ()))
        pure (Just selected)
      else pure Nothing
  let source = Source label master port
  atomicModifyIORef' resources.sources (\sources -> (source : sources, ()))
  collector <- async $ forever do
    snapshot <- getAllMetricsIO master
    writeSample resources label "periodic" snapshot
    threadDelay (intervalMs * 1000)
  atomicModifyIORef' resources.collectors (\collectors -> (collector : collectors, ()))
  restore $ forM_ port \selected -> do
    telemetry.registerEndpoint (Endpoint (label <> "-prometheus") PrometheusText (url selected "/metrics/prometheus") Nothing)
    telemetry.registerEndpoint (Endpoint (label <> "-json") JsonDocument (url selected "/metrics") Nothing)

checkpoint :: QueueMetrics -> IO MetricsMap
checkpoint resources = do
  sources <- readIORef resources.sources
  snapshots <- forM sources \source -> do
    snapshot <- getAllMetricsIO source.master
    writeSample resources source.label "checkpoint" snapshot
    pure snapshot
  let snapshot = Map.unions snapshots
  resources.report (object ["sources" .= length sources, "processors" .= snapshot])
  pure snapshot

writeSample :: QueueMetrics -> Text -> Text -> MetricsMap -> IO ()
writeSample resources source sampling snapshot = do
  at <- getCurrentTime
  mono <- getMonotonicTimeNSec
  modifyMVar_ resources.series \previous -> do
    handle <- case previous of
      Just handle -> pure handle
      Nothing -> do
        path <- resources.path SeriesDir "queue-worker-metrics.jsonl"
        handle <- openFile path WriteMode
        hSetBuffering handle LineBuffering
        pure handle
    LBS.hPut handle (encode (object ["schema" .= ("kenshou.queue-worker-metrics/v1" :: Text), "at" .= at, "monotonicNs" .= mono, "source" .= source, "sampling" .= sampling, "processors" .= snapshot]) <> "\n")
    pure (Just handle)

probeEndpoints :: QueueMetrics -> Text -> Map.Map ProcessorId WorkerCounts -> IO Bool
probeEndpoints resources phase expected = do
  sources <- readIORef resources.sources
  manager <- newManager defaultManagerSettings
  results <- forM sources \source -> case source.port of
    Nothing -> pure True
    Just port -> do
      native <- getAllMetricsIO source.master
      let wanted = Map.restrictKeys expected (Map.keysSet native)
          fetch path = parseRequest (Text.unpack (url port path)) >>= \request -> httpLbs request manager
      json <- fetch "/metrics"
      prometheus <- fetch "/metrics/prometheus"
      jsonPath <- resources.path LogsDir (Text.unpack (source.label <> "-" <> phase <> ".json"))
      promPath <- resources.path LogsDir (Text.unpack (source.label <> "-" <> phase <> ".prom"))
      LBS.writeFile jsonPath json.responseBody
      LBS.writeFile promPath prometheus.responseBody
      pure
        ( statusCode json.responseStatus == 200
            && statusCode prometheus.responseStatus == 200
            && either (const False) (metricsMatch wanted) (eitherDecode json.responseBody)
            && prometheusMatch wanted (TextEncoding.decodeUtf8 (LBS.toStrict prometheus.responseBody))
        )
  pure (not (null sources) && and results)

metricsMatch :: Map.Map ProcessorId WorkerCounts -> MetricsMap -> Bool
metricsMatch expected observed = not (Map.null expected) && fmap countsOf observed == expected

countsOf :: ProcessorMetrics -> WorkerCounts
countsOf metrics = WorkerCounts metrics.stats.received metrics.stats.processed metrics.stats.failed (inFlightOf metrics.state)

-- | Reads the in-flight count through the state's JSON form. The released
-- shibuya-core 0.9.0.3 and the head revision 6461c74 share a version number
-- but give 'Processing' two and three fields, so a constructor pattern
-- cannot compile on both cohorts.
inFlightOf :: ProcessorState -> Int
inFlightOf state = case toJSON state of
  Object fields | Just (Number count) <- KeyMap.lookup "inFlight" fields -> truncate count
  _ -> 0

prometheusMatch :: Map.Map ProcessorId WorkerCounts -> Text -> Bool
prometheusMatch expected body = not (Map.null expected) && all matches (Map.toList expected)
  where
    matches (ProcessorId processor, counts) =
      all
        (matchesValue processor)
        [("shibuya_messages_received_total", counts.received), ("shibuya_messages_processed_total", counts.processed), ("shibuya_messages_failed_total", counts.failed), ("shibuya_processor_in_flight", counts.inFlight)]
    matchesValue processor (metric, value) =
      let prefix = metric <> "{processor=\"" <> escapeLabel processor <> "\"} "
          values = [readMaybe (Text.unpack raw) :: Maybe Double | line <- Text.lines body, Just raw <- [Text.stripPrefix prefix line]]
       in values == [Just (fromIntegral value)]
    escapeLabel = Text.replace "\n" "\\n" . Text.replace "\"" "\\\"" . Text.replace "\\" "\\\\"

url :: Int -> Text -> Text
url port path = "http://127.0.0.1:" <> Text.pack (show port) <> path
