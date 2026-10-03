module Kenshou.Suite.Runtime.Oracle.Trace
  ( SpanIndex,
    indexSpans,
    sendSpanName,
    consumerSpanName,
    pickSpanName,
    judgeKafkaHop,
    judgeJobHop,
    judgeOutboxTrace,
    judgeJourneys,
    outboxTraceTx,
  )
where

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Suite.Runtime.Oracle (Judgement (..))
import Kenshou.Suite.Runtime.Telemetry (SpanRecord (..))

-- I7 judges spans that every role process exported to its own file. Span
-- identifiers are unique within a trace, so spans are indexed by both.

type SpanIndex = Map (Text, Text) SpanRecord

indexSpans :: [SpanRecord] -> SpanIndex
indexSpans spans = Map.fromList [((record.traceId, record.spanId), record) | record <- spans]

-- | The producer span kafka-effectful's traced producer opens per record.
sendSpanName :: Text -> Text
sendSpanName topic = "send " <> topic

-- | The consumer span shibuya opens per record, named after the processor.
consumerSpanName :: Text -> Text
consumerSpanName topic = topic <> "-consumer process"

-- | The consumer span shibuya opens per pick job, named after the job.
pickSpanName :: Text
pickSpanName = "pick process"

-- | A documented Kafka hop: every consumer span of the topic is a child of
-- that topic's @send@ span, exported by another process.
judgeKafkaHop :: Text -> SpanIndex -> [SpanRecord] -> Judgement
judgeKafkaHop topic index spans = foldMap judge [record | record <- spans, record.name == consumerSpanName topic]
  where
    judge record = case parentOf index record of
      Just parent
        | parent.name == sendSpanName topic && parent.process /= record.process -> Judgement 1 0 []
      parent -> Judgement 1 1 [object ["hop" .= ("kafka" :: Text), "topic" .= topic, "consumer" .= describe record, "parent" .= fmap describe parent, "parentSpanId" .= record.parentSpanId]]

-- | A documented PGMQ hop: every pick span continues the trace of the
-- workflow step that enqueued the job, whose span another process exported.
judgeJobHop :: SpanIndex -> [SpanRecord] -> Judgement
judgeJobHop index spans = foldMap judge [record | record <- spans, record.name == pickSpanName]
  where
    judge record = case parentOf index record of
      Just parent | parent.process /= record.process -> Judgement 1 0 []
      parent -> Judgement 1 1 [object ["hop" .= ("pgmq" :: Text), "consumer" .= describe record, "parent" .= fmap describe parent, "parentSpanId" .= record.parentSpanId]]

-- | Every outbox row of a context carries a @traceparent@.
judgeOutboxTrace :: Text -> (Int64, Int64, [Text]) -> Judgement
judgeOutboxTrace context (rows, missing, examples)
  | missing == 0 = Judgement rows 0 []
  | otherwise = Judgement rows missing [object ["context" .= context, "rowsWithoutTraceparent" .= missing, "rows" .= rows, "outboxIds" .= examples]]

-- | The implementation-class property: the command spans of an order's
-- stream and its fulfilment stream all belong to one trace.
judgeJourneys :: [Text] -> [SpanRecord] -> Judgement
judgeJourneys orders spans = foldMap judge orders
  where
    traces = Map.fromListWith (<>) [(record.name, [record.traceId]) | record <- spans]
    judge order =
      let orderTraces = Map.findWithDefault [] ("order-" <> order) traces
          fulfilmentTraces = Map.findWithDefault [] ("fulfilment-" <> order) traces
          distinct = nub (orderTraces <> fulfilmentTraces)
       in if not (null orderTraces) && not (null fulfilmentTraces) && length distinct == 1
            then Judgement 1 0 []
            else Judgement 1 1 [object ["orderId" .= order, "orderSpans" .= length orderTraces, "fulfilmentSpans" .= length fulfilmentTraces, "traces" .= distinct]]

parentOf :: SpanIndex -> SpanRecord -> Maybe SpanRecord
parentOf index record = record.parentSpanId >>= \parent -> Map.lookup (record.traceId, parent) index

describe :: SpanRecord -> Map Text Text
describe record = Map.fromList [("name", record.name), ("process", record.process), ("traceId", record.traceId), ("spanId", record.spanId)]

-- | Outbox rows, rows without a @traceparent@, and up to twenty of the latter.
outboxTraceTx :: Tx.Transaction (Int64, Int64, [Text])
outboxTraceTx = do
  (rows, missing) <-
    Tx.statement () $
      Statement.preparable
        "SELECT count(*), count(*) FILTER (WHERE traceparent IS NULL) FROM keiro.keiro_outbox"
        Encoders.noParams
        (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
  examples <-
    Tx.statement () $
      Statement.preparable
        "SELECT outbox_id::text FROM keiro.keiro_outbox WHERE traceparent IS NULL ORDER BY outbox_id LIMIT 20"
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
  pure (rows, missing, examples)
