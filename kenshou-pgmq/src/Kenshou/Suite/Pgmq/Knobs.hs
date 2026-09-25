module Kenshou.Suite.Pgmq.Knobs
  ( PgmqKnobs (..),
    QueueKind (..),
    ReadStrategy (..),
    AckMode (..),
    commonKnobs,
    soakKnobs,
    resolveKnobs,
    knobName,
  )
where

import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob hiding (resolveKnobs)

data QueueKind = Standard | Unlogged | Partitioned deriving stock (Eq, Ord, Show)

data ReadStrategy = Plain | Pop | Grouped | GroupedRoundRobin | GroupedHead deriving stock (Eq, Ord, Show)

data AckMode = AckDelete | AckArchive | AckBatchDelete | AckBatchArchive deriving stock (Eq, Ord, Show)

data PgmqKnobs = PgmqKnobs
  { queueKind :: QueueKind,
    visibilityTimeoutSeconds :: Int32,
    batchSize :: Int32,
    poolSize :: Int,
    acquisitionTimeoutSeconds :: Int,
    tcpUserTimeoutMs :: Int,
    pollMaxSeconds :: Int32,
    pollIntervalMs :: Int32,
    payloadBytes :: Int,
    readStrategy :: ReadStrategy,
    ackMode :: AckMode
  }
  deriving stock (Eq, Show)

commonKnobs :: [KnobSpec]
commonKnobs =
  [ enum "pgmq.queue-kind" "Queue storage kind" "standard" ["standard", "unlogged", "partitioned"],
    text "pgmq.partition.interval" "Partition interval passed to pgmq" "10000",
    text "pgmq.partition.retention" "Partition retention passed to pgmq" "100000",
    integer "pgmq.visibility-timeout-seconds" "Message lease duration" 30 0 86400 [1, 2, 10, 30],
    integer "pgmq.batch-size" "Messages per database call" 10 1 1000 [1, 10, 50, 100],
    integer "pgmq.pool-size" "Database pool size" 10 1 256 [3, 10, 20],
    integer "pgmq.pool.acquisition-timeout-seconds" "Pool acquisition timeout" 10 1 300 [],
    integer "pgmq.poll.max-seconds" "Long-poll duration; zero uses immediate reads" 0 0 300 [0, 2, 5],
    integer "pgmq.poll.interval-ms" "Long-poll interval" 100 1 60000 [50, 100, 1000],
    integer "pgmq.payload-bytes" "Approximate JSON payload bytes" 256 1 16777216 [256, 4096, 65536, 1048576],
    text "pgmq.payload-bytes-list" "Comma-separated correctness payload sizes" "1024,65536,1048576,16777216",
    enum "pgmq.read-strategy" "PGMQ read function family" "plain" ["plain", "pop", "grouped", "grouped-round-robin", "grouped-head"],
    enum "pgmq.ack-mode" "Acknowledgement function" "delete" ["delete", "archive", "batch-delete", "batch-archive"],
    integer "pgmq.message-count" "Messages in the workload" 100 1 10000000 [20, 1000, 100000],
    integer "pgmq.producers" "Concurrent producers" 1 1 256 [1, 4, 16],
    integer "pgmq.consumers" "Concurrent consumers" 1 1 256 [1, 4, 16],
    integer "pgmq.processes" "Worker processes" 4 1 64 [1, 4, 8],
    integer "pgmq.groups" "FIFO groups" 5 1 100000 [5, 50, 1000],
    integer "pgmq.handler-ms" "Simulated handler latency" 0 0 600000 [0, 5, 100],
    integer "pgmq.rate-per-second" "Open-loop arrival rate" 1000 1 1000000 [100, 1000, 5000],
    integer "pgmq.duration-seconds" "Workload duration" 60 1 86400 [60, 1200, 14400],
    integer "pgmq.notify.throttle-ms" "Insert-notification throttle" 250 0 60000 [0, 250, 1000],
    integer "pgmq.delay-window-seconds" "Scheduled-message delay window" 60 1 3600 [1, 10, 60],
    integer "pgmq.kills" "Worker SIGKILL count" 5 0 100 [1, 3, 5],
    integer "pgmq.kill-interval-seconds" "Seconds between worker kills" 5 1 600 [1, 5],
    integer "pgmq.pollers" "Concurrent long pollers" 4 1 256 [3, 4, 8],
    enum "pgmq.sabotage" "Deliberate oracle sabotage" "none" ["none", "unlocked-read"],
    integer "pgmq.fault.interval-seconds" "Seconds between injected faults" 10 1 3600 [1, 10],
    integer "pgmq.fault.latency-ms" "Injected network latency" 200 0 60000 [0, 200, 1000],
    integer "pgmq.fault.max-block-seconds" "Maximum permitted network block" 30 1 600 [5, 30],
    integer "pgmq.conn.tcp-user-timeout-ms" "libpq tcp_user_timeout value" 0 0 600000 [0, 5000, 30000],
    enum "pgmq.fault.kind" "Fault mode" "reset" ["reset", "latency", "blackhole", "stop-start", "immediate-crash"],
    integer "pgmq.poll.fallback-seconds" "Notification listener poll fallback" 2 1 600 [1, 2, 5],
    integer "pgmq.queue-depth" "Standing queue depth" 100000 1 10000000 [100000, 1000000],
    integer "pgmq.invisible-backlog" "Invisible rows ahead of a visible tail" 0 0 10000000 [0, 10000, 100000, 1000000],
    enum "pgmq.layer" "Client layer" "effectful" ["raw-sql", "hasql", "effectful"],
    enum "pgmq.op" "Benchmark operation" "full-cycle" ["send", "send-batch", "read", "delete", "pop", "full-cycle"],
    enum "pgmq.arrival" "Open-loop arrival process" "constant" ["constant", "poisson"],
    enum "pgmq.wake" "Consumer wake-up strategy" "poll" ["poll", "long-poll", "notify"],
    enum "pgmq.notify.mode" "Insert notification mode" "off" ["off", "throttled", "unthrottled"],
    enum "pgmq.comparison-label" "Behaviour-neutral A/A comparison label" "a" ["a", "b"],
    double "pgmq.soak.nack-fraction" "Fraction of deliveries deliberately not acknowledged" 0.01 0 1,
    boolean "pgmq.soak.archive-purge" "Purge archive rows older than five minutes" False,
    boolean "pgmq.fifo-index" "Create the optional FIFO index" False,
    boolean "pgmq.trace.propagate" "Propagate W3C trace context in message headers" False,
    enum "otel.semconv-stability-opt-in" "Semantic-convention stability opt-in" "unset" ["unset", "database", "messaging", "database/dup"]
  ]

