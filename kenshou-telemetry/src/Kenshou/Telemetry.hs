module Kenshou.Telemetry
  ( TelemetryHandles (..),
    FlushReport (..),
    ProviderCallReport (..),
    withTelemetry,
    module Kenshou.Telemetry.Spec,
  )
where

import Control.Exception (SomeException, displayException, mask, throwIO, try)
import Control.Monad (void)
import Data.Aeson (FromJSON (parseJSON), ToJSON (..), Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.IORef
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Dimension (renderMetrics, renderTracing)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..), mkRoleName)
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Telemetry.Compose (HandlerStatsSnapshot)
import Kenshou.Telemetry.Continuity (ContinuityResult, IsolationResult)
import Kenshou.Telemetry.Detect
import Kenshou.Telemetry.Endpoint
import Kenshou.Telemetry.Metrics
import Kenshou.Telemetry.Scrape
import Kenshou.Telemetry.Sink
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Spec qualified as Spec
import Kenshou.Telemetry.Tracing
import Kenshou.Telemetry.Tracing.Pipeline
import Kenshou.Telemetry.Tracing.Probe
import OpenTelemetry.Metric.Core (Meter, MeterProvider)
import OpenTelemetry.Trace.Core (Tracer, TracerProvider)
import System.Environment (getEnvironment)

data ProviderCallReport = ProviderCallReport
  { result :: Text,
    durationMs :: Double
  }
  deriving stock (Eq, Show)

instance ToJSON ProviderCallReport where
  toJSON report = object ["result" .= report.result, "durationMs" .= report.durationMs]

data FlushReport = FlushReport
  { tracing :: Maybe ProviderCallReport,
    metrics :: Maybe ProviderCallReport
  }
  deriving stock (Eq, Show)

instance ToJSON FlushReport where
  toJSON report = object ["tracing" .= report.tracing, "metrics" .= report.metrics]

data TelemetryHandles = TelemetryHandles
  { tracer :: Maybe Tracer,
    tracerProvider :: Maybe TracerProvider,
    meter :: Maybe Meter,
    meterProvider :: Maybe MeterProvider,
    spans :: Maybe SpanProbe,
    pipeline :: Maybe PipelineStats,
    metricsLive :: Bool,
    servesEndpoints :: Bool,
    registerEndpoint :: Endpoint -> IO (),
    setSinkFault :: SinkFault -> IO (),
    recordContinuity :: ContinuityResult -> IsolationResult -> IO (),
    recordHandlerStats :: HandlerStatsSnapshot -> IO (),
    flushTelemetry :: IO FlushReport
  }

