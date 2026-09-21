module Kenshou.Telemetry.Spec
  ( TracingArm (..),
    MetricsArm (..),
    SamplerSpec (..),
    ProcessorSpec (..),
    OtlpProtocol (..),
    OtlpEndpoint (..),
    OtlpCompression (..),
    SinkFault (..),
    OtelReader (..),
    HelperPlacement (..),
    TelemetrySpec (..),
    telemetryKnobs,
    telemetrySpecFromContext,
    renderSinkFault,
  )
where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), SummarySection (Telemetry), putSummary)
import Kenshou.Core.Dimension (Dimensions (..), MetricsArm (..), TracingArm (..))
import Kenshou.Core.Id (renderScenarioId)
import Kenshou.Core.Knob

data SamplerSpec = AlwaysOn | AlwaysOff | ParentBasedAlwaysOn | TraceIdRatio Double | ParentBasedTraceIdRatio Double
  deriving stock (Eq, Show)

data ProcessorSpec
  = BatchProcessor
      { maxQueue :: Int,
        scheduleDelayMs :: Int,
        maxExportBatch :: Int,
        exportTimeoutMs :: Int
      }
  | SimpleProcessor {exportTimeoutMs :: Int}
  deriving stock (Eq, Show)

data OtlpProtocol = HttpProtobuf | Grpc deriving stock (Eq, Show)

data SinkFault = SinkHealthy | SinkDelay200ms | SinkDelay2000ms | SinkStatus503 | SinkHang | SinkRefuse
  deriving stock (Eq, Ord, Show)

data OtlpEndpoint = BuiltinSink SinkFault | ExternalEndpoint Text deriving stock (Eq, Show)

data OtlpCompression = CompressionNone | CompressionGzip deriving stock (Eq, Show)

data OtelReader = ReaderPrometheus | ReaderOtlpPeriodic | ReaderNone deriving stock (Eq, Show)

data HelperPlacement = HelperProcess FilePath | HelperInProcess deriving stock (Eq, Show)

data TelemetrySpec = TelemetrySpec
  { tracing :: TracingArm,
    metrics :: MetricsArm,
    serviceName :: Text,
    sampler :: SamplerSpec,
    processor :: ProcessorSpec,
    exporter :: OtlpProtocol,
    endpoint :: OtlpEndpoint,
    compression :: OtlpCompression,
    probeRetain :: Int,
    shutdownMs :: Int,
    otelReader :: OtelReader,
    otelExportMs :: Int,
    scrapeMs :: Int,
    wsSubscribers :: Int,
    helpers :: HelperPlacement,
    outDir :: FilePath,
    report :: Value -> IO ()
  }

telemetryKnobs :: [KnobSpec]
telemetryKnobs =
  [ textKnob "otel.sampler" "OpenTelemetry sampler" "parentbased-always-on" ["always-on", "always-off", "parentbased-always-on", "traceidratio", "parentbased-traceidratio"],
    doubleKnob "otel.sampler-arg" "Trace-id-ratio sampler fraction" 1 0 1,
    textKnob "otel.processor" "Span processor" "batch" ["batch", "simple"],
    intKnob "otel.bsp.max-queue" "Batch processor queue bound" 2048 1 1048576,
    intKnob "otel.bsp.schedule-delay-ms" "Batch export schedule delay" 5000 10 60000,
    intKnob "otel.bsp.max-export-batch" "Maximum export batch" 512 1 1048576,
    intKnob "otel.bsp.export-timeout-ms" "Exporter timeout" 30000 100 120000,
    textKnob "otel.exporter" "OTLP protocol" "http-protobuf" ["http-protobuf", "grpc"],
    KnobSpec (name "otel.endpoint") "External OTLP base URL, empty for built-in sink" KnobText (VText "") AnyValue [],
    textKnob "otel.sink-fault" "Built-in OTLP sink fault" "none" ["none", "delay-200ms", "delay-2000ms", "status-503", "hang", "refuse"],
    textKnob "otel.compression" "OTLP compression" "none" ["none", "gzip"],
    intKnob "otel.inmemory.retain" "Recent spans retained by the bounded probe" 4096 0 1000000,
    intKnob "otel.shutdown-timeout-ms" "Provider flush and shutdown timeout" 5000 100 120000,
    intKnob "metrics.scrape-interval-ms" "Metrics scrape interval" 15000 100 600000,
    intKnob "metrics.ws-subscribers" "WebSocket subscribers per endpoint" 0 0 64,
    textKnob "metrics.otel-reader" "OpenTelemetry metric reader" "prometheus" ["prometheus", "otlp-periodic", "none"],
    intKnob "metrics.otel-export-interval-ms" "Periodic OTLP metric export interval" 60000 1000 600000
  ]

