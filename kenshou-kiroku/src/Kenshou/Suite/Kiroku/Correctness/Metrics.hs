module Kenshou.Suite.Kiroku.Correctness.Metrics (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad (replicateM)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Telemetry (TelemetryHandles (..), TelemetrySpec (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..))
import Kiroku.Metrics
import Kiroku.Store hiding (id, withKirokuStore)
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Network.WebSockets qualified as WebSocket
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [endpointsTruthful]

endpointsTruthful :: Scenario
endpointsTruthful =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/metrics/correctness/endpoints-truthful"),
      revision = 1,
      summary = "Checks live JSON, Prometheus, health and WebSocket metrics endpoints against store state.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs <> telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsServe :| [MetricsServeScraped]) MetricsServe),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runMetrics
    }

runMetrics :: RunContext -> IO ScenarioReport
runMetrics context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-configuration"] problem)
  Right spec -> withTelemetry (spec {scrapeMs = 100}) \telemetry -> runWithMetrics context telemetry.registerEndpoint

runWithMetrics :: RunContext -> (Endpoint -> IO ()) -> IO ScenarioReport
runWithMetrics context registerEndpoint = do
  storeVar <- newTVarIO Nothing
  metrics <- newKirokuMetricsWith (readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))) (pure 0)
  withKirokuStoreWithTap context (Just (metricsEventHandler metrics Nothing)) \store -> do
    atomically (writeTVar storeVar (Just store))
    gate <- newEmptyMVar
    slowDeliveries <- newIORef (0 :: Int)
    poisonDeliveries <- newIORef (0 :: Int)
    let slowName = SubscriptionName "metrics-slow"
        poisonName = SubscriptionName "metrics-poison"
        stream = StreamName "metrics-events"
        event = EventData Nothing (EventType "Metrics") (object []) Nothing Nothing Nothing
        slowHandler _ = readMVar gate >> atomicModifyIORef' slowDeliveries (\count -> (count + 1, ())) >> pure Continue
        poisonHandler row = do
          atomicModifyIORef' poisonDeliveries (\count -> (count + 1, ()))
          pure $ if row.globalPosition == GlobalPosition 1 then DeadLetter (DeadLetterPoison "metrics-fixture") else Continue
        cfg = defaultConfig {port = 0, readinessMaxLag = 10}
        awaitLive handle = timeout 10000000 loop
          where
            loop = do
              state <- handle.currentState
              case state of
                Just value | stateName value == "live" -> pure True
                _ -> threadDelay 10000 >> loop
        awaitReady manager base expected = timeout 10000000 (loop manager base)
          where
            loop mgr root = do
              (status, _) <- get mgr (root <> "/health/ready")
              if status == expected then pure True else threadDelay 10000 >> loop mgr root
    withSubscription store (defaultSubscriptionConfig slowName AllStreams slowHandler) \slow ->
      withSubscription store (defaultSubscriptionConfig poisonName AllStreams poisonHandler) \poison -> do
        live <- traverse awaitLive [slow, poison]
        withMetricsServerWithStore cfg metrics store [] \server -> do
          manager <- newManager defaultManagerSettings
          let base = "http://127.0.0.1:" <> show server.serverPort
          registerEndpoint (Endpoint "kiroku-json" JsonDocument (Text.pack (base <> "/metrics")) Nothing)
          registerEndpoint (Endpoint "kiroku-prometheus" PrometheusText (Text.pack (base <> "/metrics/prometheus")) Nothing)
          appended <- runStoreIO store (appendToStream stream NoStream (replicate 20 event))
          laggingReady <- awaitReady manager base 503
          (metricsStatus, metricsBody) <- get manager (base <> "/metrics")
          (promStatus, promBody) <- get manager (base <> "/metrics/prometheus")
          (liveStatus, _) <- get manager (base <> "/health/live")
          (unknownStatus, _) <- get manager (base <> "/metrics/unknown")
          socketPositions <- timeout 15000000 $ WebSocket.runClient "127.0.0.1" server.serverPort "/ws/events" \connection -> do
            WebSocket.sendTextData connection (encode (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int)]))
            _ <- waitForType connection "event_stream_started"
            replayed <- replicateM 20 (readEventPosition connection)
            added <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 20)) [event])
            next <- readEventPosition connection
            pure (replayed <> [next], added)
          putMVar gate ()
          caughtUp <- timeout 10000000 (waitForCount slowDeliveries 21)
          poisonCaughtUp <- timeout 10000000 (waitForCount poisonDeliveries 21)
          checkpointCaughtUp <- timeout 10000000 (waitForCheckpoint store slowName (GlobalPosition 21))
          slow.cancel
          poison.cancel
          quiescentReady <- awaitReady manager base 200
          (finalStatus, finalBody) <- get manager (base <> "/metrics")
          (finalPromStatus, finalPromBody) <- get manager (base <> "/metrics/prometheus")
          deliveredPoison <- readIORef poisonDeliveries
          finalSnapshot <- snapshotMetrics metrics
          inventory <- runStoreIO store subscriptionCheckpointInventory
          let jsonPosition body = decode body >>= look ["store", "global_position"] >>= number
              jsonLag body = decode body >>= look ["subscriptions", "metrics-slow", "lag"] >>= number
              number = \case Number value -> Just (truncate (realToFrac value :: Double) :: Int); _ -> Nothing
              prom = Text.decodeUtf8 . LazyByteString.toStrict
              promLine value body = Text.isInfixOf ("kiroku_events_appended_total " <> Text.pack (show value)) (prom body)
              checkpointPosition = case inventory of
                Right snapshot -> [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == slowName]
                Left _ -> []
              cells =
                [ ("workers-live", live == [Just True, Just True]),
                  ("known-workload-appended", case appended of Right result -> result.globalPosition == GlobalPosition 20; _ -> False),
                  ("metrics-json-head", metricsStatus == 200 && jsonPosition metricsBody == Just 20),
                  ("prometheus-appended-total", promStatus == 200 && promLine (20 :: Int) promBody),
                  ("readiness-detects-lag", laggingReady == Just True && maybe False (>= 20) (jsonLag metricsBody)),
                  ("liveness-healthy", liveStatus == 200),
                  ("unknown-subscription-404", unknownStatus == 404),
                  ("websocket-replay-live-order", case socketPositions of Just (positions, Right result) -> positions == [1 .. 21] && result.globalPosition == GlobalPosition 21; _ -> False),
                  ("slow-subscriber-catches-up", caughtUp == Just () && checkpointCaughtUp == Just () && checkpointPosition == [GlobalPosition 21]),
                  ("readiness-recovers", quiescentReady == Just True),
                  ("final-head-and-zero-lag", finalStatus == 200 && jsonPosition finalBody == Just 21 && jsonLag finalBody == Just 0),
                  ("final-prometheus-total", finalPromStatus == 200 && promLine (21 :: Int) finalPromBody),
                  ("poison-event-dead-lettered", poisonCaughtUp == Just () && deliveredPoison == 21 && finalSnapshot.counters.subscriptionsDeadLettered == 1)
                ]
          threadDelay 300000
          recordCells context "endpoints-truthful" [] cells

