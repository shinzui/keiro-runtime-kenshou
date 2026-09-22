module Kenshou.Suite.Pgmq.Knobs
  ( PgmqKnobs (..),
    QueueKind (..),
    ReadStrategy (..),
    AckMode (..),
    commonKnobs,
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
    integer "pgmq.visibility-timeout-seconds" "Message lease duration" 30 0 86400 [1, 2, 10, 30],
    integer "pgmq.batch-size" "Messages per database call" 10 1 1000 [1, 10, 50, 100],
    integer "pgmq.pool-size" "Database pool size" 10 1 256 [3, 10, 20],
    integer "pgmq.pool.acquisition-timeout-seconds" "Pool acquisition timeout" 10 1 300 [],
    integer "pgmq.poll.max-seconds" "Long-poll duration; zero uses immediate reads" 0 0 300 [0, 2, 5],
    integer "pgmq.poll.interval-ms" "Long-poll interval" 100 1 60000 [50, 100, 1000],
    integer "pgmq.payload-bytes" "Approximate JSON payload bytes" 256 1 16777216 [256, 4096, 65536, 1048576],
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
    boolean "pgmq.fifo-index" "Create the optional FIFO index" False,
    boolean "pgmq.trace.propagate" "Propagate W3C trace context in message headers" False,
    enum "otel.semconv-stability-opt-in" "Semantic-convention stability opt-in" "unset" ["unset", "database", "messaging", "database/dup"]
  ]

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
