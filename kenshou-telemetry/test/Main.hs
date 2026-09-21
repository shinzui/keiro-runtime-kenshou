module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Monad (replicateM_, void)
import Data.IORef
import Data.List (find)
import Data.Maybe (fromJust)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), renderKnobName)
import Kenshou.Telemetry.Sink qualified as Sink
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Tracing
import Kenshou.Telemetry.Tracing.Pipeline
import Kenshou.Telemetry.Tracing.Probe
import OpenTelemetry.Context.ThreadLocal (getContext)
import OpenTelemetry.Exporter.Span (ExportResult (..), SpanExporter (..))
import OpenTelemetry.Processor.Batch.Span qualified as Batch
import OpenTelemetry.Processor.Simple.Span qualified as Simple
import OpenTelemetry.Propagator (emptyTextMap, inject, textMapToList)
import OpenTelemetry.Trace.Core
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "telemetryKnobs" do
    it "declares each shared knob once" do
      let names = fmap (renderKnobName . (.name)) telemetryKnobs
      length names `shouldBe` length (unique names)
    it "bounds the trace-id ratio to zero through one" do
      fmap (.allowed) (find ((== "otel.sampler-arg") . renderKnobName . (.name)) telemetryKnobs)
        `shouldBe` Just (DoubleRange 0 1)

  describe "tracing arms" do
    it "does not construct a provider under off" do
      runtime <- startTracing (testSpec TracingOff)
      isNothing runtime.tracer `shouldBe` True
      isNothing runtime.provider `shouldBe` True

    it "constructs a disabled tracer under noop" do
      runtime <- startTracing (testSpec TracingNoop)
      let tracer = fromJust runtime.tracer
      tracerIsEnabled tracer `shouldBe` False
      inSpan tracer "ignored" defaultSpanArguments (pure ())
      _ <- stopTracing 1000 runtime
      pure ()

    it "retains a bounded, parented trace and installs W3C propagation" do
      runtime <- startTracing ((testSpec TracingSdkInMemory) {probeRetain = 4})
      let tracer = fromJust runtime.tracer
          provider = fromJust runtime.provider
      replicateM_ 5 (inSpan tracer "discarded" defaultSpanArguments (pure ()))
      headers <- inSpan' tracer "parent" defaultSpanArguments \_ -> do
        nested <- inSpan tracer "child" defaultSpanArguments (pure ())
        activeContext <- getContext
        carrier <- inject (getTracerProviderPropagators provider) activeContext emptyTextMap
        pure (nested, textMapToList carrier)
      _ <- flushTracing 1000 runtime
      let probe = fromJust runtime.probe
      views <- readSpans probe
      seen <- spansSeen probe
      seen `shouldBe` 7
      length views `shouldBe` 4
      let child = fromJust (find ((== "child") . (.name)) views)
          parent = fromJust (find ((== "parent") . (.name)) views)
      child.traceId `shouldBe` parent.traceId
      child.parentSpanId `shouldBe` Just parent.spanId
      snd headers `shouldSatisfy` any ((== "traceparent") . fst)
      snapshot <- snapshotPipeline (fromJust runtime.pipeline)
      snapshot.spansEnded `shouldBe` 7
      snapshot.spansExportedOk `shouldBe` 7
      snapshot.spansDropped `shouldBe` 0
      _ <- stopTracing 1000 runtime
      pure ()

    it "exports plain and gzip OTLP requests to the built-in sink" do
      forCompression CompressionNone
      forCompression CompressionGzip

    it "accounts for alternating exporter failures exactly" do
      stats <- newPipelineStats
      calls <- newIORef (0 :: Int)
      let exporter =
            SpanExporter
              { spanExporterExport = \_ -> do
                  call <- atomicModifyIORef' calls (\value -> let next = value + 1 in (next, next))
                  pure (if even call then Failure Nothing else Success),
                spanExporterShutdown = pure ShutdownSuccess,
                spanExporterForceFlush = pure FlushSuccess
              }
      processor <- Simple.simpleProcessor (Simple.SimpleProcessorConfig (instrumentExporter stats exporter) 1_000_000)
      provider <- createTracerProvider [countingProcessor stats, processor] emptyTracerProviderOptions
      let tracer = makeTracer provider (instrumentationLibrary "pipeline-test" "1") tracerOptions
      replicateM_ 10 (inSpan tracer "alternating" defaultSpanArguments (pure ()))
      _ <- shutdownTracerProvider provider (Just 1_000_000)
      snapshot <- snapshotPipeline stats
      snapshot.spansEnded `shouldBe` snapshot.spansExportedOk + snapshot.spansExportFailed + snapshot.spansDropped
      snapshot.spansExportedOk `shouldBe` 5
      snapshot.spansExportFailed `shouldBe` 5

    it "drops instead of blocking when a batch queue is full" do
      stats <- newPipelineStats
      releaseExporter <- newEmptyMVar
      let exporter =
            SpanExporter
              { spanExporterExport = \_ -> readMVar releaseExporter >> pure Success,
                spanExporterShutdown = pure ShutdownSuccess,
                spanExporterForceFlush = pure FlushSuccess
              }
      processor <-
        Batch.batchProcessor
          Batch.batchTimeoutConfig
            { Batch.maxQueueSize = 8,
              Batch.scheduledDelayMillis = 10,
              Batch.maxExportBatchSize = 4,
              Batch.exportTimeoutMillis = 5_000
            }
          (instrumentExporter stats exporter)
      provider <- createTracerProvider [countingProcessor stats, processor] emptyTracerProviderOptions
      let tracer = makeTracer provider (instrumentationLibrary "backpressure-test" "1") tracerOptions
      completed <- timeout 1_000_000 (replicateM_ 10_000 (inSpan tracer "queued" defaultSpanArguments (pure ())))
      completed `shouldBe` Just ()
      beforeRelease <- snapshotPipeline stats
      beforeRelease.spansDropped `shouldSatisfy` (> 0)
      putMVar releaseExporter ()
      void (shutdownTracerProvider provider (Just 1_000_000))

testSpec :: TracingArm -> TelemetrySpec
testSpec tracing =
  TelemetrySpec
    { tracing,
      metrics = MetricsOff,
      serviceName = "kenshou.test",
      sampler = AlwaysOn,
      processor = SimpleProcessor 1000,
      exporter = HttpProtobuf,
      endpoint = BuiltinSink SinkHealthy,
      compression = CompressionNone,
      probeRetain = 16,
      shutdownMs = 1000,
      otelReader = ReaderNone,
      otelExportMs = 1000,
      scrapeMs = 1000,
      wsSubscribers = 0,
      helpers = HelperInProcess,
      workerContext = Nothing,
      outDir = ".tmp/telemetry-test",
      report = const (pure ())
    }

forCompression :: OtlpCompression -> IO ()
forCompression compression = Sink.withSink SinkHealthy \sink -> do
  let spec = (testSpec TracingSdkOtlp) {endpoint = ExternalEndpoint sink.endpoint, compression}
  runtime <- startTracing spec
  let tracer = fromJust runtime.tracer
  inSpan tracer "exported" defaultSpanArguments (pure ())
  _ <- flushTracing 2000 runtime
  _ <- stopTracing 2000 runtime
  stats <- sink.snapshot
  stats.spansReceived `shouldBe` 1

isNothing :: Maybe value -> Bool
isNothing Nothing = True
isNothing (Just _) = False

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (value : values) = value : unique (filter (/= value) values)
