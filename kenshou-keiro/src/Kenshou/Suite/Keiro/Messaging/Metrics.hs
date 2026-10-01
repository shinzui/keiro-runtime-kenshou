module Kenshou.Suite.Keiro.Messaging.Metrics
  ( withMessagingTelemetry,
    probeMessagingMetrics,
    prometheusMatch,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad (forM, when)
import Data.Aeson (Value (..), decode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kenshou.Core.Context (ArtifactDir (..), RunContext, SummarySection (..), artifactPath, putSummary, requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), keiroRunner, keiroTelemetry)
import Kenshou.Telemetry (MetricsArm (..), TelemetryHandles (..), TelemetrySpec (..), withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..))
import Kiroku.Metrics (MetricsServer (..), MetricsServerConfig (..), defaultConfig, metricsEventHandler, newKirokuMetricsWith, snapshotMetrics, withMetricsServerWithStore)
import Kiroku.Store (ConnectionSettingsM (..), GlobalPosition (..), KirokuStore (publisher), defaultConnectionSettings, withStore)
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Text.Read (readMaybe)

-- Keep the native server and its store alive until telemetry has stopped its
-- scraper. Collection uses the same store callbacks in every enabled arm.
withMessagingTelemetry :: RunContext -> TelemetrySpec -> (FixtureEnv -> TelemetryHandles -> [Endpoint] -> IO a) -> IO a
withMessagingTelemetry context spec action = do
  storeVar <- newTVarIO Nothing
  collector <- if spec.metrics == MetricsOff then pure Nothing else Just <$> newKirokuMetricsWith (readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))) (pure 0)
  let settings = (defaultConnectionSettings (requirePostgres context).connectionString) {eventHandler = fmap (\metrics -> metricsEventHandler metrics Nothing) collector}
  withStore settings \store -> do
    atomically (writeTVar storeVar (Just store))
    let run endpoints = withTelemetry spec \telemetry -> do
          mapM_ telemetry.registerEndpoint endpoints
          runtimeTelemetry <- keiroTelemetry telemetry
          result <- action (FixtureEnv store (keiroRunner store) runtimeTelemetry) telemetry endpoints
          snapshot <- traverse snapshotMetrics collector
          putSummary context Telemetry "messaging-store-metrics" (object ["enabled" .= telemetry.metricsLive, "snapshot" .= snapshot, "endpoints" .= endpoints])
          -- Allow the separate scraper to observe the final stable state.
          when (spec.metrics == MetricsServeScraped) (threadDelay (2 * spec.scrapeMs * 1000))
          pure result
    case collector of
      Just metrics | spec.metrics `elem` [MetricsServe, MetricsServeScraped] ->
        withMetricsServerWithStore defaultConfig {port = 0} metrics store [] \server -> do
          let base = "http://127.0.0.1:" <> Text.pack (show server.serverPort)
          run [Endpoint "messaging-kiroku-json" JsonDocument (base <> "/metrics") Nothing, Endpoint "messaging-kiroku-prometheus" PrometheusText (base <> "/metrics/prometheus") Nothing]
      _ -> run []

-- Expected values come from the fixture's durable business checks, not from a
-- second read of the metric under test. Keep each response in the sealed run.
probeMessagingMetrics :: RunContext -> TelemetryHandles -> [Endpoint] -> Text -> [(Text, Double)] -> IO Bool
probeMessagingMetrics context telemetry native phase expected
  | not telemetry.servesEndpoints = pure (null native && telemetry.metricEndpoint == Nothing)
  | otherwise = do
      manager <- newManager defaultManagerSettings
      results <- forM (native <> maybe [] pure telemetry.metricEndpoint) \endpoint -> do
        request <- parseRequest (Text.unpack endpoint.url)
        response <- httpLbs request manager
        path <- artifactPath context LogsDir (Text.unpack (endpoint.name <> "-" <> phase) <> if endpoint.kind == JsonDocument then ".json" else ".prom")
        LBS.writeFile path response.responseBody
        let body = Text.decodeUtf8' (LBS.toStrict response.responseBody)
            correct = case endpoint.name of
              "messaging-kiroku-json" -> case decode response.responseBody of
                Just (Object fields) -> case KeyMap.lookup "store" fields of
                  Just (Object store) -> KeyMap.lookup "global_position" store == Just (Number 0)
                  _ -> False
                _ -> False
              "messaging-kiroku-prometheus" -> either (const False) (prometheusMatch [("kiroku_events_appended_total", 0)]) body
              "otel-prometheus" -> either (const False) (prometheusMatch expected) body
              _ -> False
        pure (statusCode response.responseStatus == 200 && correct)
      -- This fixture writes outbox/inbox tables, never the event store. Its
      -- native store position stays zero while Keiro's OTel counters change.
      pure (length native == 2 && telemetry.metricEndpoint /= Nothing && and results)

-- Match the complete expected label set, including the OTel scope label.
-- Reject duplicate or differently labelled series instead of summing them.
prometheusMatch :: [(Text, Double)] -> Text -> Bool
prometheusMatch expected body = not (null expected) && all matches expected
  where
    matches (metric, wanted) =
      let base = Text.takeWhile (/= '{') metric
          samples = [fields | line <- Text.lines body, let fields = Text.words (fst (Text.breakOn " # " line)), first : _ <- [fields], Text.takeWhile (/= '{') first == base]
       in case samples of
            [[name, raw]] -> name == metric && readMaybe (Text.unpack raw) == Just wanted
            _ -> False
