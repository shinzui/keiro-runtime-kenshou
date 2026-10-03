module Kenshou.Suite.Runtime.System.Schema
  ( ContextName (..),
    contextSchema,
    ensureShopTables,
    ensureWarehouseTables,
    orderProjection,
    fulfilmentProjection,
    IntakeRow (..),
    insertIntakeTx,
    pendingIntakeTx,
    undispatchedIntakeTx,
    markIntakeDispatchedTx,
    insertPoisonTx,
    upsertPickRequestTx,
    insertReferralsTx,
    referrersTx,
    StatusCounts (..),
    orderStatusCountsTx,
    fulfilmentStatusCountsTx,
    Backlog (..),
    backlogTx,
    stuckWorkTx,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Functor.Contravariant (contramap)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), Sku (..))
import Kenshou.Suite.Runtime.System.Fulfilment (FulfilmentEvent (..), FulfilmentExpiredData (..), FulfilmentRefusedData (..), FulfilmentRequestedData (..), FulfilmentShippedData (..))
import Kenshou.Suite.Runtime.System.Order (OrderCompletedData (..), OrderEvent (..), OrderExpiredData (..), OrderPlacedData (..), OrderRejectedData (..))
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..))

data ContextName = Shop | Warehouse
  deriving stock (Eq, Ord, Show, Enum, Bounded)

contextSchema :: ContextName -> Text
contextSchema = \case
  Shop -> "shop"
  Warehouse -> "warehouse"

-- The kernel's migration plan covers only kiroku, keiro and PGMQ, so the
-- application tables are created here, idempotently, before any role starts.

ensureShopTables :: (Store :> es) => Eff es ()
ensureShopTables = runTransaction do
  Tx.sql "CREATE SCHEMA IF NOT EXISTS shop"
  Tx.sql "CREATE TABLE IF NOT EXISTS shop.orders (order_id text PRIMARY KEY, customer text NOT NULL, sku text NOT NULL, quantity integer NOT NULL, amount_cents bigint NOT NULL, slow_pick boolean NOT NULL, status text NOT NULL, terminal_count integer NOT NULL DEFAULT 0, placed_position bigint NOT NULL, updated_at timestamptz NOT NULL DEFAULT clock_timestamp())"
  Tx.sql "CREATE TABLE IF NOT EXISTS shop.referrals (customer text NOT NULL, referrer text NOT NULL, PRIMARY KEY (customer, referrer))"
  intakeTables "shop"

ensureWarehouseTables :: (Store :> es) => Eff es ()
ensureWarehouseTables = runTransaction do
  Tx.sql "CREATE SCHEMA IF NOT EXISTS warehouse"
  Tx.sql "CREATE TABLE IF NOT EXISTS warehouse.fulfilments (order_id text PRIMARY KEY, sku text, quantity integer, slow_pick boolean, status text NOT NULL, terminal_count integer NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT clock_timestamp())"
  Tx.sql "CREATE TABLE IF NOT EXISTS warehouse.pick_requests (order_id text PRIMARY KEY, sku text NOT NULL, quantity integer NOT NULL, awakeable_id text NOT NULL, slow_pick boolean NOT NULL, requested_at timestamptz NOT NULL DEFAULT clock_timestamp())"
  intakeTables "warehouse"

intakeTables :: Text -> Tx.Transaction ()
intakeTables schema = do
  Tx.sql (TextEncoding.encodeUtf8 ("CREATE TABLE IF NOT EXISTS " <> schema <> ".intake (message_id text PRIMARY KEY, order_id text NOT NULL, kind text NOT NULL, payload jsonb NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(), dispatched_at timestamptz)"))
  Tx.sql (TextEncoding.encodeUtf8 ("CREATE TABLE IF NOT EXISTS " <> schema <> ".poison_records (topic text NOT NULL, partition integer NOT NULL, kafka_offset bigint NOT NULL, reason text NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (topic, partition, kafka_offset))"))