get :: Manager -> String -> IO (Int, LazyByteString.ByteString)
get manager url = do
  request <- parseRequest url
  response <- httpLbs request manager
  pure (statusCode (responseStatus response), responseBody response)

look :: [Text] -> Value -> Maybe Value
look [] value = Just value
look (key : keys) (Object properties) = KeyMap.lookup (Key.fromText key) properties >>= look keys
look _ _ = Nothing

waitForType :: WebSocket.Connection -> Text -> IO Value
waitForType connection wanted = do
  raw <- WebSocket.receiveData connection :: IO LazyByteString.ByteString
  case decode raw of
    Just value | look ["type"] value == Just (String wanted) -> pure value
    Just _ -> waitForType connection wanted
    Nothing -> fail "invalid WebSocket JSON frame"

readEventPosition :: WebSocket.Connection -> IO Int
readEventPosition connection = do
  value <- waitForType connection "event"
  case look ["event", "globalPosition"] value of
    Just (Number position) -> pure (truncate (realToFrac position :: Double))
    _ -> fail "WebSocket event omitted global position"

waitForCount :: IORef Int -> Int -> IO ()
waitForCount counter target = do
  count <- readIORef counter
  if count >= target then pure () else threadDelay 10000 >> waitForCount counter target

waitForCheckpoint :: KirokuStore -> SubscriptionName -> GlobalPosition -> IO ()
waitForCheckpoint store name wanted = do
  result <- runStoreIO store subscriptionCheckpointInventory
  case result of
    Right snapshot
      | [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [wanted] -> pure ()
    _ -> threadDelay 10000 >> waitForCheckpoint store name wanted
