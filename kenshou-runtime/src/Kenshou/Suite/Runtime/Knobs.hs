module Kenshou.Suite.Runtime.Knobs
  ( runtimeKnobs,
    runtimeKnobsWith,
    runtimeKnobName,
    systemConfigFrom,
    partitionsFrom,
    quiescenceDeadlineFrom,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobDouble, knobInt, knobText, mkKnobName)
import Kenshou.Suite.Runtime.System.Config

runtimeKnobName :: Text -> KnobName
runtimeKnobName = either (error . Text.unpack) id . mkKnobName

-- | One knob per runtime parameter. Every scenario of the layer shares this
-- list; a scenario changes only defaults through 'runtimeKnobsWith'.
runtimeKnobs :: [KnobSpec]
runtimeKnobs =
  [ integer "runtime.processes-per-role" "Worker processes started for each long-running role." 2 1 8,
    integer "runtime.rate-per-second" "Open-loop order submissions per second across all drivers." 20 1 2000,
    choices "runtime.arrival" "Arrival process of the open-loop driver (poisson arrives with the benchmarks)." "constant" [],
    integer "runtime.orders" "Orders to submit; 0 means bounded by runtime.duration-seconds." 600 0 10000000,
    integer "runtime.duration-seconds" "Driver duration when runtime.orders is 0." 0 0 172800,
    decimal "runtime.refuse-fraction" "Fraction of orders for a discontinued SKU." 0.05 0 0.5,
    decimal "runtime.expire-fraction" "Fraction of orders whose pick never confirms." 0.02 0 0.5,
    integer "runtime.router-fanout" "Referrers credited by the loyalty router per completed order." 3 0 16,
    integer "runtime.cooling-off-ms" "Durable workflow sleep before a pick is requested." 200 0 600000,
    integer "runtime.fulfilment-deadline-seconds" "Deadline timer after which a fulfilment expires." 30 1 86400,
    integer "runtime.quiescence-deadline-seconds" "Time allowed after the driver stops for all work to finish." 120 1 86400,
    choices "runtime.inbox-idempotence" "Inbox idempotence mechanism of both Kafka consumers (delegated is not wired yet)." "table" [],
    choices "runtime.kafka-transient-policy" "Kafka consumer reaction to a transient database failure." "crash-only" ["ack-retry"],
    choices "runtime.publish-mode" "Outbox publisher wiring (batch-enqueue arrives with its known-defect scenario)." "sync-per-record" [],
    choices "runtime.ttl-profile" "Lease and timeout profile of every runtime component." "short" ["production"],
    integer "kiroku.pool-size" "Connection pool size of each role's event store." 4 2 32,
    integer "kafka.partitions" "Partitions of each run-scoped topic." 6 1 128,
    choices "outbox.ordering-policy" "Outbox publication ordering policy." "per-key-head-of-line" ["per-source-stream", "stop-the-line", "best-effort"],
    integer "outbox.batch-size" "Outbox rows claimed per publisher pass." 32 1 1000,
    choices "workflow.wake" "How the resume worker learns about runnable workflows." "push" ["poll"],
    integer "workflow.max-concurrent-advances" "Workflows one resume pass may advance concurrently." 4 1 32,
    integer "shard.count" "Shards of each context's dispatch subscription." 8 1 256,
    integer "queue.batch-size" "Pick jobs read per poll." 1 1 100
  ]
  where
    integer name summary value low high = KnobSpec (runtimeKnobName name) summary KnobInt (VInt value) (IntRange low high) []
    decimal name summary value low high = KnobSpec (runtimeKnobName name) summary KnobDouble (VDouble value) (DoubleRange low high) []
    choices name summary value others = KnobSpec (runtimeKnobName name) summary KnobText (VText value) (OneOf (VText value :| fmap VText others)) []

-- | Replace the defaults of named knobs, keeping their types and ranges.
runtimeKnobsWith :: [(Text, KnobValue)] -> [KnobSpec]
runtimeKnobsWith overrides = fmap override runtimeKnobs
  where
    override spec = maybe spec (\value -> spec {def = value}) (lookup spec.name [(runtimeKnobName name, value) | (name, value) <- overrides])

-- | Translate resolved knobs into the system description every role reads.
-- Connection strings and broker coordinates are filled in by the topology.
systemConfigFrom :: ResolvedKnobs -> SystemConfig
systemConfigFrom knobs =
  SystemConfig
    { shopDatabase = "",
      warehouseDatabase = "",
      brokers = [],
      topicPrefix = "",
      shopTopic = "",
      warehouseTopic = "",
      shopConsumerGroup = "",
      warehouseConsumerGroup = "",
      orders = int "runtime.orders",
      durationSeconds = int "runtime.duration-seconds",
      ratePerSecond = int "runtime.rate-per-second",
      refuseFraction = knobDouble knobs (runtimeKnobName "runtime.refuse-fraction"),
      expireFraction = knobDouble knobs (runtimeKnobName "runtime.expire-fraction"),
      routerFanout = int "runtime.router-fanout",
      coolingOffMillis = int "runtime.cooling-off-ms",
      fulfilmentDeadlineSeconds = int "runtime.fulfilment-deadline-seconds",
      ttlProfile = if text "runtime.ttl-profile" == "production" then ProductionTtl else ShortTtl,
      inboxMode = if text "runtime.inbox-idempotence" == "delegated" then InboxDelegated else InboxTable,
      transientPolicy = if text "runtime.kafka-transient-policy" == "ack-retry" then AckRetryPolicy else CrashOnly,
      publishMode = if text "runtime.publish-mode" == "batch-enqueue" then BatchEnqueue else SyncPerRecord,
      poolSize = int "kiroku.pool-size",
      shardCount = int "shard.count",
      outboxBatchSize = int "outbox.batch-size",
      wakeMode = if text "workflow.wake" == "poll" then WakePoll else WakePush,
      maxConcurrentAdvances = int "workflow.max-concurrent-advances",
      queueBatchSize = int "queue.batch-size",
      orderingPolicy = text "outbox.ordering-policy",
      processesPerRole = int "runtime.processes-per-role"
    }
  where
    int name = fromIntegral (knobInt knobs (runtimeKnobName name))
    text name = knobText knobs (runtimeKnobName name)

partitionsFrom :: ResolvedKnobs -> Int
partitionsFrom knobs = fromIntegral (knobInt knobs (runtimeKnobName "kafka.partitions"))

quiescenceDeadlineFrom :: ResolvedKnobs -> NominalDiffTime
quiescenceDeadlineFrom knobs = fromIntegral (knobInt knobs (runtimeKnobName "runtime.quiescence-deadline-seconds"))
