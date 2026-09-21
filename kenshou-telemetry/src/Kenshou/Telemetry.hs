module Kenshou.Telemetry
  ( TelemetryHandles (..),
    FlushReport (..),
    ProviderCallReport (..),
    withTelemetry,
    module Kenshou.Telemetry.Spec,
  )
where

import Control.Exception (SomeException, displayException, mask, throwIO, try)
import Data.Aeson (FromJSON (parseJSON), ToJSON (..), Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Dimension (renderMetrics, renderTracing)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..), mkRoleName)
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Telemetry.Sink
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Spec qualified as Spec
import Kenshou.Telemetry.Tracing
import Kenshou.Telemetry.Tracing.Pipeline
import Kenshou.Telemetry.Tracing.Probe
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
  { tracing :: Maybe ProviderCallReport
  }
  deriving stock (Eq, Show)

instance ToJSON FlushReport where
  toJSON report = object ["tracing" .= report.tracing]

data TelemetryHandles = TelemetryHandles
  { tracer :: Maybe Tracer,
    tracerProvider :: Maybe TracerProvider,
    spans :: Maybe SpanProbe,
    pipeline :: Maybe PipelineStats,
    metricsLive :: Bool,
    servesEndpoints :: Bool,
    setSinkFault :: SinkFault -> IO (),
    flushTelemetry :: IO FlushReport
  }

withTelemetry :: TelemetrySpec -> (TelemetryHandles -> IO value) -> IO value
withTelemetry spec action = case spec.endpoint of
  BuiltinSink fault | requiresSink spec -> withConfiguredSink spec fault (\sink -> runWith (spec {Spec.endpoint = ExternalEndpoint sink.endpoint}) (Just sink))
  _ -> runWith spec Nothing
  where
    runWith effectiveSpec sink = mask \restore -> do
      runtime <- startTracing effectiveSpec
      let handles =
            TelemetryHandles
              { tracer = runtime.tracer,
                tracerProvider = runtime.provider,
                spans = runtime.probe,
                pipeline = runtime.pipeline,
                metricsLive = spec.metrics /= MetricsOff,
                servesEndpoints = spec.metrics `elem` [MetricsServe, MetricsServeScraped],
                setSinkFault = maybe (const (pure ())) (.setFault) sink,
                flushTelemetry = FlushReport <$> timedCall (flushTracing spec.shutdownMs runtime)
              }
      bodyResult <- tryAny (restore (action handles))
      flushResult <- timedCall (flushTracing spec.shutdownMs runtime)
      shutdownResult <- timedCall (stopTracing spec.shutdownMs runtime)
      pipelineSnapshot <- traverse snapshotPipeline runtime.pipeline
      sinkSnapshot <- traverse (.snapshot) sink
      ambient <- ambientOtelEnvironment
      let summary = telemetrySummary spec ambient pipelineSnapshot sinkSnapshot flushResult shutdownResult
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

telemetrySummary :: TelemetrySpec -> [(Text, Text)] -> Maybe PipelineSnapshot -> Maybe SinkStats -> Maybe ProviderCallReport -> Maybe ProviderCallReport -> Value
telemetrySummary spec ambient pipelineSnapshot sinkSnapshot flushResult shutdownResult =
  object
    [ "schema" .= ("kenshou.telemetry-summary/v1" :: Text),
      "arms" .= object ["tracing" .= renderTracing spec.tracing, "metrics" .= renderMetrics spec.metrics],
      "settings" .= settingsValue spec,
      "ambientEnv" .= object [Key.fromText key .= value | (key, value) <- ambient],
      "pipeline" .= pipelineValue pipelineSnapshot flushResult shutdownResult,
      "sink" .= sinkSnapshot,
      "endpoints" .= ([] :: [Value]),
      "handlers" .= ([] :: [Value]),
      "findings" .= ([] :: [Value])
    ]

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

ambientOtelEnvironment :: IO [(Text, Text)]
ambientOtelEnvironment = do
  environment <- getEnvironment
  pure [(Text.pack key, Text.pack value) | (key, value) <- environment, "OTEL_" `Text.isPrefixOf` Text.pack key]

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try
