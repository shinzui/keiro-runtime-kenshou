module Kenshou.Suite.Kiroku.Bench.Telemetry (scenarios) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeAsyncException, SomeException, bracket, fromException, throwIO, try)
import Control.Monad (forM, forever, replicateM, void)
import Data.Aeson (decode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStoreWithCallbacks)
import Kenshou.Suite.Kiroku.Fixture.Telemetry (composeEventHandler)
import Kenshou.Suite.Kiroku.Fixture.Workload (payloadOf)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Endpoint (Endpoint (..), EndpointKind (..))
import Kiroku.Metrics (MetricsServer (..), MetricsServerConfig (..), defaultConfig, newKirokuMetricsWith, withMetricsServerWithStore)
import Kiroku.Otel.TraceContext (injectTraceContext)
import Kiroku.Store hiding (id, withKirokuStore)
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Network.WebSockets qualified as WebSocket
import OpenTelemetry.Trace.Core (defaultSpanArguments, getSpanContext, inSpan')
import System.Info (os)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [eventHandlerArms, serverArms]

serverArms :: Scenario
serverArms =
  eventHandlerArms
    { id = either (error . show) id (parseScenarioId "kiroku/metrics/benchmark/server-arms"),
      summary = "Measures collection, HTTP serving, scraping, and optional WebSocket tails.",
      knobs = eventHandlerArms.knobs <> [KnobSpec (name "kiroku.metrics.websocket-tails") "Concurrent WebSocket event tails" KnobInt (VInt 0) (OneOf (VInt 0 :| [VInt 1, VInt 8])) []],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsCollect :| [MetricsServe, MetricsServeScraped]) MetricsCollect),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      run = runTelemetryBenchmark True
    }
  where
    name = either (error . show) id . mkKnobName

eventHandlerArms :: Scenario
eventHandlerArms =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/otel/benchmark/event-handler-arms"),
      revision = 1,
      summary = "Measures append throughput with four subscribers under Kiroku metrics and tracing handler arms.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> telemetryKnobs <> loadKnobs (defaultLoadDefaults {workers = 32}) <> measureKnobs Benchmark <> [intKnob "kiroku.append.writers" 32 1 128, intKnob "kiroku.append.payload-bytes" 256 64 65536, boolKnob "kiroku.trace.enrich-event" False],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = PhasePlan 30 120 15,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runTelemetryBenchmark False
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value low high = KnobSpec (name key) key KnobInt (VInt value) (IntRange low high) []
    boolKnob key value = KnobSpec (name key) key KnobBool (VBool value) (OneOf (VBool False :| [VBool True])) []

