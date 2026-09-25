module Kenshou.Suite.Shibuya.Correctness.Metrics (scenarios, readyFailures, liveFailures, counterFailures, sustainedLoadFailures, exceptionRecoveryFailures, websocketFlagFailures, websocketUnsubscribeFailures, websocketSlotFailures) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (Exception, SomeException, bracket, finally, fromException, throwIO, try)
import Control.Monad (when)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (getCurrentTime)
import Effectful (Limit (..), Persistence (..), UnliftStrategy (..), liftIO, runEff, withEffToIO)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), Support (..), Supported (..), noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerStats (..), SyntheticBroker, SyntheticConfig (..), brokerStats, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Kenshou.Telemetry.Endpoint (reserveFreePort)
import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Network.WebSockets qualified as WebSockets
import Shibuya.App (Master, QueueProcessor (..), defaultAppConfig, getAppMaster, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Metrics (AckDecisionMetric (..), ProcessorId (..), beginProcessing, finishProcessing, incrementReceived, newMetricsHandle, sampleMetrics)
import Shibuya.Metrics.Server (MetricsServerConfig (..), defaultConfig, startMetricsServer, stopMetricsServer)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [endpointContract, readyReflectsFailedProcessor, liveReflectsStoppedMaster, countersDistinguishRetries, readyNotStuckUnderLoad, readyRecoversAfterException, websocketFlagGatesUpgrades, websocketUnsubscribeAll, websocketSlotAccounting]

metricsDimensions :: DimensionSupport
metricsDimensions = noDimensions {metrics = Supported (Support (MetricsServe :| [MetricsServeScraped]) MetricsServe)}

endpointContract :: Scenario
endpointContract =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/endpoint-contract"),
      revision = 1,
      summary = "HTTP metrics and health routes preserve their JSON, Prometheus, state and feature-flag contracts.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runEndpointContract
    }

readyReflectsFailedProcessor :: Scenario
readyReflectsFailedProcessor = healthScenario "shibuya/metrics/correctness/ready-reflects-a-failed-processor" "Readiness retains a failed configured processor after its source exits." "REV-8-F1" runReadyFailed

liveReflectsStoppedMaster :: Scenario
liveReflectsStoppedMaster = healthScenario "shibuya/metrics/correctness/live-reflects-a-stopped-master" "Liveness reports a stopped master as unavailable." "REV-8-F2" runLiveStopped

countersDistinguishRetries :: Scenario
countersDistinguishRetries =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/counters-distinguish-retries-from-success"),
      revision = 1,
      summary = "Prometheus distinguishes a retried delivery from one completed successfully.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-7",
              summary = "REV-7-A2",
              expectedFailures = ["REV-7-A2"],
              appliesTo = AllCohorts
            },
      run = runCounters
    }

readyNotStuckUnderLoad :: Scenario
readyNotStuckUnderLoad =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/ready-not-stuck-under-sustained-load"),
      revision = 1,
      summary = "A processor making steady progress remains ready beyond the stuck threshold while a blocked control becomes unready.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-7",
              summary = "REV-7-F1",
              expectedFailures = ["REV-7-F1"],
              appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-core" :| [VersionBelow "shibuya-core" "0.10.0.0"])
            },
      run = \context -> sustainedLoadFailures >>= healthReport context "sustained-load-readiness"
    }

readyRecoversAfterException :: Scenario
readyRecoversAfterException =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/ready-recovers-after-transient-handler-exception"),
      revision = 1,
      summary = "Readiness recovers after one handler exception is retried and subsequent work makes progress.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-7",
              summary = "transient-handler-error-sticks-failed-state",
              expectedFailures = ["transient-handler-error-sticks-failed-state"],
              appliesTo = AllCohorts
            },
      run = \context -> exceptionRecoveryFailures >>= healthReport context "transient-exception-readiness"
    }

websocketFlagGatesUpgrades :: Scenario
websocketFlagGatesUpgrades =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/websocket-flag-gates-upgrades"),
      revision = 1,
      summary = "Disabling the WebSocket endpoint prevents an upgrade while the enabled endpoint still serves a snapshot.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-9",
              summary = "REV-9-F2",
              expectedFailures = ["REV-9-F2"],
              appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-metrics" :| [VersionBelow "shibuya-metrics" "0.10.0.0"])
            },
      run = \context -> websocketFlagFailures >>= healthReport context "websocket-flag"
    }

