module Kenshou.Suite.Runtime.Oracle.Ops
  ( -- * The compared commands
    OpsCheck (..),
    opsChecks,

    -- * Pure extraction and judgement
    extractCount,
    extractWorkflows,
    extractTimers,
    extractShardStatus,
    extractCheckpoints,
    extractDlqEntries,
    parseDlqMessageId,
    dlqShapeProblems,
    judgeOpsAgreement,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (sort, (\\))
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Suite.Runtime.Oracle (Judgement (..))
import Kenshou.Suite.Runtime.System.Schema (ContextName (..))

-- I8 compares what @keiro-ops --json@ reports with what the same database
-- holds. Each side is reduced to a multiset of normalised text facts, so a
-- comparison is an equality of sorted lists and a disagreement names the
-- facts that only one side reported.

-- | One operator command and the SQL that states the same facts.
data OpsCheck = OpsCheck
  { name :: !Text,
    context :: !ContextName,
    arguments :: ![Text],
    extract :: Value -> Either Text [Text],
    facts :: Tx.Transaction [Text]
  }

-- | The commands of invariant I8, for both contexts where the component
-- exists in both. Workflows, timers and the pick queue exist only in the
-- warehouse, but the workflow and timer commands also run against the shop,
-- where both sides must report nothing.
opsChecks :: [OpsCheck]
opsChecks =
  concat
    [ [ OpsCheck "outbox-backlog" context ["outbox", "backlog"] extractCount (countFact "SELECT count(*) FROM keiro.keiro_outbox WHERE status IN ('pending', 'failed')"),
        OpsCheck "inbox-backlog" context ["inbox", "backlog"] extractCount (countFact "SELECT count(*) FROM keiro.keiro_inbox WHERE status IN ('processing', 'failed')"),
        OpsCheck
          "workflows-unfinished"
          context
          ["wf", "list", "--status", "running", "--status", "suspended", "--status", "failed", "--limit", "100000"]
          extractWorkflows
          (textFacts "SELECT workflow_name || '/' || workflow_id || '/' || status FROM keiro.keiro_workflows WHERE status IN ('running', 'suspended', 'failed')"),
        OpsCheck "timers-stuck" context ["timer", "stuck", "list"] extractTimers (textFacts "SELECT timer_id::text FROM keiro.keiro_timers WHERE status = 'firing'"),
        OpsCheck
          "shard-status"
          context
          ["shard", "status", "--subscription", subscription]
          extractShardStatus
          ( textFacts
              ( "SELECT 'bucket/' || bucket || '/' || coalesce(owner_worker_id::text, 'unowned') FROM keiro.keiro_subscription_shards WHERE subscription_name = '"
                  <> subscription
                  <> "' UNION ALL SELECT 'shards/' || shard_count || '/' || count(*) FROM keiro.keiro_subscription_shards WHERE subscription_name = '"
                  <> subscription
                  <> "' GROUP BY shard_count"
              )
          ),
        OpsCheck
          "subscription-checkpoints"
          context
          ["stream", "subscriptions"]
          extractCheckpoints
          ( textFacts
              "SELECT 'checkpoint/' || subscription_name || '/' || consumer_group_member || '/' || last_seen FROM kiroku.subscriptions UNION ALL SELECT 'store/' || stream_version FROM kiroku.streams WHERE stream_id = 0"
          )
      ]
    | (context, subscription) <- [(Shop, "shop-dispatch"), (Warehouse, "warehouse-dispatch")]
    ]
    <> [ OpsCheck
           "pick-dead-letters"
           Warehouse
           ["pgmq", "dlq", "read", "--queue", "pick", "--limit", "1000"]
           extractDlqEntries
           (textFacts "SELECT msg_id::text FROM pgmq.q_pick_dlq")
       ]

-- | @outbox backlog@ and @inbox backlog@ report @{"metric": ..., "count": n}@.
extractCount :: Value -> Either Text [Text]
extractCount value = do
  count <- field "count" value >>= integer
  pure [textShow count]

-- | @wf list@ reports an array of instances.
extractWorkflows :: Value -> Either Text [Text]
extractWorkflows value = do
  rows <- array value
  traverse (\row -> (\n i s -> n <> "/" <> i <> "/" <> s) <$> (field "workflow_name" row >>= text) <*> (field "workflow_id" row >>= text) <*> (field "status" row >>= text)) rows

-- | @timer stuck list@ reports an array of timers.
extractTimers :: Value -> Either Text [Text]
extractTimers value = array value >>= traverse (\row -> field "timer_id" row >>= text)

-- | @shard status@ reports each bucket's owner and the shard-count groups.
extractShardStatus :: Value -> Either Text [Text]
extractShardStatus value = do
  ownership <- field "ownership" value >>= array
  counts <- field "shard_counts" value >>= array
  owners <-
    traverse
      ( \row -> do
          bucket <- field "bucket" row >>= integer
          owner <- field "owner" row >>= nullableText
          pure ("bucket/" <> textShow bucket <> "/" <> maybe "unowned" id owner)
      )
      ownership
  groups <-
    traverse
      ( \row -> do
          shards <- field "shard_count" row >>= integer
          rows <- field "rows" row >>= integer
          pure ("shards/" <> textShow shards <> "/" <> textShow rows)
      )
      counts
  pure (owners <> groups)

-- | @stream subscriptions@ reports every durable checkpoint and the store
-- position captured with them.
extractCheckpoints :: Value -> Either Text [Text]
extractCheckpoints value = do
  store <- field "store_position" value >>= integer
  checkpoints <- field "checkpoints" value >>= array
  rows <-
    traverse
      ( \row -> do
          name <- field "subscription" row >>= text
          member <- field "member" row >>= integer
          position <- field "checkpoint_position" row >>= integer
          pure ("checkpoint/" <> name <> "/" <> textShow member <> "/" <> textShow position)
      )
      checkpoints
  pure (("store/" <> textShow store) : rows)

-- | @pgmq dlq read@ reports an array of entries; their message identifiers
-- are read through 'parseDlqMessageId'.
extractDlqEntries :: Value -> Either Text [Text]
extractDlqEntries value = array value >>= traverse (\row -> field "dlq_message_id" row >>= parseDlqMessageId)

-- | A DLQ message identifier as keiro-ops renders it. keiro-ops 0.17.0.0
-- renders it with the derived 'Show' of pgmq-core's record newtype, so the
-- JSON carries @"MessageId {unMessageId = 7}"@; a number or a digit string is
-- accepted as well. The shape itself is judged by 'dlqShapeProblems'.
parseDlqMessageId :: Value -> Either Text Text
parseDlqMessageId = \case
  Number n -> either (const (Left "non-integral DLQ message id")) (Right . textShow) (floatingOrInteger n :: Either Double Int64)
  String raw
    | not (Text.null raw) && Text.all isDigit raw -> Right raw
    | Just inner <- Text.stripPrefix "MessageId {unMessageId = " raw >>= Text.stripSuffix "}",
      not (Text.null inner) && Text.all isDigit inner ->
        Right inner
    | otherwise -> Left ("unrecognised DLQ message id " <> raw)
  other -> Left ("unrecognised DLQ message id " <> textShow other)

-- | DLQ identifiers that are not machine-shaped (a JSON number or a digit
-- string). An automation client cannot use the derived 'Show' rendering
-- without knowing the Haskell type behind it.
dlqShapeProblems :: Value -> [Value]
dlqShapeProblems value = case value of
  Array rows -> [identifier | row <- toList rows, Right identifier <- [field "dlq_message_id" row], not (machineShaped identifier)]
  _ -> []
  where
    machineShaped = \case
      Number _ -> True
      String raw -> not (Text.null raw) && Text.all isDigit raw
      _ -> False

-- | I8 for one command: both sides report the same multiset of facts. An
-- operator command that failed or printed something unparseable is a
-- violation in its own right.
judgeOpsAgreement :: Text -> ContextName -> Either Text [Text] -> [Text] -> Judgement
judgeOpsAgreement check context reported stored = case reported of
  Left problem -> Judgement 1 1 [object ["check" .= check, "context" .= contextText, "problem" .= problem]]
  Right facts
    | sort facts == sort stored -> Judgement 1 0 []
    | otherwise ->
        Judgement
          1
          1
          [ object
              [ "check" .= check,
                "context" .= contextText,
                "opsOnly" .= take 10 (facts \\ stored),
                "sqlOnly" .= take 10 (stored \\ facts),
                "opsFacts" .= length facts,
                "sqlFacts" .= length stored
              ]
          ]
  where
    contextText = case context of
      Shop -> "shop" :: Text
      Warehouse -> "warehouse"

field :: Text -> Value -> Either Text Value
field name = \case
  Object fields -> maybe (Left ("missing field " <> name)) Right (KeyMap.lookup (Key.fromText name) fields)
  _ -> Left ("expected an object with field " <> name)

array :: Value -> Either Text [Value]
array = \case
  Array rows -> Right (toList rows)
  _ -> Left "expected an array"

text :: Value -> Either Text Text
text = \case
  String raw -> Right raw
  other -> Left ("expected text, found " <> textShow other)

nullableText :: Value -> Either Text (Maybe Text)
nullableText = \case
  Null -> Right Nothing
  other -> Just <$> text other

integer :: Value -> Either Text Int64
integer = \case
  Number n -> either (const (Left "expected an integer")) Right (floatingOrInteger n :: Either Double Int64)
  other -> Left ("expected an integer, found " <> textShow other)

countFact :: Text -> Tx.Transaction [Text]
countFact query = do
  count <- Tx.statement () (Statement.preparable query Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))
  pure [textShow count]

textFacts :: Text -> Tx.Transaction [Text]
textFacts query = Tx.statement () (Statement.preparable query Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text))))

textShow :: (Show a) => a -> Text
textShow = Text.pack . show
