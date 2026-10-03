module Kenshou.Suite.Runtime.Oracle.Sql
  ( StreamOutcome (..),
    orderOutcomePageTx,
    fulfilmentOutcomePageTx,
    EffectRow (..),
    shopEffectPageTx,
    warehouseEffectPageTx,
    ShopTotals (..),
    shopTotalsTx,
    SkuStock (..),
    skuStockTx,
    deadLetterExamplesTx,
    orphanCountsTx,
    CheckpointKey (..),
    checkpointsTx,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant (contramap)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx

-- These queries only gather durable facts, one page at a time; the pure
-- judgements in "Kenshou.Suite.Runtime.Oracle" decide whether they violate an
-- invariant. Lifecycle facts come from the event store itself, and the read
-- model's status is read alongside so the two can be compared.

-- | The lifecycle of one entity stream as recorded in the event store.
data StreamOutcome = StreamOutcome
  { orderId :: !Text,
    firstEvents :: !Int64,
    terminalEvents :: !Int64,
    terminalKind :: !(Maybe Text),
    readModelStatus :: !(Maybe Text),
    quantity :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

-- | One page of order streams after the given order identifier, in byte
-- order. @firstEvents@ counts @OrderPlaced@.
orderOutcomePageTx :: Text -> Int64 -> Tx.Transaction [StreamOutcome]
orderOutcomePageTx = outcomePage "order" "shop.orders" "'OrderPlaced'" "'OrderCompleted', 'OrderRejected', 'OrderExpired'"

-- | One page of fulfilment streams. @firstEvents@ counts @FulfilmentRequested@
-- and @FulfilmentRefused@; a refusal is both first and terminal.
fulfilmentOutcomePageTx :: Text -> Int64 -> Tx.Transaction [StreamOutcome]
fulfilmentOutcomePageTx = outcomePage "fulfilment" "warehouse.fulfilments" "'FulfilmentRequested', 'FulfilmentRefused'" "'FulfilmentShipped', 'FulfilmentRefused', 'FulfilmentExpired'"

outcomePage :: Text -> Text -> Text -> Text -> Text -> Int64 -> Tx.Transaction [StreamOutcome]
outcomePage category readModel firstTypes terminalTypes after limit =
  Tx.statement (after, limit) $
    Statement.preparable
      ( "WITH page AS (SELECT stream_id, substr(stream_name, "
          <> offset
          <> ") AS entity FROM kiroku.streams WHERE category = '"
          <> category
          <> "' AND substr(stream_name, "
          <> offset
          <> ") COLLATE \"C\" > $1 ORDER BY substr(stream_name, "
          <> offset
          <> ") COLLATE \"C\" LIMIT $2), "
          <> "ev AS (SELECT p.entity, count(*) FILTER (WHERE e.event_type IN ("
          <> firstTypes
          <> ")) AS firsts, count(*) FILTER (WHERE e.event_type IN ("
          <> terminalTypes
          <> ")) AS terminals, max(e.event_type) FILTER (WHERE e.event_type IN ("
          <> terminalTypes
          <> ")) AS kind FROM page p JOIN kiroku.stream_events se ON se.stream_id = p.stream_id AND se.original_stream_id = p.stream_id JOIN kiroku.events e ON e.event_id = se.event_id GROUP BY p.entity) "
          <> "SELECT ev.entity, ev.firsts, ev.terminals, ev.kind, r.status, r.quantity::bigint FROM ev LEFT JOIN "
          <> readModel
          <> " r ON r.order_id = ev.entity ORDER BY ev.entity COLLATE \"C\""
      )
      (contramap fst (Encoders.param (Encoders.nonNullable Encoders.text)) <> contramap snd (Encoders.param (Encoders.nonNullable Encoders.int8)))
      ( Decoders.rowList
          ( StreamOutcome
              <$> Decoders.column (Decoders.nonNullable Decoders.text)
              <*> Decoders.column (Decoders.nonNullable Decoders.int8)
              <*> Decoders.column (Decoders.nonNullable Decoders.int8)
              <*> Decoders.column (Decoders.nullable Decoders.text)
              <*> Decoders.column (Decoders.nullable Decoders.text)
              <*> Decoders.column (Decoders.nullable Decoders.int8)
          )
      )
  where
    -- Entity streams are named @<category>-<id>@; the identifier starts
    -- after the separator.
    offset = textShow (Text.length category + 2)

-- | Ledger movements of one order, keyed by @<purpose>/<direction>@ (for
-- example @hold/debit@), with the read model's status.
data EffectRow = EffectRow
  { orderId :: !Text,
    status :: !Text,
    movements :: !(Map Text Int64)
  }
  deriving stock (Eq, Show)

shopEffectPageTx :: Text -> Int64 -> Tx.Transaction [EffectRow]
shopEffectPageTx = effectPage "shop.orders"

warehouseEffectPageTx :: Text -> Int64 -> Tx.Transaction [EffectRow]
warehouseEffectPageTx = effectPage "warehouse.fulfilments"

effectPage :: Text -> Text -> Int64 -> Tx.Transaction [EffectRow]
effectPage readModel after limit = do
  rows <-
    Tx.statement (after, limit) $
      Statement.preparable
        ( "WITH page AS (SELECT order_id, status FROM "
            <> readModel
            <> " WHERE order_id COLLATE \"C\" > $1 ORDER BY order_id COLLATE \"C\" LIMIT $2) "
            <> "SELECT p.order_id, p.status, coalesce(jsonb_object_agg(m.movement, m.n) FILTER (WHERE m.movement IS NOT NULL), '{}'::jsonb) FROM page p LEFT JOIN (SELECT split_part(transfer_ref, ':', 1) AS order_id, split_part(transfer_ref, ':', 2) || '/' || direction AS movement, count(*) AS n FROM ledger.entries GROUP BY 1, 2) m ON m.order_id = p.order_id GROUP BY p.order_id, p.status ORDER BY p.order_id COLLATE \"C\""
        )
        (contramap fst (Encoders.param (Encoders.nonNullable Encoders.text)) <> contramap snd (Encoders.param (Encoders.nonNullable Encoders.int8)))
        ( Decoders.rowList
            ( (,,)
                <$> Decoders.column (Decoders.nonNullable Decoders.text)
                <*> Decoders.column (Decoders.nonNullable Decoders.text)
                <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
            )
        )
  pure [EffectRow order status (decodeCounts counts) | (order, status, counts) <- rows]
  where
    decodeCounts value = case fromJsonCounts value of
      Just counts -> counts
      Nothing -> Map.empty

fromJsonCounts :: Value -> Maybe (Map Text Int64)
fromJsonCounts value = case Aeson.fromJSON value of
  Aeson.Success counts -> Just counts
  Aeson.Error _ -> Nothing

-- | Money balances by account role, with the amounts the completed orders
-- imply, all from the shop database.
data ShopTotals = ShopTotals
  { total :: !Int64,
    escrow :: !Int64,
    merchant :: !Int64,
    pool :: !Int64,
    loyaltyAccounts :: !Int64,
    capturedAmount :: !Int64,
    completedOrders :: !Int64,
    completedQuantity :: !Int64,
    -- | The sum over completed orders of one loyalty bonus, so the pool's
    -- payout is this times the router fanout.
    bonusUnits :: !Int64
  }
  deriving stock (Eq, Show)

shopTotalsTx :: Tx.Transaction ShopTotals
shopTotalsTx =
  Tx.statement () $
    Statement.preparable
      ( "WITH b AS (SELECT account_id, balance FROM kenshou_keiro.account_balance) SELECT "
          <> "(SELECT coalesce(sum(balance), 0) FROM b)::bigint, "
          <> "(SELECT coalesce(sum(balance), 0) FROM b WHERE account_id = 'escrow')::bigint, "
          <> "(SELECT coalesce(sum(balance), 0) FROM b WHERE account_id = 'merchant')::bigint, "
          <> "(SELECT coalesce(sum(balance), 0) FROM b WHERE account_id = 'loyalty-pool')::bigint, "
          <> "(SELECT coalesce(sum(balance), 0) FROM b WHERE account_id LIKE 'loyalty-customer-%')::bigint, "
          <> "(SELECT coalesce(sum(amount_cents), 0) FROM shop.orders WHERE status = 'completed')::bigint, "
          <> "(SELECT count(*) FROM shop.orders WHERE status = 'completed')::bigint, "
          <> "(SELECT coalesce(sum(quantity), 0) FROM shop.orders WHERE status = 'completed')::bigint, "
          <> "(SELECT coalesce(sum(greatest(1, amount_cents / 100)), 0) FROM shop.orders WHERE status = 'completed')::bigint"
      )
      Encoders.noParams
      ( Decoders.singleRow
          ( ShopTotals
              <$> int8
              <*> int8
              <*> int8
              <*> int8
              <*> int8
              <*> int8
              <*> int8
              <*> int8
              <*> int8
          )
      )
  where
    int8 = Decoders.column (Decoders.nonNullable Decoders.int8)

-- | Stock buckets per SKU, and the quantity of shipped fulfilments.
data SkuStock = SkuStock
  { sku :: !Text,
    available :: !Int64,
    reserved :: !Int64,
    shipped :: !Int64,
    shippedFulfilments :: !Int64
  }
  deriving stock (Eq, Show)

skuStockTx :: Tx.Transaction [SkuStock]
skuStockTx =
  Tx.statement () $
    Statement.preparable
      ( "WITH b AS (SELECT regexp_replace(account_id, '-(available|reserved|shipped)$', '') AS sku, substring(account_id from '(available|reserved|shipped)$') AS bucket, balance FROM kenshou_keiro.account_balance WHERE account_id ~ '^sku-'), "
          <> "s AS (SELECT sku, coalesce(sum(balance) FILTER (WHERE bucket = 'available'), 0)::bigint AS available, coalesce(sum(balance) FILTER (WHERE bucket = 'reserved'), 0)::bigint AS reserved, coalesce(sum(balance) FILTER (WHERE bucket = 'shipped'), 0)::bigint AS shipped FROM b GROUP BY sku), "
          <> "f AS (SELECT sku, coalesce(sum(quantity), 0)::bigint AS shipped FROM warehouse.fulfilments WHERE status = 'shipped' GROUP BY sku) "
          <> "SELECT s.sku, s.available, s.reserved, s.shipped, coalesce(f.shipped, 0)::bigint FROM s LEFT JOIN f ON f.sku = s.sku ORDER BY s.sku"
      )
      Encoders.noParams
      ( Decoders.rowList
          ( SkuStock
              <$> Decoders.column (Decoders.nonNullable Decoders.text)
              <*> int8
              <*> int8
              <*> int8
              <*> int8
          )
      )
  where
    int8 = Decoders.column (Decoders.nonNullable Decoders.int8)

-- | Up to twenty process-manager or router dispatches that Keiro
-- dead-lettered. The reference system never relies on a rejected command.
deadLetterExamplesTx :: Tx.Transaction (Int64, [Value])
deadLetterExamplesTx = do
  total <- scalar "SELECT count(*) FROM keiro.keiro_dead_letters"
  rows <- Tx.statement () (Statement.preparable "SELECT to_jsonb(d) FROM keiro.keiro_dead_letters d LIMIT 20" Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.jsonb))))
  pure (total, rows)

