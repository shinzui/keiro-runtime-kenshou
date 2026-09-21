module Kenshou.Check.Oracle.Keiro
  ( outboxNonTerminal,
    inboxByStatus,
    timersByStatus,
    workflowLeases,
    shardOwners,
    deadLetters,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Oracle

outboxNonTerminal :: OracleQuery Int64
outboxNonTerminal = countQuery "keiro-outbox-non-terminal" "SELECT count(*) FROM keiro.keiro_outbox WHERE status NOT IN ('sent', 'rejected', 'dead')"

inboxByStatus, timersByStatus, workflowLeases, shardOwners, deadLetters :: OracleQuery Text
inboxByStatus = textQuery "keiro-inbox-by-status" "SELECT coalesce(json_agg(rows), '[]'::json)::text FROM (SELECT status, count(*) FROM keiro.keiro_inbox GROUP BY status) rows"
timersByStatus = textQuery "keiro-timers-by-status" "SELECT coalesce(json_agg(rows), '[]'::json)::text FROM (SELECT status, count(*) FROM keiro.keiro_timers GROUP BY status) rows"
workflowLeases = textQuery "keiro-workflow-leases" "SELECT coalesce(json_agg(rows), '[]'::json)::text FROM (SELECT leased_by, lease_expires_at FROM keiro.keiro_workflows) rows"
shardOwners = textQuery "keiro-shard-owners" "SELECT coalesce(json_agg(rows), '[]'::json)::text FROM (SELECT owner_worker_id, lease_expires_at FROM keiro.keiro_subscription_shards) rows"
deadLetters = textQuery "keiro-dead-letters" "SELECT count(*)::text FROM keiro.keiro_dead_letters"

countQuery name sql = OracleQuery name sql (maybe (Left "expected integer") Right . readMaybe . Text.unpack)

textQuery name sql = OracleQuery name sql Right

readMaybe input = case reads input of [(value, "")] -> Just value; _ -> Nothing