-- | Runs in the append transaction of every order event, so the read model
-- and the stream can never disagree about whether an event happened.
orderProjection :: InlineProjection OrderEvent
orderProjection =
  InlineProjection
    { name = "kenshou-runtime-shop-orders",
      apply = \event recorded -> case event of
        OrderPlaced d ->
          let OrderId order = d.orderId
              CustomerId customer = d.customer
              Sku sku = d.sku
              GlobalPosition position = recorded.globalPosition
           in Tx.statement
                (object ["order" .= order, "customer" .= customer, "sku" .= sku, "quantity" .= d.quantity, "amount" .= d.amountCents, "slow" .= d.slowPick, "position" .= position])
                insertOrderStatement
        OrderCompleted d -> terminal "shop" (orderText d.orderId) "completed"
        OrderRejected d -> terminal "shop" (orderText d.orderId) "rejected"
        OrderExpired d -> terminal "shop" (orderText d.orderId) "expired"
    }

fulfilmentProjection :: InlineProjection FulfilmentEvent
fulfilmentProjection =
  InlineProjection
    { name = "kenshou-runtime-warehouse-fulfilments",
      apply = \event _ -> case event of
        FulfilmentRequested d ->
          let OrderId order = d.orderId
              Sku sku = d.sku
           in Tx.statement (object ["order" .= order, "sku" .= sku, "quantity" .= d.quantity, "slow" .= d.slowPick]) insertFulfilmentStatement
        FulfilmentRefused d -> refused (orderText d.orderId)
        FulfilmentShipped d -> terminal "warehouse" (orderText d.orderId) "shipped"
        FulfilmentExpired d -> terminal "warehouse" (orderText d.orderId) "expired"
    }
  where
    refused order = Tx.statement (object ["order" .= order]) refusedFulfilmentStatement

terminal :: Text -> Text -> Text -> Tx.Transaction ()
terminal schema order status = Tx.statement (object ["order" .= order, "status" .= status]) (terminalStatement schema)

insertOrderStatement :: Statement.Statement Value ()
insertOrderStatement =
  jsonStatement
    "INSERT INTO shop.orders (order_id, customer, sku, quantity, amount_cents, slow_pick, status, placed_position) SELECT x->>'order', x->>'customer', x->>'sku', (x->>'quantity')::integer, (x->>'amount')::bigint, (x->>'slow')::boolean, 'placed', (x->>'position')::bigint FROM (SELECT $1::jsonb AS x) input"

insertFulfilmentStatement :: Statement.Statement Value ()
insertFulfilmentStatement =
  jsonStatement
    "INSERT INTO warehouse.fulfilments (order_id, sku, quantity, slow_pick, status) SELECT x->>'order', x->>'sku', (x->>'quantity')::integer, (x->>'slow')::boolean, 'requested' FROM (SELECT $1::jsonb AS x) input"

-- A refusal is itself terminal, and it is the first event of its stream.
refusedFulfilmentStatement :: Statement.Statement Value ()
refusedFulfilmentStatement =
  jsonStatement
    "INSERT INTO warehouse.fulfilments (order_id, status, terminal_count) SELECT x->>'order', 'refused', 1 FROM (SELECT $1::jsonb AS x) input"

terminalStatement :: Text -> Statement.Statement Value ()
terminalStatement schema =
  jsonStatement
    ( ( "UPDATE "
          <> schema
          <> (if schema == "shop" then ".orders" else ".fulfilments")
          <> " SET status = x->>'status', terminal_count = terminal_count + 1, updated_at = clock_timestamp() FROM (SELECT $1::jsonb AS x) input WHERE order_id = x->>'order'"
      )
    )

data IntakeRow = IntakeRow
  { messageId :: !Text,
    orderId :: !Text,
    kind :: !Text,
    payload :: !Value
  }
  deriving stock (Eq, Show)

intakeEncoder :: Encoders.Params IntakeRow
intakeEncoder =
  contramap (.messageId) (Encoders.param (Encoders.nonNullable Encoders.text))
    <> contramap (.orderId) (Encoders.param (Encoders.nonNullable Encoders.text))
    <> contramap (.kind) (Encoders.param (Encoders.nonNullable Encoders.text))
    <> contramap (.payload) (Encoders.param (Encoders.nonNullable Encoders.jsonb))

intakeDecoder :: Decoders.Row IntakeRow
intakeDecoder =
  IntakeRow
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)

insertIntakeTx :: ContextName -> IntakeRow -> Tx.Transaction ()
insertIntakeTx context row =
  Tx.statement row $
    Statement.preparable
      (("INSERT INTO " <> contextSchema context <> ".intake (message_id, order_id, kind, payload) VALUES ($1, $2, $3, $4) ON CONFLICT (message_id) DO NOTHING"))
      intakeEncoder
      Decoders.noResult

