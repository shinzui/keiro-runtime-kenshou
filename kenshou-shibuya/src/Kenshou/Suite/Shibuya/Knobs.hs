module Kenshou.Suite.Shibuya.Knobs
  ( coreKnobs,
    PartitionMode (..),
    DecisionPattern (..),
    parseConcurrency,
    parseOrdering,
    parseStrategy,
    parsePartitions,
    parseDecisions,
    renderPartitions,
    renderDecisions,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), mkKnobName)
import Shibuya.App (SupervisionStrategy (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))

data PartitionMode = NoPartitions | UniformPartitions Int | HotKey Int | HighCardinality
  deriving stock (Eq, Show)

data DecisionPattern = AllOk | RetryEvery Int | DeadLetterEvery Int | ThrowEvery Int
  deriving stock (Eq, Show)

coreKnobs :: [KnobSpec]
coreKnobs =
  [ integer "shibuya.inbox-size" "Bounded inbox capacity per processor" 100 1 1000000,
    text "shibuya.concurrency" "serial, ahead:N, or async:N" "serial",
    text "shibuya.ordering" "strict-in-order, partitioned-in-order, or unordered" "unordered",
    text "shibuya.strategy" "ignore-failures or stop-all-on-failure" "ignore-failures",
    text "shibuya.processor-kind" "single or batch" "single",
    integer "shibuya.drain-timeout-seconds" "Drain deadline in seconds" 30 0 3600,
    integer "shibuya.messages" "Number of messages" 10000 1 10000000,
    integer "shibuya.handler-delay-micros" "Handler delay in microseconds" 0 0 100000000,
    text "shibuya.partitions" "none, uniform:N, hot-key:N, or high-cardinality" "none",
    text "shibuya.decisions" "all-ok, retry-every:N, dead-letter-every:N, or throw-every:N" "all-ok"
  ]
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)
    integer raw description def low high = KnobSpec (name raw) description KnobInt (VInt def) (IntRange low high) []
    text raw description def = KnobSpec (name raw) description KnobText (VText def) AnyValue []

parseConcurrency :: Text -> Either Text Concurrency
parseConcurrency "serial" = Right Serial
parseConcurrency value = case Text.splitOn ":" value of
  ["ahead", count] -> Ahead <$> parseCount count
  ["async", count] -> Async <$> parseCount count
  _ -> Left "expected serial, ahead:N, or async:N"
  where
    parseCount raw = case reads (Text.unpack raw) of
      [(count, "")] -> Right count
      _ -> Left "concurrency count must be an integer"

parseOrdering :: Text -> Either Text OrderingPolicy
parseOrdering "strict-in-order" = Right StrictInOrder
parseOrdering "partitioned-in-order" = Right PartitionedInOrder
parseOrdering "unordered" = Right Unordered
parseOrdering _ = Left "expected strict-in-order, partitioned-in-order, or unordered"

parseStrategy :: Text -> Either Text SupervisionStrategy
parseStrategy "ignore-failures" = Right IgnoreFailures
parseStrategy "stop-all-on-failure" = Right StopAllOnFailure
parseStrategy _ = Left "expected ignore-failures or stop-all-on-failure"

parsePartitions :: Text -> Either Text PartitionMode
parsePartitions "none" = Right NoPartitions
parsePartitions "high-cardinality" = Right HighCardinality
parsePartitions value = case Text.splitOn ":" value of
  ["uniform", count] -> UniformPartitions <$> positiveCount count
  ["hot-key", count] -> HotKey <$> positiveCount count
  _ -> Left "expected none, uniform:N, hot-key:N, or high-cardinality"

parseDecisions :: Text -> Either Text DecisionPattern
parseDecisions "all-ok" = Right AllOk
parseDecisions value = case Text.splitOn ":" value of
  ["retry-every", count] -> RetryEvery <$> positiveCount count
  ["dead-letter-every", count] -> DeadLetterEvery <$> positiveCount count
  ["throw-every", count] -> ThrowEvery <$> positiveCount count
  _ -> Left "expected all-ok, retry-every:N, dead-letter-every:N, or throw-every:N"

renderPartitions :: PartitionMode -> Text
renderPartitions NoPartitions = "none"
renderPartitions (UniformPartitions count) = "uniform:" <> Text.pack (show count)
renderPartitions (HotKey count) = "hot-key:" <> Text.pack (show count)
renderPartitions HighCardinality = "high-cardinality"

renderDecisions :: DecisionPattern -> Text
renderDecisions AllOk = "all-ok"
renderDecisions (RetryEvery count) = "retry-every:" <> Text.pack (show count)
renderDecisions (DeadLetterEvery count) = "dead-letter-every:" <> Text.pack (show count)
renderDecisions (ThrowEvery count) = "throw-every:" <> Text.pack (show count)

positiveCount :: Text -> Either Text Int
positiveCount raw = case reads (Text.unpack raw) of
  [(count, "")] | count > 0 -> Right count
  _ -> Left "count must be a positive integer"