websocketUnsubscribeAll :: Scenario
websocketUnsubscribeAll =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates"),
      revision = 1,
      summary = "Unsubscribing from a processor after subscribe-all suppresses its updates while other subscriptions remain live.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-9",
              summary = "REV-9-F3",
              expectedFailures = ["REV-9-F3"],
              appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-metrics" :| [VersionBelow "shibuya-metrics" "0.10.0.0"])
            },
      run = \context -> websocketUnsubscribeFailures >>= healthReport context "websocket-unsubscribe-all"
    }

websocketSlotAccounting :: Scenario
websocketSlotAccounting =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/metrics/concurrency/websocket-slot-accounting"),
      revision = 1,
      summary = "Repeated clean closes, peer drops and early drops release WebSocket connection slots.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-9",
              summary = "REV-9-F1",
              expectedFailures = ["REV-9-F1"],
              appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-metrics" :| [VersionBelow "shibuya-metrics" "0.10.0.0"])
            },
      run = \context -> websocketSlotFailures >>= healthReport context "websocket-slot-accounting"
    }

healthScenario :: Text -> Text -> Text -> (RunContext -> IO ScenarioReport) -> Scenario
healthScenario identifier description finding action =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId identifier),
      revision = 1,
      summary = description,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = metricsDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-8",
              summary = finding,
              expectedFailures = [finding],
              appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-metrics" :| [VersionBelow "shibuya-metrics" "0.10.0.0"])
            },
      run = action
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
hasPath keys body = maybe False (const True) (lookupPath keys body)

lookupPath :: [Text] -> LazyByteString.ByteString -> Maybe Value
lookupPath keys body = decode body >>= go keys
  where
    go [] value = Just value
    go (key : rest) (Object value) = KeyMap.lookup (fromString (Text.unpack key)) value >>= go rest
    go _ _ = Nothing

check :: Text -> Bool -> [Text]
check label success = [label | not success]

runReadyFailed :: RunContext -> IO ScenarioReport
runReadyFailed context = readyFailures >>= healthReport context "ready-failed-processor"

