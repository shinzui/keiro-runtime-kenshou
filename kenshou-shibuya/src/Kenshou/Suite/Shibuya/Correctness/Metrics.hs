module Kenshou.Suite.Shibuya.Correctness.Metrics (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, try)
import Data.Aeson (Value (..), decode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), Support (..), Supported (..), noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Kenshou.Telemetry.Endpoint (reserveFreePort)
import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shibuya.App (Master, defaultAppConfig, getAppMaster, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.Server (MetricsServerConfig (..), defaultConfig, startMetricsServer, stopMetricsServer)
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [endpointContract]

endpointContract :: Scenario
endpointContract =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/endpoint-contract"),
      revision = 1,
      summary = "HTTP metrics and health routes preserve their JSON, Prometheus, state and feature-flag contracts.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions {metrics = Supported (Support (MetricsServe :| [MetricsServeScraped]) MetricsServe)},
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runEndpointContract
    }

data HttpResult = HttpResult {status :: !Int, body :: !LazyByteString.ByteString}

runEndpointContract :: RunContext -> IO ScenarioReport
runEndpointContract context = do
  manager <- newManager defaultManagerSettings
  broker <- newSyntheticBroker defaultSyntheticConfig
  started <- newEmptyMVar
  release <- newEmptyMVar
  failures <- runEff $ runTracingNoop $ do
    let handler _ = do
          liftIO $ putMVar started ()
          liftIO $ takeMVar release
          pure AckOk
    result <- runApp defaultAppConfig [(ProcessorId "endpoint-contract", mkProcessor (syntheticAdapter broker) handler)]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> do
        checks <- liftIO $ withServer manager defaultConfig (getAppMaster handle) $ \port -> do
          idle <- checkIdleRoutes manager port
          _ <- publish broker Nothing "probe"
          began <- timeout 2000000 (takeMVar started)
          active <- if began == Nothing then pure ["handler-not-started"] else checkActiveState manager port
          putMVar release ()
          disabled <- withServer manager defaultConfig {enableJSON = False, enablePrometheus = False} (getAppMaster handle) (checkDisabledRoutes manager)
          pure (idle <> active <> disabled)
        stopApp handle
        pure checks
  putSummary context Verdicts "metrics-endpoint-contract" $ object ["failures" .= failures]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

withServer :: Manager -> MetricsServerConfig -> Master -> (Int -> IO [Text]) -> IO [Text]
withServer manager config master action = attempt (5 :: Int)
  where
    attempt 0 = pure ["metrics-server-did-not-bind"]
    attempt remaining = do
      port <- reserveFreePort
      bracket
        (startMetricsServer config {port = port} master)
        stopMetricsServer
        ( \_server -> do
            ready <- awaitResponse manager port (if config.enableJSON then "/health/live" else "/metrics/prometheus")
            if ready then action port else attempt (remaining - 1)
        )

awaitResponse :: Manager -> Int -> String -> IO Bool
awaitResponse manager port path = loop (20 :: Int)
  where
    loop 0 = pure False
    loop remaining = do
      result <- try (fetch manager port path) :: IO (Either SomeException HttpResult)
      case result of
        Right _ -> pure True
        Left _ -> threadDelay 50000 >> loop (remaining - 1)

fetch :: Manager -> Int -> String -> IO HttpResult
fetch manager port path = do
  request <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- httpLbs request manager
  pure $ HttpResult (statusCode (responseStatus response)) (responseBody response)

checkIdleRoutes :: Manager -> Int -> IO [Text]
checkIdleRoutes manager port = do
  allMetrics <- fetch manager port "/metrics"
  one <- fetch manager port "/metrics/endpoint-contract"
  unknown <- fetch manager port "/metrics/unknown"
  prometheus <- fetch manager port "/metrics/prometheus"
  health <- fetch manager port "/health"
  live <- fetch manager port "/health/live"
  ready <- fetch manager port "/health/ready"
  websocket <- fetch manager port "/ws"
  missing <- fetch manager port "/no-such-route"
  let metricFamilies =
        [ "shibuya_messages_received_total",
          "shibuya_messages_processed_total",
          "shibuya_messages_failed_total",
          "shibuya_processor_state",
          "shibuya_processor_in_flight"
        ]
      promText = TextEncoding.decodeUtf8 (LazyByteString.toStrict prometheus.body)
  pure $
    check "metrics-all" (allMetrics.status == 200 && hasPath ["endpoint-contract", "stats", "received"] allMetrics.body)
      <> check "metrics-one" (one.status == 200 && hasPath ["state", "status"] one.body && hasPath ["batch"] one.body && hasPath ["startedAt"] one.body)
      <> check "metrics-unknown" (unknown.status == 404 && hasPath ["error"] unknown.body && hasPath ["processor"] unknown.body)
      <> check "prometheus-families" (prometheus.status == 200 && all (\name -> Text.isInfixOf ("# TYPE " <> name <> " ") promText && Text.isInfixOf (name <> "{processor=\"endpoint-contract\"} ") promText) metricFamilies)
      <> check "prometheus-idle-state" (Text.isInfixOf "shibuya_processor_state{processor=\"endpoint-contract\"} 1.0" promText && Text.isInfixOf "1=idle, 2=processing, 3=failed, 4=stopped" promText)
      <> check "health" (health.status == 200 && hasPath ["status", "ready"] health.body && hasPath ["processors"] health.body)
      <> check "health-live" (live.status == 200 && hasPath ["alive"] live.body)
      <> check "health-ready" (ready.status == 200 && hasPath ["ready"] ready.body && hasPath ["processors"] ready.body && hasPath ["dependencies"] ready.body)
      <> check "websocket-http" (websocket.status == 404 && hasPath ["error"] websocket.body)
      <> check "unknown-route" (missing.status == 404 && hasPath ["error"] missing.body)

checkActiveState :: Manager -> Int -> IO [Text]
checkActiveState manager port = do
  response <- fetch manager port "/metrics/prometheus"
  let body = TextEncoding.decodeUtf8 (LazyByteString.toStrict response.body)
  pure $ check "prometheus-processing-state" (response.status == 200 && Text.isInfixOf "shibuya_processor_state{processor=\"endpoint-contract\"} 2.0" body && Text.isInfixOf "shibuya_processor_in_flight{processor=\"endpoint-contract\"} 1.0" body)

checkDisabledRoutes :: Manager -> Int -> IO [Text]
checkDisabledRoutes manager port = do
  responses <- traverse (fetch manager port) ["/metrics", "/metrics/endpoint-contract", "/metrics/prometheus", "/health", "/health/live", "/health/ready"]
  pure $ check "disabled-routes" (all (\response -> response.status == 404 && hasPath ["error"] response.body) responses)

hasPath :: [Text] -> LazyByteString.ByteString -> Bool
hasPath keys body = maybe False (go keys) (decode body)
  where
    go [] _ = True
    go (key : rest) (Object value) = maybe False (go rest) (KeyMap.lookup (fromString (Text.unpack key)) value)
    go _ _ = False

check :: Text -> Bool -> [Text]
check label success = [label | not success]