withTelemetry :: TelemetrySpec -> (TelemetryHandles -> IO value) -> IO value
withTelemetry spec action = withConfiguredScraper spec \scraper -> case spec.endpoint of
  BuiltinSink fault | requiresSink spec -> withConfiguredSink spec fault (\sink -> runWith scraper (spec {Spec.endpoint = ExternalEndpoint sink.endpoint}) (Just sink))
  _ -> runWith scraper spec Nothing
  where
    runWith scraper effectiveSpec sink = mask \restore -> do
      runtime <- startTracing effectiveSpec
      metricsRuntime <- startMetrics effectiveSpec
      stopPipelineSampler <- maybe (pure (pure [])) (startPipelineSampler spec.outDir) runtime.pipeline
      endpointsRef <- newIORef (maybe [] pure metricsRuntime.endpoint)
      recordedFindingsRef <- newIORef []
      handlerStatsRef <- newIORef []
      traverse_ (\endpoint -> traverse_ (\active -> active.register endpoint) scraper) metricsRuntime.endpoint
      let register endpoint
            | spec.metrics `notElem` [MetricsServe, MetricsServeScraped] = ioError (userError "metrics endpoint registered while telemetry.metrics does not serve endpoints")
            | otherwise = do
                ready <- if endpoint.kind == WebSocketPush then pure True else awaitHttpReady endpoint.url 10_000
                if ready
                  then do
                    modifyIORef' endpointsRef (<> [endpoint])
                    traverse_ (\active -> active.register endpoint) scraper
                  else ioError (userError ("metrics endpoint did not become ready: " <> Text.unpack endpoint.url))
      let handles =
            TelemetryHandles
              { tracer = runtime.tracer,
                tracerProvider = runtime.provider,
                meter = metricsRuntime.meter,
                meterProvider = metricsRuntime.provider,
                spans = runtime.probe,
                pipeline = runtime.pipeline,
                metricsLive = spec.metrics /= MetricsOff,
                servesEndpoints = spec.metrics `elem` [MetricsServe, MetricsServeScraped],
                registerEndpoint = register,
                setSinkFault = maybe (const (pure ())) (.setFault) sink,
                recordContinuity = \continuity isolation -> modifyIORef' recordedFindingsRef (<> continuityFindings continuity isolation),
                recordHandlerStats = \snapshot -> modifyIORef' handlerStatsRef (<> [snapshot]),
                flushTelemetry = FlushReport <$> timedCall (flushTracing spec.shutdownMs runtime) <*> timedCall (flushMetrics spec.shutdownMs metricsRuntime)
              }
      bodyResult <- tryAny (restore (action handles))
      flushResult <- timedCall (flushTracing spec.shutdownMs runtime)
      metricsFlushResult <- timedCall (flushMetrics spec.shutdownMs metricsRuntime)
      endpointSummaries <- maybe (pure Nothing) (fmap Just . (.finish)) scraper
      (metricsSnapshot, metricsShutdownResult) <- timedStopMetrics spec.shutdownMs metricsRuntime
      shutdownResult <- timedCall (stopTracing spec.shutdownMs runtime)
      queueSamples <- stopPipelineSampler
      rawPipelineSnapshot <- traverse snapshotPipeline runtime.pipeline
      let pipelineSnapshot = fmap (normalizeQueueDepth spec) rawPipelineSnapshot
      sinkSnapshot <- traverse (.snapshot) sink
      ambient <- ambientOtelEnvironment
      endpoints <- readIORef endpointsRef
      recordedFindings <- readIORef recordedFindingsRef
      handlerStats <- readIORef handlerStatsRef
      let endpointValues = maybe (fmap toJSON endpoints) (fmap toJSON) endpointSummaries
          calls = catMaybes [providerCall "trace-flush" spec.shutdownMs flushResult, providerCall "metrics-flush" spec.shutdownMs metricsFlushResult, providerCall "trace-shutdown" spec.shutdownMs shutdownResult, providerCall "metrics-shutdown" spec.shutdownMs metricsShutdownResult]
          findings = pipelineFindings 0.01 pipelineSnapshot calls <> [queueGrowthFinding (pipelineQueueLimit spec runtime.pipeline) queueSamples, endpointFinding (maybe [] id endpointSummaries)] <> fmap handlerFinding handlerStats <> recordedFindings
          summary = telemetrySummary spec ambient pipelineSnapshot sinkSnapshot metricsSnapshot endpointValues (fmap toJSON handlerStats) findings flushResult metricsFlushResult shutdownResult metricsShutdownResult
      _ <- tryAny (spec.report summary)
      either throwIO pure bodyResult

requiresSink :: TelemetrySpec -> Bool
requiresSink spec = spec.tracing == TracingSdkOtlp || (spec.metrics /= MetricsOff && spec.otelReader == ReaderOtlpPeriodic)

withConfiguredSink :: TelemetrySpec -> SinkFault -> (SinkHandle -> IO value) -> IO value
withConfiguredSink spec fault action = case (spec.helpers, spec.workerContext) of
  (HelperProcess _, Just context) -> do
    roleName <- either (ioError . userError . Text.unpack) pure (mkRoleName "selftest/telemetry-otlp-sink")
    withWorker context roleName "telemetry-otlp-sink" (object ["fault" .= renderSinkFault fault]) \worker -> do
      ready <- worker.receive 10_000
      endpoint <- case ready of
        Just (WrkCustom "ready" payload) -> maybe (ioError (userError "telemetry sink sent an invalid ready message")) pure (parseMaybe (withObject "sink ready" (.: "endpoint")) payload)
        Just (WrkError message) -> ioError (userError (Text.unpack message))
        _ -> ioError (userError "telemetry sink did not become ready within 10 seconds")
      let setFault updated = worker.send (CtlCustom "fault" (String (renderSinkFault updated)))
          snapshot = do
            worker.send (CtlCustom "snapshot" Null)
            response <- worker.receive 10_000
            case response of
              Just (WrkCustom "sink-stats" payload) -> maybe (ioError (userError "telemetry sink sent invalid statistics")) pure (parseMaybe parseJSON payload)
              _ -> ioError (userError "telemetry sink did not return statistics")
      action (SinkHandle endpoint setFault snapshot)
  _ -> withSink fault action

