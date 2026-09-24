module Kenshou.Suite.Keiro.Outbox.Telemetry (scenarios) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), countOutboxBacklog, defaultPublishOptions, enqueueIntegrationEventTx, freshOutboxId, listOutbox, mkPublishRejection, publishClaimedOutbox, sampleOutboxBacklog)
import Keiro.Telemetry (traceContextFromCurrentSpan)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Inbox.Telemetry (runInboxSignals)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, inlineEvent, sourceName)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Trace.Core (defaultSpanArguments, inSpan')

scenarios :: [Scenario]
scenarios = [outboxSignals]

outboxSignals :: Scenario
outboxSignals =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/telemetry-contract"),
      revision = 1,
      summary = "Checks outbox producer spans and counters against durable publish states.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingSdkInMemory]) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsCollect),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runOutboxSignals
    }

runOutboxSignals :: RunContext -> IO ScenarioReport
runOutboxSignals context = case telemetrySpecFromContext context of
  Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
  Right spec -> withTelemetry spec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "telemetry"
      let enqueuePublished = do
            now <- getCurrentTime
            traceContext <- traceContextFromCurrentSpan
            outboxId <- runFixture freshOutboxId >>= either (fail . show) pure
            let event = (inlineEvent source "published" (Just "published") 1 now) {traceContext}
            _ <- runFixture (runTransaction (enqueueIntegrationEventTx outboxId event)) >>= either (fail . show) pure
            pure ()
      case telemetry.tracer of
        Nothing -> enqueuePublished
        Just activeTracer -> inSpan' activeTracer "telemetry-source" defaultSpanArguments (const enqueuePublished)
      enqueueInline fixture source [("rejected", Just "rejected", 2), ("retried", Just "retried", 3)]
      rejection <- either (fail . show) pure (mkPublishRejection "telemetry_rejection" Nothing)
      broker <- Broker.newBroker
      let model = Broker.BrokerModel 0 0 4
          hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
          decide row = case row.event.messageId of
            "published" -> Broker.Succeed
            "rejected" -> Broker.RejectWith rejection
            _ -> Broker.AlwaysFail
          publish = Broker.publishScripted broker model decide hooks "telemetry-publisher"
          options = defaultPublishOptions {batchSize = 3, tracer = runtimeTelemetry.keiroTracer}
      result <- runFixture (publishClaimedOutbox publish options runtimeTelemetry.keiroMetrics) >>= either (fail . show) pure
      brokerRecords <- Broker.readBroker broker
      inboxCells <- case brokerRecords of
        [record] -> runInboxSignals fixture telemetry record
        _ -> pure [("broker-record-for-inbox", False)]
      _ <- runFixture (sampleOutboxBacklog runtimeTelemetry.keiroMetrics) >>= either (fail . show) pure
      backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      _ <- telemetry.flushTelemetry
      spans <- maybe (pure []) readSpans telemetry.spans
      sums <- telemetry.readMetricSums
      gauges <- telemetry.readMetricGauges
      let statuses = Map.fromList [(row.event.messageId, row.status) | row <- rows]
          producerSpans = [spanValue | spanValue <- spans, spanValue.name == "send kenshou.outbox.v1"]
          rootSpans = [spanValue | spanValue <- spans, spanValue.name == "telemetry-source"]
          consumerSpans = [spanValue | spanValue <- spans, spanValue.name == "process kenshou.outbox.v1"]
          metric name = sum [value | (key, value) <- sums, key == name]
          gauge name = [value | (key, value) <- gauges, key == name]
          hasText spanValue key value = lookupAttribute spanValue.attributes key == Just (AttributeValue (TextAttribute value))
          hasInt spanValue key value = lookupAttribute spanValue.attributes key == Just (AttributeValue (IntAttribute value))
          spanValid spanValue =
            spanValue.name == "send kenshou.outbox.v1"
              && show spanValue.kind == "Producer"
              && hasText spanValue "messaging.system" "kafka"
              && hasText spanValue "messaging.operation.type" "publish"
              && hasText spanValue "messaging.destination.name" "kenshou.outbox.v1"
              && hasInt spanValue "keiro.outbox.batch.size" 3
              && hasText spanValue "error.type" "publish_failed"
          cells =
            [ ("durable-publish-outcomes", result.claimed == 3 && result.published == 1 && result.rejected == 1 && result.retried == 1 && result.dead == 0 && statuses == Map.fromList [("published", OutboxSent), ("rejected", OutboxRejected), ("retried", OutboxFailed)] && backlog == 1),
              ("producer-span", if maybe True (const False) telemetry.tracer then null producerSpans else case producerSpans of [spanValue] -> spanValid spanValue; _ -> False),
              ("persisted-trace-parent", if maybe True (const False) telemetry.tracer then null rootSpans && null consumerSpans else case rootSpans of [root] -> length consumerSpans == 2 && all (\child -> child.traceId == root.traceId && child.parentSpanId == Just root.spanId) consumerSpans; _ -> False),
              ("outbox-metrics", if telemetry.metricsLive then metric "keiro.outbox.published" == 1 && metric "keiro.outbox.rejected" == 1 && metric "keiro.outbox.retried" == 1 && metric "keiro.outbox.deadlettered" == 0 && gauge "keiro.outbox.backlog" == [fromIntegral backlog] else null sums && null gauges)
            ]
      putSummary context Measurements "outbox-telemetry" (object ["publishSummary" .= object ["claimed" .= result.claimed, "published" .= result.published, "rejected" .= result.rejected, "retried" .= result.retried], "backlog" .= backlog, "spanCount" .= length spans, "metricSums" .= sums, "metricGauges" .= gauges])
      recordCells context (cells <> inboxCells)