runTelemetryBenchmark :: Bool -> RunContext -> IO ScenarioReport
runTelemetryBenchmark serverArmed context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases), telemetrySpecFromContext context) of
  (Left reason, _, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, _, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right loadModel, Right measureConfig, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry -> do
    let name = either (error . show) id . mkKnobName
        writers = fromIntegral (knobInt context.knobs (name "kiroku.append.writers")) :: Int
        payloadBytes = fromIntegral (knobInt context.knobs (name "kiroku.append.payload-bytes")) :: Int
        enrich = knobBool context.knobs (name "kiroku.trace.enrich-event")
        tails = if serverArmed then fromIntegral (knobInt context.knobs (name "kiroku.metrics.websocket-tails")) else 0
        metricsOn = context.dimensions.metrics /= Just MetricsOff
        configuredModel = case loadModel of ClosedLoop closed -> ClosedLoop (closed {workers = writers}); other -> other
    storeVar <- newTVarIO Nothing
    metrics <- if metricsOn then Just <$> newKirokuMetricsWith (readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))) (pure 0) else pure Nothing
    eventHandler <- composeEventHandler metrics telemetry.tracer Nothing
    withKirokuStoreWithCallbacks context eventHandler Nothing \store -> do
      atomically (writeTVar storeVar (Just store))
      counters <- forM [0 :: Int .. 3] \_ -> newIORef (0 :: Int)
      let subscriber index = defaultSubscriptionConfig (SubscriptionName ("handler-arms-" <> Text.pack (show index))) AllStreams (\_ -> atomicModifyIORef' (counters !! index) (\count -> (count + 1, ())) >> pure Continue)
          withSubscribers [] action = action
          withSubscribers (index : rest) action = withSubscription store (subscriber index) (\_ -> withSubscribers rest action)
          awaitCount wanted = do
            counts <- traverse readIORef counters
            if all (>= wanted) counts then pure counts else threadDelay 10000 >> awaitCount wanted
          operation worker sequenceNumber = do
            let event = EventData Nothing (EventType "HandlerArms") (payloadOf context.seed worker (fromIntegral sequenceNumber) payloadBytes) Nothing Nothing Nothing
                stream = StreamName ("handler-arms-" <> Text.pack (show (worker `mod` writers)))
                append value = runStoreIO store (appendToStream stream AnyVersion [value])
            result <- try @SomeException $ case (enrich, telemetry.tracer) of
              (True, Just tracer) -> inSpan' tracer "kiroku.bench.producer" defaultSpanArguments \spanValue -> do
                spanContext <- getSpanContext spanValue
                append (injectTraceContext spanContext event)
              _ -> append event
            case result of
              Right (Right _) -> pure (OpOk 1)
              Right (Left err) -> pure (OpFailed (ErrorCause (Text.pack (show err))))
              Left err | Just (_ :: SomeAsyncException) <- fromException err -> throwIO err
              Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
      walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
      let withServer action = case (serverArmed, metrics, context.dimensions.metrics) of
            (True, Just collector, Just arm) | arm == MetricsServe || arm == MetricsServeScraped ->
              withMetricsServerWithStore (defaultConfig {port = 0}) collector store [] \server -> do
                let base = "http://127.0.0.1:" <> show server.serverPort
                telemetry.registerEndpoint (Endpoint "kiroku-json" JsonDocument (Text.pack (base <> "/metrics")) Nothing)
                telemetry.registerEndpoint (Endpoint "kiroku-prometheus" PrometheusText (Text.pack (base <> "/metrics/prometheus")) Nothing)
                withTails tails server.serverPort action
            _ -> action
      withServer $ withSubscribers [0 .. 3] do
        (_, report) <- withMeasurement context measureConfig \measurement -> runLoad measurement configuredModel (Operation (OpName "append") operation)
        let completed = sum [load.completed | load <- report.loads]
            failures = sum [load.failed | load <- report.loads]
        durableCounts@(durable, _, _) <- Oracle.threeCounts store.pool
        delivered <- timeout 60000000 (awaitCount (fromIntegral durable))
        let counts = maybe [] id delivered
            ambiguous = durable - fromIntegral completed
            coverage = durable > 0 && durableCounts == (durable, durable, durable) && counts == replicate 4 (fromIntegral durable)
            base
              | not coverage || failures > 0 || ambiguous < 0 = failedWith ["event-handler-delivery"] ("completed=" <> Text.pack (show completed) <> ", failures=" <> Text.pack (show failures) <> ", durable=" <> Text.pack (show durableCounts) <> ", subscriber-counts=" <> Text.pack (show counts))
              | ambiguous > 0 = inconclusiveBecause ("drain ended with " <> Text.pack (show ambiguous) <> " committed append(s) whose operation did not return")
              | otherwise = passed
            walMethod = either (const Nothing) Just walSync
            reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
        putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "writers" .= writers, "payloadBytes" .= payloadBytes, "enrichEvent" .= enrich, "subscriberCount" .= (4 :: Int), "websocketTails" .= tails, "trialsRequired" .= (3 :: Int)])
        putSummary context Verdicts (if serverArmed then "server-arms" else "event-handler-arms") (object ["completed" .= completed, "failed" .= failures, "durableCounts" .= durableCounts, "ambiguousCompletions" .= ambiguous, "subscriberCounts" .= counts])
        pure (if base.outcome == Passed then base {outcome = measuredOutcome report base.outcome} else base)

withTails :: Int -> Int -> IO result -> IO result
withTails count port action
  | count == 0 = action
  | otherwise = bracket acquire (mapM_ killThread . fst) \(_, tails) -> do
      ready <- timeout 5000000 (traverse (takeMVar . fst) tails)
      case ready of
        Just results | all (== Right ()) results -> pure ()
        _ -> fail "WebSocket event tails did not start"
      result <- action
      delivered <- traverse (readIORef . snd) tails
      if all (> 0) delivered then pure result else fail "WebSocket event tail received no events"
  where
    acquire = do
      tails <- replicateM count ((,) <$> newEmptyMVar <*> newIORef (0 :: Int))
      threads <- forM tails \(gate, delivered) -> forkIO do
        result <- try @SomeException (tailLoop gate delivered)
        case result of
          Left err -> void (tryPutMVar gate (Left (show err)))
          Right () -> pure ()
      pure (threads, tails)
    tailLoop gate delivered = WebSocket.runClient "127.0.0.1" port "/ws/events" \connection -> do
      WebSocket.sendTextData connection (encode (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int)]))
      first <- WebSocket.receiveData connection :: IO LazyByteString.ByteString
      let frameType raw = decode raw >>= parseMaybe (withObject "WebSocket frame" (.: "type")) :: Maybe Text
      if frameType first == Just "event_stream_started"
        then void (tryPutMVar gate (Right ()))
        else fail "WebSocket tail did not receive event_stream_started"
      forever do
        frame <- WebSocket.receiveData connection :: IO LazyByteString.ByteString
        if frameType frame == Just "event"
          then atomicModifyIORef' delivered (\countValue -> (countValue + 1, ()))
          else pure ()

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