withConfiguredScraper :: TelemetrySpec -> (Maybe ScraperHandle -> IO value) -> IO value
withConfiguredScraper spec action
  | spec.metrics /= MetricsServeScraped = action Nothing
  | otherwise = case (spec.helpers, spec.workerContext) of
      (HelperProcess _, Just context) -> do
        roleName <- either (ioError . userError . Text.unpack) pure (mkRoleName "selftest/telemetry-scraper")
        withWorker context roleName "telemetry-scraper" (object ["intervalMs" .= spec.scrapeMs, "wsSubscribers" .= spec.wsSubscribers]) \worker -> do
          ready <- worker.receive 10_000
          case ready of
            Just WrkReady -> pure ()
            Just (WrkError message) -> ioError (userError (Text.unpack message))
            _ -> ioError (userError "telemetry scraper did not become ready within 10 seconds")
          let register endpoint = worker.send (CtlCustom "endpoint" (toJSON endpoint))
              finish = do
                worker.send (CtlCustom "finish" Null)
                response <- worker.receive 10_000
                case response of
                  Just (WrkCustom "scrape-summary" payload) -> maybe (ioError (userError "telemetry scraper sent an invalid summary")) pure (parseMaybe parseJSON payload)
                  _ -> ioError (userError "telemetry scraper did not return its summary")
          action (Just (ScraperHandle register finish))
      _ -> do
        scraper <- startScraperInProcess spec.outDir spec.scrapeMs spec.wsSubscribers
        action (Just scraper)

telemetrySummary :: TelemetrySpec -> [(Text, Text)] -> Maybe PipelineSnapshot -> Maybe SinkStats -> Maybe MetricsSnapshot -> [Value] -> [Value] -> [Finding] -> Maybe ProviderCallReport -> Maybe ProviderCallReport -> Maybe ProviderCallReport -> Maybe ProviderCallReport -> Value
telemetrySummary spec ambient pipelineSnapshot sinkSnapshot metricsSnapshot endpoints handlers findings flushResult metricsFlushResult shutdownResult metricsShutdownResult =
  object
    [ "schema" .= ("kenshou.telemetry-summary/v1" :: Text),
      "arms" .= object ["tracing" .= renderTracing spec.tracing, "metrics" .= renderMetrics spec.metrics],
      "settings" .= settingsValue spec,
      "ambientEnv" .= object [Key.fromText key .= value | (key, value) <- ambient],
      "pipeline" .= pipelineValue pipelineSnapshot flushResult shutdownResult,
      "sink" .= sinkSnapshot,
      "metrics" .= object ["snapshot" .= metricsSnapshot, "flush" .= metricsFlushResult, "shutdown" .= metricsShutdownResult],
      "endpoints" .= endpoints,
      "handlers" .= handlers,
      "findings" .= findings
    ]

providerCall :: Text -> Int -> Maybe ProviderCallReport -> Maybe (Text, Text, Double, Double)
providerCall _ _ Nothing = Nothing
providerCall name limit (Just report) = Just (name, report.result, report.durationMs, fromIntegral limit)

normalizeQueueDepth :: TelemetrySpec -> PipelineSnapshot -> PipelineSnapshot
normalizeQueueDepth spec snapshot = case spec.processor of
  BatchProcessor queue _ batch _ ->
    -- The public SDK does not expose its private queue count. The accounting
    -- backlog includes SDK-dropped spans, so cap its high-water mark at the
    -- configured queue plus the one batch that may already be exporting.
    PipelineSnapshot snapshot.spansStarted snapshot.spansEnded snapshot.spansExportedOk snapshot.spansExportFailed snapshot.spansDropped (min snapshot.maxQueueDepth (queue + batch)) snapshot.exportCalls snapshot.exportLatencyNs snapshot.lastExportError
  SimpleProcessor _ -> snapshot