pendingIntakeTx :: ContextName -> Text -> Tx.Transaction (Maybe IntakeRow)
pendingIntakeTx context message =
  Tx.statement message $
    Statement.preparable
      (("SELECT message_id, order_id, kind, payload FROM " <> contextSchema context <> ".intake WHERE message_id = $1 AND dispatched_at IS NULL"))
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.rowMaybe intakeDecoder)

undispatchedIntakeTx :: ContextName -> Tx.Transaction [IntakeRow]
undispatchedIntakeTx context =
  Tx.statement () $
    Statement.preparable
      (("SELECT message_id, order_id, kind, payload FROM " <> contextSchema context <> ".intake WHERE dispatched_at IS NULL ORDER BY received_at"))
      Encoders.noParams
      (Decoders.rowList intakeDecoder)

markIntakeDispatchedTx :: ContextName -> Text -> Tx.Transaction ()
markIntakeDispatchedTx context message =
  Tx.statement message $
    Statement.preparable
      (("UPDATE " <> contextSchema context <> ".intake SET dispatched_at = clock_timestamp() WHERE message_id = $1 AND dispatched_at IS NULL"))
      (Encoders.param (Encoders.nonNullable Encoders.text))
      Decoders.noResult

insertPoisonTx :: ContextName -> Text -> Int -> Int64 -> Text -> Tx.Transaction ()
insertPoisonTx context topic partition offset reason =
  Tx.statement (object ["topic" .= topic, "partition" .= partition, "offset" .= offset, "reason" .= reason]) $
    jsonStatement
      (("INSERT INTO " <> contextSchema context <> ".poison_records (topic, partition, kafka_offset, reason) SELECT x->>'topic', (x->>'partition')::integer, (x->>'offset')::bigint, x->>'reason' FROM (SELECT $1::jsonb AS x) input ON CONFLICT DO NOTHING"))

upsertPickRequestTx :: OrderId -> Sku -> Int -> Text -> Bool -> Tx.Transaction ()
upsertPickRequestTx (OrderId order) (Sku sku) quantity awakeable slow =
  Tx.statement (object ["order" .= order, "sku" .= sku, "quantity" .= quantity, "awakeable" .= awakeable, "slow" .= slow]) $
    jsonStatement
      "INSERT INTO warehouse.pick_requests (order_id, sku, quantity, awakeable_id, slow_pick) SELECT x->>'order', x->>'sku', (x->>'quantity')::integer, x->>'awakeable', (x->>'slow')::boolean FROM (SELECT $1::jsonb AS x) input ON CONFLICT (order_id) DO UPDATE SET awakeable_id = EXCLUDED.awakeable_id"

insertReferralsTx :: [(Text, Text)] -> Tx.Transaction ()
insertReferralsTx pairs =
  Tx.statement (object ["pairs" .= [object ["customer" .= customer, "referrer" .= referrer] | (customer, referrer) <- pairs]]) $
    jsonStatement
      "INSERT INTO shop.referrals (customer, referrer) SELECT p->>'customer', p->>'referrer' FROM (SELECT $1::jsonb AS x) input, jsonb_array_elements(x->'pairs') p ON CONFLICT DO NOTHING"

referrersTx :: CustomerId -> Tx.Transaction [Text]
referrersTx (CustomerId customer) =
  Tx.statement customer $
    Statement.preparable
      "SELECT referrer FROM shop.referrals WHERE customer = $1 ORDER BY referrer"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

-- | Row counts per status, plus rows whose terminal event was applied more
-- than once (which the aggregate must make impossible).
data StatusCounts = StatusCounts
  { total :: !Int64,
    byStatus :: ![(Text, Int64)],
    multipleTerminals :: !Int64
  }
  deriving stock (Eq, Show)

orderStatusCountsTx :: Tx.Transaction StatusCounts
orderStatusCountsTx = statusCounts "shop.orders"

fulfilmentStatusCountsTx :: Tx.Transaction StatusCounts
fulfilmentStatusCountsTx = statusCounts "warehouse.fulfilments"

