module Kenshou.Telemetry.Metrics
  ( MetricsRuntime (..),
    MetricsSnapshot (..),
    startMetrics,
    flushMetrics,
    stopMetrics,
  )
where

import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Monad (void)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Telemetry.Endpoint
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Tracing (otlpExporterConfig)
import Network.Socket (Socket, close)
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket)
import OpenTelemetry.Exporter.Metric (ResourceMetricsExport (..), ScopeMetricsExport (..))
import OpenTelemetry.Exporter.OTLP.Metric qualified as OtlpMetric
import OpenTelemetry.Exporter.Prometheus.WAI (prometheusApplication)
import OpenTelemetry.MeterProvider (SdkMeterEnv, collectResourceMetrics, createMeterProvider, defaultSdkMeterProviderOptions)
import OpenTelemetry.Metric.Core (Meter, MeterProvider, forceFlushMeterProvider, getMeter, shutdownMeterProvider)
import OpenTelemetry.MetricReader (PeriodicMetricReaderHandle (..), PeriodicMetricReaderOptions (..), forkPeriodicMetricReader)
import OpenTelemetry.Resource (emptyMaterializedResources)
import OpenTelemetry.Trace.Core (FlushResult, ShutdownResult, instrumentationLibrary)

data MetricsRuntime = MetricsRuntime
  { meter :: Maybe Meter,
    provider :: Maybe MeterProvider,
    env :: Maybe SdkMeterEnv,
    endpoint :: Maybe Endpoint,
    server :: Maybe (Async (), Socket),
    reader :: Maybe PeriodicMetricReaderHandle
  }

data MetricsSnapshot = MetricsSnapshot
  { resourceBatches :: Int,
    instruments :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON MetricsSnapshot where
  toJSON snapshot = object ["resourceBatches" .= snapshot.resourceBatches, "instruments" .= snapshot.instruments]

startMetrics :: TelemetrySpec -> IO MetricsRuntime
startMetrics spec = case spec.metrics of
  MetricsOff -> pure (MetricsRuntime Nothing Nothing Nothing Nothing Nothing Nothing)
  _ -> do
    (provider, env) <- createMeterProvider emptyMaterializedResources defaultSdkMeterProviderOptions
    meter <- getMeter provider (instrumentationLibrary "kenshou" "0.1.0.0")
    (endpoint, server) <- case (spec.metrics, spec.otelReader) of
      (arm, ReaderPrometheus) | arm `elem` [MetricsServe, MetricsServeScraped] -> do
        (port, socket) <- openFreePort
        running <- async (runSettingsSocket defaultSettings socket (prometheusApplication (Vector.fromList <$> collectResourceMetrics env)))
        let url = "http://127.0.0.1:" <> Text.pack (show port) <> "/metrics"
        pure (Just (Endpoint "otel-prometheus" PrometheusText url Nothing), Just (running, socket))
      _ -> pure (Nothing, Nothing)
    reader <- case spec.otelReader of
      ReaderOtlpPeriodic -> do
        exporter <- OtlpMetric.otlpMetricExporter (otlpExporterConfig spec)
        Just <$> forkPeriodicMetricReader env exporter (PeriodicMetricReaderOptions (spec.otelExportMs * 1000))
      _ -> pure Nothing
    pure (MetricsRuntime (Just meter) (Just provider) (Just env) endpoint server reader)

flushMetrics :: Int -> MetricsRuntime -> IO (Maybe FlushResult)
flushMetrics timeoutMs runtime = traverse (\provider -> forceFlushMeterProvider provider (Just (timeoutMs * 1000))) runtime.provider

stopMetrics :: Int -> MetricsRuntime -> IO (Maybe MetricsSnapshot, Maybe ShutdownResult)
stopMetrics timeoutMs runtime = do
  traverse_ (.stopPeriodicMetricReader) runtime.reader
  batches <- maybe (pure []) collectResourceMetrics runtime.env
  let snapshot = case runtime.env of
        Nothing -> Nothing
        Just _ -> Just (MetricsSnapshot (length batches) (sum [Vector.length scope.scopeMetricsExports | resource <- batches, scope <- Vector.toList resource.resourceMetricsScopes]))
  shutdown <- traverse (\provider -> shutdownMeterProvider provider (Just (timeoutMs * 1000))) runtime.provider
  case runtime.server of
    Nothing -> pure ()
    Just (running, socket) -> cancel running >> void (waitCatch running) >> close socket
  pure (snapshot, shutdown)

traverse_ :: (a -> IO b) -> Maybe a -> IO ()
traverse_ _ Nothing = pure ()
traverse_ action (Just value) = void (action value)