soakKnobs :: [KnobSpec]
soakKnobs =
  [integer "pgmq.soak.major-gc-interval-ms" "Post-major-GC heap sample interval; zero disables forced collections" 30000 0 60000 [0, 30000]]

resolveKnobs :: RunContext -> Either Text PgmqKnobs
resolveKnobs context = do
  queueKind <- parseQueueKind (knobText context.knobs (knobName "pgmq.queue-kind"))
  readStrategy <- parseReadStrategy (knobText context.knobs (knobName "pgmq.read-strategy"))
  ackMode <- parseAckMode (knobText context.knobs (knobName "pgmq.ack-mode"))
  let pollMaxSeconds = int32 "pgmq.poll.max-seconds"
  if readStrategy == Pop && pollMaxSeconds > 0
    then Left "pgmq.read-strategy=pop cannot be combined with long polling"
    else
      Right
        PgmqKnobs
          { queueKind,
            visibilityTimeoutSeconds = int32 "pgmq.visibility-timeout-seconds",
            batchSize = int32 "pgmq.batch-size",
            poolSize = fromIntegral (knobInt context.knobs (knobName "pgmq.pool-size")),
            acquisitionTimeoutSeconds = fromIntegral (knobInt context.knobs (knobName "pgmq.pool.acquisition-timeout-seconds")),
            tcpUserTimeoutMs = fromIntegral (knobInt context.knobs (knobName "pgmq.conn.tcp-user-timeout-ms")),
            pollMaxSeconds,
            pollIntervalMs = int32 "pgmq.poll.interval-ms",
            payloadBytes = fromIntegral (knobInt context.knobs (knobName "pgmq.payload-bytes")),
            readStrategy,
            ackMode
          }
  where
    int32 name = fromIntegral (knobInt context.knobs (knobName name))

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

integer :: Text -> Text -> Integer -> Integer -> Integer -> [Integer] -> KnobSpec
integer name summary def low high variants =
  KnobSpec (knobName name) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) (fmap (VInt . fromIntegral) variants)

enum :: Text -> Text -> Text -> [Text] -> KnobSpec
enum name summary def values =
  KnobSpec (knobName name) summary KnobText (VText def) (OneOf (case fmap VText values of first : rest -> first :| rest; [] -> error "enum requires values")) []

boolean :: Text -> Text -> Bool -> KnobSpec
boolean name summary def = KnobSpec (knobName name) summary KnobBool (VBool def) (OneOf (VBool False :| [VBool True])) []

text :: Text -> Text -> Text -> KnobSpec
text name summary def = KnobSpec (knobName name) summary KnobText (VText def) AnyValue []

double :: Text -> Text -> Double -> Double -> Double -> KnobSpec
double name summary def low high = KnobSpec (knobName name) summary KnobDouble (VDouble def) (DoubleRange low high) []

parseQueueKind :: Text -> Either Text QueueKind
parseQueueKind = \case
  "standard" -> Right Standard
  "unlogged" -> Right Unlogged
  "partitioned" -> Right Partitioned
  value -> Left ("unknown queue kind: " <> value)

parseReadStrategy :: Text -> Either Text ReadStrategy
parseReadStrategy = \case
  "plain" -> Right Plain
  "pop" -> Right Pop
  "grouped" -> Right Grouped
  "grouped-round-robin" -> Right GroupedRoundRobin
  "grouped-head" -> Right GroupedHead
  value -> Left ("unknown read strategy: " <> value)

parseAckMode :: Text -> Either Text AckMode
parseAckMode = \case
  "delete" -> Right AckDelete
  "archive" -> Right AckArchive
  "batch-delete" -> Right AckBatchDelete
  "batch-archive" -> Right AckBatchArchive
  value -> Left ("unknown acknowledgement mode: " <> value)