readyFailures :: IO [Text]
readyFailures = do
  manager <- newManager defaultManagerSettings
  broker <- newSyntheticBroker defaultSyntheticConfig {sourceFault = Just (1, "scripted source failure")}
  failures <- runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig [(ProcessorId "readiness-failure", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $
        withServer manager defaultConfig (getAppMaster handle) $ \port -> do
          before <- fetch manager port "/health/ready"
          _ <- publish broker Nothing "probe"
          ended <- timeout 5000000 (runInIO $ waitApp handle)
          after <- fetch manager port "/health/ready"
          runInIO $ stopApp handle
          pure $
            check "ready-before-failure" (before.status == 200 && hasPath ["ready"] before.body)
              <> check "source-did-not-fail" (ended /= Nothing)
              <> check "REV-8-F1" (after.status == 503 && hasPath ["ready"] after.body)
  pure failures

runLiveStopped :: RunContext -> IO ScenarioReport
runLiveStopped context = liveFailures >>= healthReport context "live-stopped-master"

liveFailures :: IO [Text]
liveFailures = do
  manager <- newManager defaultManagerSettings
  broker <- newSyntheticBroker defaultSyntheticConfig
  failures <- runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig [(ProcessorId "liveness-stopped", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $
        withServer manager defaultConfig (getAppMaster handle) $ \port -> do
          before <- fetch manager port "/health/live"
          runInIO $ stopApp handle
          after <- fetch manager port "/health/live"
          runInIO $ stopApp handle
          afterAgain <- fetch manager port "/health/live"
          pure $
            check "live-before-stop" (before.status == 200 && hasPath ["alive"] before.body)
              <> check "REV-8-F2" (after.status == 503 && afterAgain.status == 503 && hasPath ["alive"] after.body && hasPath ["alive"] afterAgain.body)
  pure failures

healthReport :: RunContext -> Text -> [Text] -> IO ScenarioReport
healthReport context name failures = do
  putSummary context Verdicts name $ object ["failures" .= failures]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runCounters :: RunContext -> IO ScenarioReport
runCounters context = counterFailures >>= healthReport context "retry-counter-truthfulness"

counterFailures :: IO [Text]
counterFailures = do
  manager <- newManager defaultManagerSettings
  retryBroker <- newSyntheticBroker defaultSyntheticConfig
  successBroker <- newSyntheticBroker defaultSyntheticConfig
  failures <- runEff $ runTracingNoop $ do
    let processors =
          [ (ProcessorId "retry", mkProcessor (syntheticAdapter retryBroker) (\_ -> pure (AckRetry (RetryDelay 60)))),
            (ProcessorId "success", mkProcessor (syntheticAdapter successBroker) (\_ -> pure AckOk))
          ]
    result <- runApp defaultAppConfig processors
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $
        withServer manager defaultConfig (getAppMaster handle) $ \port -> do
          _ <- publish retryBroker Nothing "probe"
          _ <- publish successBroker Nothing "probe"
          settled <- timeout 3000000 $ awaitDecisions retryBroker successBroker
          metricsSettled <- timeout 2000000 $ awaitIdleCounters manager port
          retryStats <- brokerStats retryBroker
          successStats <- brokerStats successBroker
          retryJson <- fetch manager port "/metrics/retry"
          successJson <- fetch manager port "/metrics/success"
          prom <- fetch manager port "/metrics/prometheus"
          runInIO $ stopApp handle
          let retrySamples = processorSamples "retry" prom.body
              successSamples = processorSamples "success" prom.body
          pure $
            check "decisions-not-settled" (settled == Just ())
              <> check "metrics-not-settled" (metricsSettled == Just ())
              <> check "distinct-broker-decisions" (retryStats.retried == 1 && retryStats.finalizedOk == 0 && successStats.finalizedOk == 1 && successStats.retried == 0)
              <> check "documented-processed-mapping" (all (\response -> response.status == 200 && lookupPath ["stats", "received"] response.body == Just (Number 1) && lookupPath ["stats", "processed"] response.body == Just (Number 1) && lookupPath ["stats", "failed"] response.body == Just (Number 0)) [retryJson, successJson])
              <> check "prometheus-samples-present" (prom.status == 200 && length retrySamples >= 5 && length successSamples >= 5)
              <> check "REV-7-A2" (retrySamples /= successSamples)
  mapping <- decisionMappingFailures
  pure $ failures <> mapping

decisionMappingFailures :: IO [Text]
decisionMappingFailures = do
  now <- getCurrentTime
  outcomes <-
    traverse
      ( \(name, decision, processed, failed, state) -> do
          handle <- newMetricsHandle now
          incrementReceived handle
          _ <- beginProcessing handle 1
          finishProcessing handle decision
          snapshot <- sampleMetrics handle
          let body = encode snapshot
          pure $
            check
              ("decision-mapping-" <> name)
              ( lookupPath ["stats", "received"] body == Just (Number 1)
                  && lookupPath ["stats", "processed"] body == Just (Number processed)
                  && lookupPath ["stats", "failed"] body == Just (Number failed)
                  && lookupPath ["state", "status"] body == Just (String state)
              )
      )
      [ ("ok", Right CountProcessed, 1, 0, "idle"),
        ("retry", Right CountProcessed, 1, 0, "idle"),
        ("dead-letter", Right CountFailed, 0, 1, "idle"),
        ("exception", Left "scripted handler exception", 0, 1, "failed"),
        ("halt", Right (CountHalt "scripted halt"), 0, 0, "failed")
      ]
  pure $ concat outcomes

awaitDecisions :: SyntheticBroker -> SyntheticBroker -> IO ()
awaitDecisions retryBroker successBroker = do
  retry <- brokerStats retryBroker
  success <- brokerStats successBroker
  if retry.retried >= 1 && success.finalizedOk >= 1
    then pure ()
    else threadDelay 10000 >> awaitDecisions retryBroker successBroker

awaitIdleCounters :: Manager -> Int -> IO ()
awaitIdleCounters manager port = do
  retry <- fetch manager port "/metrics/retry"
  success <- fetch manager port "/metrics/success"
  let settled response = lookupPath ["stats", "processed"] response.body == Just (Number 1) && lookupPath ["state", "status"] response.body == Just (String "idle")
  if settled retry && settled success
    then pure ()
    else threadDelay 10000 >> awaitIdleCounters manager port

processorSamples :: Text -> LazyByteString.ByteString -> [Text]
processorSamples processor body =
  let marker = "processor=\"" <> processor <> "\""
      normalized = "processor=\"<id>\""
   in sort [Text.replace marker normalized line | line <- Text.lines (TextEncoding.decodeUtf8 (LazyByteString.toStrict body)), Text.isInfixOf marker line]

websocketFlagFailures :: IO [Text]
websocketFlagFailures = do
  manager <- newManager defaultManagerSettings
  broker <- newSyntheticBroker defaultSyntheticConfig
  runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig [(ProcessorId "websocket-flag", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> do
        let master = getAppMaster handle
        failures <- liftIO $ do
          enabled <- withServer manager defaultConfig master $ \port -> do
            response <- websocketProbe port
            pure $ check "enabled-websocket-control" (case response of Just (Right frame) -> lookupPath ["type"] frame == Just (String "snapshot"); _ -> False)
          disabled <- withServer manager defaultConfig {enableWebSocket = False} master $ \port -> do
            response <- websocketProbe port
            pure $ case response of
              Nothing -> ["disabled-upgrade-timeout"]
              Just (Left _) -> []
              Just (Right _) -> ["REV-9-F2"]
          pure (enabled <> disabled)
        stopApp handle
        pure failures

websocketProbe :: Int -> IO (Maybe (Either SomeException LazyByteString.ByteString))
websocketProbe port =
  timeout 2000000 $
    (try (WebSockets.runClient "127.0.0.1" port "/ws" WebSockets.receiveData) :: IO (Either SomeException LazyByteString.ByteString))

websocketUnsubscribeFailures :: IO [Text]
websocketUnsubscribeFailures = do
  manager <- newManager defaultManagerSettings
  alphaBroker <- newSyntheticBroker defaultSyntheticConfig
  betaBroker <- newSyntheticBroker defaultSyntheticConfig
  runEff $ runTracingNoop $ do
    let processors =
          [ (ProcessorId "alpha", mkProcessor (syntheticAdapter alphaBroker) (\_ -> pure AckOk)),
            (ProcessorId "beta", mkProcessor (syntheticAdapter betaBroker) (\_ -> pure AckOk))
          ]
    result <- runApp defaultAppConfig processors
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> do
        failures <- liftIO $ withServer manager defaultConfig (getAppMaster handle) $ \port -> do
          session <-
            timeout 7000000 $
              ( try
                  ( WebSockets.runClient "127.0.0.1" port "/ws" $ \connection -> do
                      initial <- receiveFrame connection
                      WebSockets.sendTextData connection $ encode $ object ["type" .= ("unsubscribe" :: Text), "processors" .= (["alpha"] :: [Text])]
                      WebSockets.sendTextData connection $ encode $ object ["type" .= ("ping" :: Text)]
                      pong <- receiveFrame connection
                      _ <- publish alphaBroker Nothing "first"
                      _ <- publish betaBroker Nothing "first"
                      finalized <- timeout 2000000 $ awaitFinalizedPair alphaBroker betaBroker
                      first <- receiveFrame connection
                      second <- receiveFrame connection
                      let frames = catMaybes [first, second]
                          updates processor = any (\frame -> lookupPath ["type"] frame == Just (String "update") && lookupPath ["processor"] frame == Just (String processor)) frames
                      pure $
                        check "websocket-initial-snapshot" (maybe False (\frame -> lookupPath ["type"] frame == Just (String "snapshot")) initial)
                          <> check "websocket-ping-control" (maybe False (\frame -> lookupPath ["type"] frame == Just (String "pong")) pong)
                          <> check "broker-updates-not-finalized" (finalized == Just ())
                          <> check "retained-subscription-control" (updates "beta")
                          <> check "REV-9-F3" (not $ updates "alpha")
                  )
              ) ::
              IO (Maybe (Either SomeException [Text]))
          pure $ case session of
            Nothing -> ["websocket-session-timeout"]
            Just (Left err) -> ["websocket-session: " <> Text.pack (show err)]
            Just (Right checks) -> checks
        stopApp handle
        pure failures

receiveFrame :: WebSockets.Connection -> IO (Maybe LazyByteString.ByteString)
receiveFrame connection = timeout 2000000 (WebSockets.receiveData connection)

awaitFinalizedPair :: SyntheticBroker -> SyntheticBroker -> IO ()
awaitFinalizedPair alphaBroker betaBroker = do
  alpha <- brokerStats alphaBroker
  beta <- brokerStats betaBroker
  if alpha.finalizedOk >= 1 && beta.finalizedOk >= 1
    then pure ()
    else threadDelay 10000 >> awaitFinalizedPair alphaBroker betaBroker

data SlotClose = CleanClose | DropAfterSnapshot | DropBeforeSnapshot deriving (Eq, Show)

data IntentionalPeerDrop = IntentionalPeerDrop deriving (Eq, Show)

instance Exception IntentionalPeerDrop

websocketSlotFailures :: IO [Text]
websocketSlotFailures = do
  manager <- newManager defaultManagerSettings
  broker <- newSyntheticBroker defaultSyntheticConfig
  runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig [(ProcessorId "websocket-slots", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> do
        failures <- liftIO $ do
          let config = defaultConfig {wsMaxConnections = 8}
          batches <- traverse (\mode -> withServer manager config (getAppMaster handle) (\port -> slotBatch port mode)) [CleanClose, DropAfterSnapshot, DropBeforeSnapshot]
          pure $ nub $ concat batches
        stopApp handle
        pure failures

slotBatch :: Int -> SlotClose -> IO [Text]
slotBatch port mode = do
  control <- snapshotAccepted port
  if not control
    then pure ["websocket-slot-initial-control-" <> Text.pack (show mode)]
    else do
      churned <- churn (24 :: Int)
      if not churned
        then pure ["REV-9-F1"]
        else do
          threadDelay 50000
          final <- snapshotAccepted port
          pure $ check "REV-9-F1" final
  where
    churn 0 = pure True
    churn remaining = do
      closed <- closeOne port mode
      threadDelay 10000
      if closed then churn (remaining - 1) else pure False

snapshotAccepted :: Int -> IO Bool
snapshotAccepted port = do
  result <-
    timeout
      2000000
      ( try
          ( WebSockets.runClient "127.0.0.1" port "/ws" $ \connection -> do
              frame <- WebSockets.receiveData connection :: IO LazyByteString.ByteString
              pure $ lookupPath ["type"] frame == Just (String "snapshot")
          ) ::
          IO (Either SomeException Bool)
      )
  pure $ case result of
    Just (Right accepted) -> accepted
    _ -> False

closeOne :: Int -> SlotClose -> IO Bool
closeOne port mode = do
  entered <- newIORef False
  result <- timeout 2000000 $ try $ WebSockets.runClient "127.0.0.1" port "/ws" $ \connection -> do
    case mode of
      DropBeforeSnapshot -> pure ()
      _ -> do
        frame <- WebSockets.receiveData connection :: IO LazyByteString.ByteString
        when (lookupPath ["type"] frame /= Just (String "snapshot")) $ fail "missing initial snapshot"
    writeIORef entered True
    case mode of
      CleanClose -> WebSockets.sendClose connection ("done" :: Text)
      _ -> throwIO IntentionalPeerDrop
  didEnter <- readIORef entered
  pure $
    didEnter && case result of
      Just (Right ()) -> mode == CleanClose
      Just (Left err) -> mode /= CleanClose && fromException err == Just IntentionalPeerDrop
      Nothing -> False

sustainedLoadFailures :: IO [Text]
sustainedLoadFailures = do
  manager <- newManager defaultManagerSettings
  active <- sustainedProgress manager False
  blocked <- blockedControl manager
  pure $ active <> blocked

exceptionRecoveryFailures :: IO [Text]
exceptionRecoveryFailures = do
  manager <- newManager defaultManagerSettings
  sustainedProgress manager True

sustainedProgress :: Manager -> Bool -> IO [Text]
sustainedProgress manager injectFault = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  faultAvailable <- newIORef injectFault
  runEff $ runTracingNoop $ do
    let handler _ = do
          fault <- liftIO $ atomicModifyIORef' faultAvailable (\available -> (False, available))
          when fault $ liftIO $ throwIO $ userError "scripted transient handler exception"
          liftIO $ threadDelay 100000
          pure AckOk
        processor = (mkProcessor (syntheticAdapter broker) handler) {concurrency = Async 8}
    result <- runApp defaultAppConfig [(ProcessorId "sustained", processor)]
    case result of
      Left err -> pure ["app-start: " <> Text.pack (show err)]
      Right handle -> do
        checks <- liftIO $ withServer manager defaultConfig {stuckThreshold = 3} (getAppMaster handle) $ \port -> do
          mapM_ (\_ -> publish broker Nothing "work") [1 .. (1200 :: Int)]
          begun <- timeout 3000000 $ if injectFault then awaitRetried broker else awaitInFlight manager port
          threadDelay 4000000
          first <- activeSnapshot manager port
          threadDelay 3000000
          second <- activeSnapshot manager port
          threadDelay 3000000
          third <- activeSnapshot manager port
          stats <- brokerStats broker
          let samples = [first, second, third]
              metricSamples = map snd samples
              progress = map (lookupPath ["stats", "processed"] . (.body)) metricSamples
              inFlight = map (lookupPath ["state", "inFlight"] . (.body)) metricSamples
              readySample (ready, _) = ready.status == 200 && lookupPath ["ready"] ready.body == Just (Bool True) && lookupPath ["processors", "stuck"] ready.body == Just (Number 0)
              progressed = case progress of
                [Just (Number a), Just (Number b), Just (Number c)] -> a > 0 && a < b && b < c
                _ -> False
              activeThroughout = all (\case Just (Number n) -> n > 0; _ -> False) inFlight
              controls =
                check "sustained-load-not-started" (begun == Just ())
                  <> check "sustained-load-not-progressing" (progressed && stats.finalizedOk > 0)
                  <> if injectFault
                    then check "transient-exception-not-retried" (stats.retried == 1 && stats.finalizedOk < 1200)
                    else check "sustained-load-not-in-flight" activeThroughout
              failureKey = if injectFault then "transient-handler-error-sticks-failed-state" else "REV-7-F1"
          pure $ controls <> if null controls then check failureKey (all readySample samples) else []
        stopApp handle
        pure checks

activeSnapshot :: Manager -> Int -> IO (HttpResult, HttpResult)
activeSnapshot manager port = do
  ready <- fetch manager port "/health/ready"
  metrics <- fetch manager port "/metrics/sustained"
  pure (ready, metrics)

awaitInFlight :: Manager -> Int -> IO ()
awaitInFlight manager port = do
  metrics <- fetch manager port "/metrics/sustained"
  case lookupPath ["state", "inFlight"] metrics.body of
    Just (Number count) | count > 0 -> pure ()
    _ -> threadDelay 10000 >> awaitInFlight manager port

awaitRetried :: SyntheticBroker -> IO ()
awaitRetried broker = do
  stats <- brokerStats broker
  if stats.retried > 0 then pure () else threadDelay 10000 >> awaitRetried broker

blockedControl :: Manager -> IO [Text]
blockedControl manager = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  started <- newEmptyMVar
  release <- newEmptyMVar
  runEff $ runTracingNoop $ do
    let handler _ = do
          liftIO $ putMVar started ()
          liftIO $ takeMVar release
          pure AckOk
    result <- runApp defaultAppConfig [(ProcessorId "blocked-control", mkProcessor (syntheticAdapter broker) handler)]
    case result of
      Left err -> pure ["blocked-app-start: " <> Text.pack (show err)]
      Right handle -> do
        checks <- liftIO $ withServer manager defaultConfig {stuckThreshold = 3} (getAppMaster handle) $ \port ->
          ( do
              _ <- publish broker Nothing "blocked"
              began <- timeout 2000000 (takeMVar started)
              primed <- fetch manager port "/metrics/blocked-control"
              threadDelay 4000000
              ready <- fetch manager port "/health/ready"
              pure $
                check "blocked-handler-not-started" (began == Just ())
                  <> check "blocked-metrics-not-primed" (primed.status == 200 && lookupPath ["state", "inFlight"] primed.body == Just (Number 1))
                  <> check "blocked-control-not-stuck" (ready.status == 503 && lookupPath ["ready"] ready.body == Just (Bool False) && lookupPath ["processors", "stuck"] ready.body == Just (Number 1))
          )
            `finally` (tryPutMVar release () >> pure ())
        stopApp handle
        pure checks