-- | Work left behind anywhere in one context: unsent or dead outbox rows,
-- unfinished inbox rows, undispatched intake, unfinished workflows, pending
-- or dead timers, pending awakeables, subscription dead letters, poison
-- records, and, for the warehouse, messages left in the pick queue or its
-- dead-letter queue.
orphanCountsTx :: Text -> Bool -> Tx.Transaction [(Text, Int64)]
orphanCountsTx schema warehouse =
  traverse
    (\(name, query) -> (name,) <$> scalar query)
    ( [ ("outbox-unsent", "SELECT count(*) FROM keiro.keiro_outbox WHERE status <> 'sent'"),
        ("inbox-unfinished", "SELECT count(*) FROM keiro.keiro_inbox WHERE status IN ('processing', 'failed')"),
        ("intake-undispatched", "SELECT count(*) FROM " <> schema <> ".intake WHERE dispatched_at IS NULL"),
        ("workflows-unfinished", "SELECT count(*) FROM keiro.keiro_workflows WHERE status NOT IN ('completed', 'cancelled')"),
        ("timers-pending-or-dead", "SELECT count(*) FROM keiro.keiro_timers WHERE status IN ('scheduled', 'firing', 'dead')"),
        ("awakeables-pending", "SELECT count(*) FROM keiro.keiro_awakeables WHERE status = 'pending'"),
        ("subscription-dead-letters", "SELECT count(*) FROM kiroku.dead_letters"),
        ("poison-records", "SELECT count(*) FROM " <> schema <> ".poison_records")
      ]
        <> if warehouse
          then
            [ ("pick-queue", "SELECT count(*) FROM pgmq.q_pick"),
              ("pick-dead-letters", "SELECT count(*) FROM pgmq.q_pick_dlq")
            ]
          else []
    )

-- | One subscription member's durable checkpoint.
data CheckpointKey = CheckpointKey
  { subscription :: !Text,
    member :: !Int64,
    size :: !Int64
  }
  deriving stock (Eq, Ord, Show)

checkpointsTx :: Tx.Transaction [(CheckpointKey, Int64)]
checkpointsTx =
  Tx.statement () $
    Statement.preparable
      "SELECT subscription_name, consumer_group_member::bigint, consumer_group_size::bigint, last_seen FROM kiroku.subscriptions ORDER BY 1, 2, 3"
      Encoders.noParams
      ( Decoders.rowList
          ( (\name member size seen -> (CheckpointKey name member size, seen))
              <$> Decoders.column (Decoders.nonNullable Decoders.text)
              <*> Decoders.column (Decoders.nonNullable Decoders.int8)
              <*> Decoders.column (Decoders.nonNullable Decoders.int8)
              <*> Decoders.column (Decoders.nonNullable Decoders.int8)
          )
      )

scalar :: Text -> Tx.Transaction Int64
scalar query = Tx.statement () (Statement.preparable query Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))

textShow :: (Show a) => a -> Text
textShow = Text.pack . show