statusCounts :: Text -> Tx.Transaction StatusCounts
statusCounts table = do
  rows <-
    Tx.statement () $
      Statement.preparable
        (("SELECT status, count(*) FROM " <> table <> " GROUP BY status ORDER BY status"))
        Encoders.noParams
        (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
  multiple <-
    Tx.statement () $
      Statement.preparable
        (("SELECT count(*) FROM " <> table <> " WHERE terminal_count > 1"))
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  pure (StatusCounts (sum (fmap snd rows)) rows multiple)

-- | Work that has not reached a terminal state in one context. Quiescence
-- requires every field to be zero.
data Backlog = Backlog
  { outboxUnsent :: !Int64,
    inboxUnfinished :: !Int64,
    intakeUndispatched :: !Int64,
    workflowsUnfinished :: !Int64,
    timersPending :: !Int64,
    awakeablesPending :: !Int64
  }
  deriving stock (Eq, Show)

backlogTx :: ContextName -> Tx.Transaction Backlog
backlogTx context =
  Backlog
    <$> count "SELECT count(*) FROM keiro.keiro_outbox WHERE status <> 'sent'"
    <*> count "SELECT count(*) FROM keiro.keiro_inbox WHERE status IN ('processing', 'failed')"
    <*> count ("SELECT count(*) FROM " <> contextSchema context <> ".intake WHERE dispatched_at IS NULL")
    <*> count "SELECT count(*) FROM keiro.keiro_workflows WHERE status NOT IN ('completed', 'cancelled')"
    <*> count "SELECT count(*) FROM keiro.keiro_timers WHERE status IN ('scheduled', 'firing')"
    <*> count "SELECT count(*) FROM keiro.keiro_awakeables WHERE status = 'pending'"
  where
    count sql = Tx.statement () (Statement.preparable sql Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))

-- | Up to twenty examples of unfinished work per kind, for the counter
-- example of an unreached quiescence.
stuckWorkTx :: ContextName -> Tx.Transaction Value
stuckWorkTx context = Tx.statement () (Statement.preparable sql Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.jsonb))))
  where
    schema = contextSchema context
    examples query = "(SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) FROM (" <> query <> " LIMIT 20) q)"
    readModel = case context of
      Shop -> "SELECT order_id, status, sku, slow_pick, terminal_count FROM shop.orders WHERE status = 'placed' OR terminal_count <> 1"
      Warehouse -> "SELECT order_id, status, sku, terminal_count FROM warehouse.fulfilments WHERE status = 'requested' OR terminal_count <> 1"
    sql =
      "SELECT jsonb_build_object("
        <> "'readModel', "
        <> examples readModel
        <> ", 'outbox', "
        <> examples "SELECT * FROM keiro.keiro_outbox WHERE status <> 'sent'"
        <> ", 'inbox', "
        <> examples "SELECT * FROM keiro.keiro_inbox WHERE status IN ('processing', 'failed')"
        <> ", 'intake', "
        <> examples ("SELECT message_id, order_id, kind FROM " <> schema <> ".intake WHERE dispatched_at IS NULL")
        <> ", 'outboxForStuckOrders', "
        <> examples ("SELECT o.* FROM keiro.keiro_outbox o JOIN " <> (if context == Shop then "shop.orders s ON o.message_key = s.order_id WHERE s.status = 'placed'" else "warehouse.fulfilments s ON o.message_key = s.order_id WHERE s.status = 'requested'"))
        <> ", 'poison', "
        <> examples ("SELECT * FROM " <> schema <> ".poison_records")
        <> ", 'workflows', "
        <> examples "SELECT * FROM keiro.keiro_workflows WHERE status NOT IN ('completed', 'cancelled')"
        <> ", 'timers', "
        <> examples "SELECT * FROM keiro.keiro_timers WHERE status IN ('scheduled', 'firing', 'dead')"
        <> ", 'awakeables', "
        <> examples "SELECT * FROM keiro.keiro_awakeables WHERE status = 'pending'"
        <> ", 'deadLetters', "
        <> examples "SELECT * FROM kiroku.dead_letters"
        <> ")"

jsonStatement :: Text -> Statement.Statement Value ()
jsonStatement sql = Statement.preparable (sql) (Encoders.param (Encoders.nonNullable Encoders.jsonb)) Decoders.noResult

orderText :: OrderId -> Text
orderText (OrderId value) = value
