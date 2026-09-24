module Kenshou.Suite.Keiro.Inbox.Telemetry (runInboxSignals) where

import Data.Text (Text)
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..), InboxRow (..), InboxStatus (..), countInboxBacklog, listInbox, runInboxTransactionWith, sampleInboxBacklog)
import Keiro.Inbox.Kafka (integrationEventFromKafka)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Telemetry (withConsumerSpan)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..))
import Kenshou.Suite.Keiro.Inbox.Correctness (effectInsertStatement, effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Outbox.Broker (BrokerRecord (..), toInboundRecord)
import Kenshou.Telemetry (TelemetryHandles (..))
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import Kiroku.Store.Transaction (runTransaction)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)

runInboxSignals :: FixtureEnv -> TelemetryHandles -> BrokerRecord -> IO [(Text, Bool)]
runInboxSignals fixture telemetry brokerRecord = do
  let inbound = toInboundRecord brokerRecord.appendedAt brokerRecord
  (event, reference) <- either (fail . show) pure (integrationEventFromKafka inbound)
  ensureEffectTable fixture
  let KeiroRunner runFixture = fixture.runner
      handle delivered = Tx.statement delivered.messageId effectInsertStatement
      intake = withConsumerSpan telemetry.tracer (Just "kenshou-telemetry") inbound (Just event) \_ ->
        runFixture (runInboxTransactionWith fixture.telemetry.keiroMetrics PersistFullEnvelope PreferIntegrationMessageId event (Just reference) handle) >>= either (fail . show) pure
  first <- intake
  duplicate <- intake
  _ <- runFixture (sampleInboxBacklog fixture.telemetry.keiroMetrics) >>= either (fail . show) pure
  backlog <- runFixture countInboxBacklog >>= either (fail . show) pure
  rows <- runFixture (listInbox event.source) >>= either (fail . show) pure
  effects <- runFixture (runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
  _ <- telemetry.flushTelemetry
  spans <- maybe (pure []) readSpans telemetry.spans
  sums <- telemetry.readMetricSums
  gauges <- telemetry.readMetricGauges
  let metric name = sum [value | (key, value) <- sums, key == name]
      gauge name = [value | (key, value) <- gauges, key == name]
      consumerSpans = [spanValue | spanValue <- spans, spanValue.name == "process " <> brokerRecord.topic]
      hasText spanValue key value = lookupAttribute spanValue.attributes key == Just (AttributeValue (TextAttribute value))
      spanValid spanValue = show spanValue.kind == "Consumer" && hasText spanValue "messaging.system" "kafka" && hasText spanValue "messaging.operation.type" "process" && hasText spanValue "messaging.message.id" event.messageId
  pure
    [ ("inbox-durable-duplicate", first == Right (InboxProcessed ()) && duplicate == Right InboxDuplicate && case rows of [row] -> row.status == InboxCompleted && row.event.messageId == event.messageId; _ -> False),
      ("inbox-single-effect", effects == [event.messageId] && backlog == 0),
      ("consumer-spans", if maybe True (const False) telemetry.tracer then null consumerSpans else length consumerSpans == 2 && all spanValid consumerSpans),
      ("inbox-metrics", if telemetry.metricsLive then metric "keiro.inbox.processed" == 1 && metric "keiro.inbox.duplicates" == 1 && metric "keiro.inbox.failed" == 0 && gauge "keiro.inbox.backlog" == [fromIntegral backlog] else metric "keiro.inbox.processed" == 0 && null (gauge "keiro.inbox.backlog"))
    ]
