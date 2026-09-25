module Kenshou.Telemetry.Tracing
  ( TracingRuntime (..),
    startTracing,
    flushTracing,
    stopTracing,
    otlpExporterConfig,
  )
where

import Control.Monad (when)
import Data.Text qualified as Text
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Tracing.Pipeline
import Kenshou.Telemetry.Tracing.Probe
import OpenTelemetry.Exporter.OTLP.Span qualified as OtlpSpan
import OpenTelemetry.Exporter.Span (SpanExporter)
import OpenTelemetry.Processor.Batch.Span qualified as Batch
import OpenTelemetry.Processor.Simple.Span qualified as Simple
import OpenTelemetry.Processor.Span (SpanProcessor)
import OpenTelemetry.Propagator (setGlobalTextMapPropagator)
import OpenTelemetry.Propagator.W3CTraceContext (w3cTraceContextPropagator)
import OpenTelemetry.Resource (materializeResources, mkResource, (.=))
import OpenTelemetry.Trace.Core
import OpenTelemetry.Trace.Id.Generator.Default (defaultIdGenerator)
import OpenTelemetry.Trace.Sampler qualified as Sampler

data TracingRuntime = TracingRuntime
  { tracer :: Maybe Tracer,
    provider :: Maybe TracerProvider,
    probe :: Maybe SpanProbe,
    pipeline :: Maybe PipelineStats
  }

startTracing :: TelemetrySpec -> IO TracingRuntime
startTracing spec = do
  when (spec.tracing /= TracingOff) (setGlobalTextMapPropagator w3cTraceContextPropagator)
  case spec.tracing of
    TracingOff -> pure (TracingRuntime Nothing Nothing Nothing Nothing)
    TracingNoop -> do
      provider <- createTracerProvider [] (providerOptions spec)
      pure (runtime provider Nothing Nothing)
    TracingSdkInMemory -> do
      stats <- newPipelineStats
      (probe, probeProcessor) <- newSpanProbe spec.probeRetain
      provider <- createTracerProvider [countingProcessor stats, instrumentProcessorSuccess stats probeProcessor] (providerOptions spec)
      pure (runtime provider (Just probe) (Just stats))
    TracingSdkOtlp -> do
      stats <- newPipelineStats
      exporter <- instrumentExporter stats <$> OtlpSpan.otlpExporter (otlpExporterConfig spec)
      processor <- makeProcessor spec.processor exporter
      provider <- createTracerProvider [countingProcessor stats, processor] (providerOptions spec)
      pure (runtime provider Nothing (Just stats))
  where
    runtime provider probe pipeline = TracingRuntime (Just (makeTracer provider (instrumentationLibrary "kenshou" "0.1.0.0") tracerOptions)) (Just provider) probe pipeline

flushTracing :: Int -> TracingRuntime -> IO (Maybe FlushResult)
flushTracing timeoutMs runtime = traverse (\provider -> forceFlushTracerProvider provider (Just (timeoutMs * 1000))) runtime.provider

stopTracing :: Int -> TracingRuntime -> IO (Maybe ShutdownResult)
stopTracing timeoutMs runtime = traverse (\provider -> shutdownTracerProvider provider (Just (timeoutMs * 1000))) runtime.provider

providerOptions :: TelemetrySpec -> TracerProviderOptions
providerOptions spec =
  emptyTracerProviderOptions
    { tracerProviderOptionsIdGenerator = defaultIdGenerator,
      tracerProviderOptionsSampler = sampler spec.sampler,
      tracerProviderOptionsResources = materializeResources (mkResource ["service.name" .= spec.serviceName]),
      tracerProviderOptionsPropagators = w3cTraceContextPropagator
    }

sampler :: SamplerSpec -> Sampler.Sampler
sampler AlwaysOn = Sampler.alwaysOn
sampler AlwaysOff = Sampler.alwaysOff
sampler ParentBasedAlwaysOn = Sampler.parentBased (Sampler.parentBasedOptions Sampler.alwaysOn)
sampler (TraceIdRatio ratio) = Sampler.traceIdRatioBased ratio
sampler (ParentBasedTraceIdRatio ratio) = Sampler.parentBased (Sampler.parentBasedOptions (Sampler.traceIdRatioBased ratio))

makeProcessor :: ProcessorSpec -> SpanExporter -> IO SpanProcessor
makeProcessor (SimpleProcessor timeoutMs) exporter = Simple.simpleProcessor (Simple.SimpleProcessorConfig exporter (timeoutMs * 1000))
makeProcessor (BatchProcessor queue delay batch timeoutMs) exporter =
  Batch.batchProcessor
    Batch.batchTimeoutConfig
      { Batch.maxQueueSize = queue,
        Batch.scheduledDelayMillis = delay,
        Batch.maxExportBatchSize = batch,
        Batch.exportTimeoutMillis = timeoutMs
      }
    exporter

otlpExporterConfig :: TelemetrySpec -> OtlpSpan.OTLPExporterConfig
otlpExporterConfig spec =
  OtlpSpan.OTLPExporterConfig
    { OtlpSpan.otlpEndpoint = Just (Text.unpack (endpointBase spec.endpoint)),
      OtlpSpan.otlpTracesEndpoint = Nothing,
      OtlpSpan.otlpMetricsEndpoint = Nothing,
      OtlpSpan.otlpInsecure = True,
      OtlpSpan.otlpSpanInsecure = True,
      OtlpSpan.otlpMetricInsecure = True,
      OtlpSpan.otlpCertificate = Nothing,
      OtlpSpan.otlpTracesCertificate = Nothing,
      OtlpSpan.otlpMetricCertificate = Nothing,
      OtlpSpan.otlpHeaders = Nothing,
      OtlpSpan.otlpTracesHeaders = Nothing,
      OtlpSpan.otlpMetricsHeaders = Nothing,
      OtlpSpan.otlpCompression = Just (case spec.compression of CompressionNone -> OtlpSpan.None; CompressionGzip -> OtlpSpan.GZip),
      OtlpSpan.otlpTracesCompression = Nothing,
      OtlpSpan.otlpMetricsCompression = Nothing,
      OtlpSpan.otlpTimeout = Just (processorTimeout spec.processor),
      OtlpSpan.otlpTracesTimeout = Nothing,
      OtlpSpan.otlpMetricsTimeout = Nothing,
      OtlpSpan.otlpProtocol = Just OtlpSpan.HttpProtobuf,
      OtlpSpan.otlpTracesProtocol = Nothing,
      OtlpSpan.otlpMetricsProtocol = Nothing
    }

endpointBase :: OtlpEndpoint -> Text.Text
endpointBase (ExternalEndpoint url) = url
endpointBase (BuiltinSink _) = "http://127.0.0.1:4318"

processorTimeout :: ProcessorSpec -> Int
processorTimeout (SimpleProcessor timeoutMs) = timeoutMs
processorTimeout (BatchProcessor _ _ _ timeoutMs) = timeoutMs