pipelineQueueLimit :: TelemetrySpec -> Maybe PipelineStats -> Maybe Int
pipelineQueueLimit spec pipeline = case (pipeline, spec.processor) of
  (Just _, BatchProcessor queue _ _ _) -> Just queue
  _ -> Nothing

pipelineValue :: Maybe PipelineSnapshot -> Maybe ProviderCallReport -> Maybe ProviderCallReport -> Value
pipelineValue Nothing _ _ = Null
pipelineValue (Just snapshot) flushResult shutdownResult = case toJSON snapshot of
  Object fields -> Object (KeyMap.insert "shutdown" (toJSON shutdownResult) (KeyMap.insert "flush" (toJSON flushResult) fields))
  value -> value

settingsValue :: TelemetrySpec -> Value
settingsValue spec =
  object
    [ "sampler" .= renderSampler spec.sampler,
      "processor" .= renderProcessor spec.processor,
      "exporter" .= (case spec.exporter of HttpProtobuf -> "http-protobuf" :: Text; Grpc -> "grpc"),
      "endpoint" .= (case spec.endpoint of BuiltinSink _ -> "builtin-sink" :: Text; ExternalEndpoint value -> value),
      "sinkFault" .= (case spec.endpoint of BuiltinSink fault -> renderSinkFault fault; ExternalEndpoint _ -> "none"),
      "compression" .= (case spec.compression of CompressionNone -> "none" :: Text; CompressionGzip -> "gzip")
    ]

renderSampler :: SamplerSpec -> Text
renderSampler AlwaysOn = "always-on"
renderSampler AlwaysOff = "always-off"
renderSampler ParentBasedAlwaysOn = "parentbased-always-on"
renderSampler (TraceIdRatio ratio) = "traceidratio:" <> Text.pack (show ratio)
renderSampler (ParentBasedTraceIdRatio ratio) = "parentbased-traceidratio:" <> Text.pack (show ratio)

renderProcessor :: ProcessorSpec -> Value
renderProcessor (SimpleProcessor timeoutMs) = object ["kind" .= ("simple" :: Text), "exportTimeoutMs" .= timeoutMs]
renderProcessor (BatchProcessor queue delay batch timeoutMs) =
  object
    [ "kind" .= ("batch" :: Text),
      "maxQueue" .= queue,
      "scheduleDelayMs" .= delay,
      "maxExportBatch" .= batch,
      "exportTimeoutMs" .= timeoutMs
    ]

timedCall :: (Show result) => IO (Maybe result) -> IO (Maybe ProviderCallReport)
timedCall operation = do
  started <- getMonotonicTimeNSec
  outcome <- tryAny operation
  finished <- getMonotonicTimeNSec
  let elapsed = fromIntegral (finished - started) / 1_000_000
  pure . Just $ case outcome of
    Left exception -> ProviderCallReport ("exception: " <> Text.pack (displayException exception)) elapsed
    Right Nothing -> ProviderCallReport "not-applicable" elapsed
    Right (Just result) -> ProviderCallReport (Text.pack (show result)) elapsed

timedStopMetrics :: Int -> MetricsRuntime -> IO (Maybe MetricsSnapshot, Maybe ProviderCallReport)
timedStopMetrics timeoutMs runtime = do
  started <- getMonotonicTimeNSec
  outcome <- tryAny (stopMetrics timeoutMs runtime)
  finished <- getMonotonicTimeNSec
  let elapsed = fromIntegral (finished - started) / 1_000_000
  pure $ case outcome of
    Left exception -> (Nothing, Just (ProviderCallReport ("exception: " <> Text.pack (displayException exception)) elapsed))
    Right (snapshot, Nothing) -> (snapshot, Just (ProviderCallReport "not-applicable" elapsed))
    Right (snapshot, Just result) -> (snapshot, Just (ProviderCallReport (Text.pack (show result)) elapsed))

ambientOtelEnvironment :: IO [(Text, Text)]
ambientOtelEnvironment = do
  environment <- getEnvironment
  pure [(Text.pack key, Text.pack value) | (key, value) <- environment, "OTEL_" `Text.isPrefixOf` Text.pack key]

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

traverse_ :: (a -> IO b) -> Maybe a -> IO ()
traverse_ _ Nothing = pure ()
traverse_ action (Just value) = void (action value)
