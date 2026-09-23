module Kenshou.Suite.Kiroku.Correctness.Otel (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStoreWithCallbacks)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import Kiroku.Metrics (LifecycleCounters (..), MetricsSnapshot (..), metricsEventHandler, newKirokuMetricsWith, snapshotMetrics)
import Kiroku.Otel.Subscription (attrBatchRows, spanCatchup, spanDeliver, spanRetrying, subscriptionTraceHandler)
import Kiroku.Otel.TraceContext (extractTraceContext, injectTraceContext)
import Kiroku.Store hiding (id, withKirokuStore)
import OpenTelemetry.Attributes (lookupAttribute)
import OpenTelemetry.Trace.Core (SpanContext (..), SpanStatus (..), defaultSpanArguments, getSpanContext, inSpan')
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [spansAndTraceContext]

spansAndTraceContext :: Scenario
spansAndTraceContext =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/otel/correctness/spans-and-trace-context"),
      revision = 1,
      summary = "Checks subscription spans, error status, trace context propagation and composed metrics.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs <> telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingSdkInMemory :| []) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runOtel
    }

runOtel :: RunContext -> IO ScenarioReport
runOtel context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-configuration"] problem)
  Right spec -> withTelemetry spec \telemetry -> case (telemetry.tracer, telemetry.spans) of
    (Just tracer, Just probe) -> do
      traceHandler <- subscriptionTraceHandler tracer
      metrics <- newKirokuMetricsWith (pure (GlobalPosition 3)) (pure 0)
      producerContext <- newIORef Nothing
      let metricsOn = context.dimensions.metrics == Just MetricsCollect
          eventHandler = if metricsOn then metricsEventHandler metrics (Just traceHandler) else traceHandler
          enricher event = do
            current <- readIORef producerContext
            pure (maybe event (`injectTraceContext` event) current)
      withKirokuStoreWithCallbacks context (Just eventHandler) (Just enricher) \store -> do
        let name = SubscriptionName "otel-spans"
            stream = StreamName "otel-events"
            event = EventData Nothing (EventType "Traced") (object ["index" .= (1 :: Int)]) (Just (object ["source" .= ("producer" :: String)])) Nothing Nothing
        appended <- inSpan' tracer "kiroku.test.producer" defaultSpanArguments \producer -> do
          spanContext <- getSpanContext producer
          writeIORef producerContext (Just spanContext)
          result <- runStoreIO store (appendToStream stream NoStream (replicate 3 event))
          writeIORef producerContext Nothing
          pure (spanContext, result)
        attempts <- newIORef (0 :: Int)
        delivered <- newIORef []
        let handler row = do
              atomicModifyIORef' delivered (\values -> ((row.globalPosition, extractTraceContext row) : values, ()))
              if row.globalPosition == GlobalPosition 2
                then do
                  attempt <- atomicModifyIORef' attempts (\count -> let next = count + 1 in (next, next))
                  pure (if attempt == 1 then Retry (RetryDelay 0.01) else DeadLetter (DeadLetterPoison "otel-poison"))
                else pure Continue
            cfg = (defaultSubscriptionConfig name AllStreams handler) {retryPolicy = RetryPolicy 2}
            awaitCheckpoint = timeout 10000000 loop
            loop = do
              inventory <- runStoreIO store subscriptionCheckpointInventory
              case inventory of
                Right snapshot | [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [GlobalPosition 3] -> pure True
                _ -> threadDelay 10000 >> loop
        completed <- withSubscription store cfg \_ -> awaitCheckpoint
        _ <- telemetry.flushTelemetry
        spans <- readSpans probe
        observations <- reverse <$> readIORef delivered
        metricsSnapshot <- snapshotMetrics metrics
        let named wanted = filter ((== wanted) . (.name)) spans
            catchups = named spanCatchup
            delivers = named spanDeliver
            retries = named spanRetrying
            producer = named "kiroku.test.producer"
            contexts = mapMaybe snd observations
            (createdContext, appendResult) = appended
            cells =
              [ ("appended-three", case appendResult of Right result -> result.globalPosition == GlobalPosition 3; _ -> False),
                ("checkpoint-reached-head", completed == Just True),
                ("one-catchup-span", length catchups == 1),
                ("deliver-spans-carry-row-count", not (null delivers) && all (\spanValue -> lookupAttribute spanValue.attributes attrBatchRows /= Nothing) delivers),
                ("retry-span-ended-in-error", length retries == 1 && all (\spanValue -> case spanValue.status of Error _ -> True; _ -> False) retries),
                ("producer-span-retained", length producer == 1),
                ("trace-context-preserved", length observations == 4 && length contexts == 4 && all ((== createdContext.traceId) . (.traceId)) contexts),
                ("metrics-and-tracing-composed", not metricsOn || (metricsSnapshot.counters.subscriptionsStarted == 1 && metricsSnapshot.counters.subscriptionsDeadLettered == 1 && metricsSnapshot.counters.batchesDelivered == fromIntegral (length delivers)))
              ]
        recordCells context "spans-and-trace-context" [] cells
    _ -> pure (failedWith ["missing-tracer"] "sdk-inmemory did not provide a tracer and span probe")