telemetrySpecFromContext :: RunContext -> Either Text TelemetrySpec
telemetrySpecFromContext context = do
  let Dimensions resolvedTracing resolvedMetrics _ _ = context.dimensions
  tracing <- maybe (Left "telemetry.tracing is not applicable") Right resolvedTracing
  metrics <- maybe (Left "telemetry.metrics is not applicable") Right resolvedMetrics
  sampler <- parseSampler (knobText context.knobs (name "otel.sampler")) (knobDouble context.knobs (name "otel.sampler-arg"))
  processor <- parseProcessor context.knobs
  exporter <- parseProtocol (knobText context.knobs (name "otel.exporter"))
  endpoint <- parseEndpoint context.knobs
  compression <- parseCompression (knobText context.knobs (name "otel.compression"))
  reader <- parseReader (knobText context.knobs (name "metrics.otel-reader"))
  pure
    TelemetrySpec
      { tracing,
        metrics,
        serviceName = Text.replace "/" "." (renderScenarioId context.scenario),
        sampler,
        processor,
        exporter,
        endpoint,
        compression,
        probeRetain = integer "otel.inmemory.retain",
        shutdownMs = integer "otel.shutdown-timeout-ms",
        otelReader = reader,
        otelExportMs = integer "metrics.otel-export-interval-ms",
        scrapeMs = integer "metrics.scrape-interval-ms",
        wsSubscribers = integer "metrics.ws-subscribers",
        helpers = HelperProcess "kenshou",
        outDir = context.outDir,
        report = putSummary context Telemetry "telemetry"
      }
  where
    integer key = fromIntegral (knobInt context.knobs (name key))

parseSampler :: Text -> Double -> Either Text SamplerSpec
parseSampler "always-on" _ = Right AlwaysOn
parseSampler "always-off" _ = Right AlwaysOff
parseSampler "parentbased-always-on" _ = Right ParentBasedAlwaysOn
parseSampler "traceidratio" ratio = Right (TraceIdRatio ratio)
parseSampler "parentbased-traceidratio" ratio = Right (ParentBasedTraceIdRatio ratio)
parseSampler value _ = Left ("unsupported otel.sampler: " <> value)

parseProcessor :: ResolvedKnobs -> Either Text ProcessorSpec
parseProcessor knobs = case knobText knobs (name "otel.processor") of
  "simple" -> Right (SimpleProcessor timeoutMs)
  "batch"
    | batch > queue -> Left "otel.bsp.max-export-batch must not exceed otel.bsp.max-queue"
    | otherwise -> Right (BatchProcessor queue delay batch timeoutMs)
  value -> Left ("unsupported otel.processor: " <> value)
  where
    queue = integer "otel.bsp.max-queue"
    delay = integer "otel.bsp.schedule-delay-ms"
    batch = integer "otel.bsp.max-export-batch"
    timeoutMs = integer "otel.bsp.export-timeout-ms"
    integer key = fromIntegral (knobInt knobs (name key))

parseProtocol :: Text -> Either Text OtlpProtocol
parseProtocol "http-protobuf" = Right HttpProtobuf
parseProtocol "grpc" = Left "otel.exporter=grpc requires building kenshou-telemetry with -fotlp-grpc"
parseProtocol value = Left ("unsupported otel.exporter: " <> value)

parseEndpoint :: ResolvedKnobs -> Either Text OtlpEndpoint
parseEndpoint knobs = case (knobText knobs (name "otel.endpoint"), parseSinkFault (knobText knobs (name "otel.sink-fault"))) of
  (_, Left message) -> Left message
  ("", Right fault) -> Right (BuiltinSink fault)
  (url, Right SinkHealthy) -> Right (ExternalEndpoint url)
  (_, Right _) -> Left "otel.sink-fault is only valid with the built-in sink"

parseCompression :: Text -> Either Text OtlpCompression
parseCompression "none" = Right CompressionNone
parseCompression "gzip" = Right CompressionGzip
parseCompression value = Left ("unsupported otel.compression: " <> value)

parseReader :: Text -> Either Text OtelReader
parseReader "prometheus" = Right ReaderPrometheus
parseReader "otlp-periodic" = Right ReaderOtlpPeriodic
parseReader "none" = Right ReaderNone
parseReader value = Left ("unsupported metrics.otel-reader: " <> value)

parseSinkFault :: Text -> Either Text SinkFault
parseSinkFault value = maybe (Left ("unsupported otel.sink-fault: " <> value)) Right (lookup value values)
  where
    values = [(renderSinkFault fault, fault) | fault <- [SinkHealthy, SinkDelay200ms, SinkDelay2000ms, SinkStatus503, SinkHang, SinkRefuse]]

renderSinkFault :: SinkFault -> Text
renderSinkFault SinkHealthy = "none"
renderSinkFault SinkDelay200ms = "delay-200ms"
renderSinkFault SinkDelay2000ms = "delay-2000ms"
renderSinkFault SinkStatus503 = "status-503"
renderSinkFault SinkHang = "hang"
renderSinkFault SinkRefuse = "refuse"

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob key summary def low high = KnobSpec (name key) summary KnobInt (VInt def) (IntRange low high) []

doubleKnob :: Text -> Text -> Double -> Double -> Double -> KnobSpec
doubleKnob key summary def low high = KnobSpec (name key) summary KnobDouble (VDouble def) (DoubleRange low high) []

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob key summary def (first : rest) = KnobSpec (name key) summary KnobText (VText def) (OneOf (VText first :| fmap VText rest)) []
textKnob key _ _ [] = error ("text knob has no values: " <> Text.unpack key)

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName
