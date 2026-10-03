module Kenshou.Suite.Runtime.Oracle
  ( -- * Pure judgements
    Judgement (..),
    emptyJudgement,
    judgePair,
    mergeOutcomes,
    judgeShopEffects,
    judgeWarehouseEffects,
    SeededLedgers (..),
    judgeShopConservation,
    judgeWarehouseConservation,
    judgeOrphans,

    -- * Running the oracle
    verifyEndToEnd,
    verdictFor,

    -- * Sabotage controls
    Sabotage (..),
    sabotageFrom,
    applySabotage,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Transaction qualified as Tx
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Suite.Runtime.Oracle.Sql
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..), customerCount, skuCount)
import Kenshou.Suite.Runtime.System.Shop (openingCustomerBalance, openingLoyaltyPool)
import Kenshou.Suite.Runtime.System.Store (ContextStore, runSql)
import Kenshou.Suite.Runtime.System.Warehouse (openingStock)

-- | A violation count over a number of examined items, with at most twenty
-- counter-examples. Judgements combine with '<>' so pages fold in constant
-- memory.
data Judgement = Judgement
  { examined :: !Int64,
    violations :: !Int64,
    examples :: ![Value]
  }
  deriving stock (Eq, Show)

instance Semigroup Judgement where
  Judgement a b c <> Judgement d e f = Judgement (a + d) (b + e) (take 20 (c <> f))

instance Monoid Judgement where
  mempty = emptyJudgement

emptyJudgement :: Judgement
emptyJudgement = Judgement 0 0 []

single :: [Text] -> Value -> Judgement
single [] _ = Judgement 1 0 []
single problems detail = Judgement 1 1 [object ["problems" .= problems, "detail" .= detail]]

orderStatusFor, fulfilmentStatusFor :: Maybe Text -> Text
orderStatusFor = \case
  Just "OrderCompleted" -> "completed"
  Just "OrderRejected" -> "rejected"
  Just "OrderExpired" -> "expired"
  _ -> "placed"
fulfilmentStatusFor = \case
  Just "FulfilmentShipped" -> "shipped"
  Just "FulfilmentRefused" -> "refused"
  Just "FulfilmentExpired" -> "expired"
  _ -> "requested"

-- | I1 for one order: exactly one placement and one terminal event in the
-- shop, exactly one request-or-refusal and one terminal event in the
-- warehouse, terminal kinds that match across contexts, read models that
-- agree with their streams, and the same quantity for a shipped order.
judgePair :: Maybe StreamOutcome -> Maybe StreamOutcome -> Judgement
judgePair order fulfilment =
  single
    (catMaybes checks)
    (object ["order" .= fmap describe order, "fulfilment" .= fmap describe fulfilment])
  where
    describe outcome =
      object
        [ "orderId" .= outcome.orderId,
          "firstEvents" .= outcome.firstEvents,
          "terminalEvents" .= outcome.terminalEvents,
          "terminalKind" .= outcome.terminalKind,
          "readModel" .= outcome.readModelStatus,
          "quantity" .= outcome.quantity
        ]
    checks = case (order, fulfilment) of
      (Nothing, Nothing) -> []
      (Nothing, Just _) -> [Just "fulfilment without an order"]
      (Just _, Nothing) -> [Just "order never reached the warehouse"]
      (Just o, Just f) ->
        [ problem (o.firstEvents /= 1) "order placement count is not one",
          problem (o.terminalEvents /= 1) "order terminal event count is not one",
          problem (f.firstEvents /= 1) "fulfilment decision count is not one",
          problem (f.terminalEvents /= 1) "fulfilment terminal event count is not one",
          problem (o.readModelStatus /= Just (orderStatusFor o.terminalKind)) "shop read model disagrees with the order stream",
          problem (f.readModelStatus /= Just (fulfilmentStatusFor f.terminalKind)) "warehouse read model disagrees with the fulfilment stream",
          problem (not (matching o.terminalKind f.terminalKind)) "terminal kinds do not match across contexts",
          problem (f.terminalKind == Just "FulfilmentShipped" && f.quantity /= o.quantity) "shipped quantity differs from the order quantity"
        ]
    problem condition message = if condition then Just message else Nothing
    matching (Just "OrderCompleted") (Just "FulfilmentShipped") = True
    matching (Just "OrderRejected") (Just "FulfilmentRefused") = True
    matching (Just "OrderExpired") (Just "FulfilmentExpired") = True
    matching _ _ = False

-- | Merge-join two pages ordered by order identifier. Returns the judgement
-- of every pair that can be decided and the unconsumed tails. A side marked
-- exhausted has no further pages, so the other side's items are unmatched.
mergeOutcomes :: Bool -> Bool -> [StreamOutcome] -> [StreamOutcome] -> (Judgement, [StreamOutcome], [StreamOutcome])
mergeOutcomes ordersDone fulfilmentsDone = go mempty
  where
    go acc [] [] = (acc, [], [])
    go acc [] fs
      | ordersDone = (acc <> foldMap (judgePair Nothing . Just) fs, [], [])
      | otherwise = (acc, [], fs)
    go acc os []
      | fulfilmentsDone = (acc <> foldMap (\o -> judgePair (Just o) Nothing) os, [], [])
      | otherwise = (acc, os, [])
    go acc (o : os) (f : fs) = case compare (byteKey o.orderId) (byteKey f.orderId) of
      EQ -> go (acc <> judgePair (Just o) (Just f)) os fs
      LT -> go (acc <> judgePair (Just o) Nothing) os (f : fs)
      GT -> go (acc <> judgePair Nothing (Just f)) (o : os) fs
    -- PostgreSQL orders with COLLATE "C", which is byte order of UTF-8.
    byteKey = Text.unpack

-- | I2 in the shop: one hold pair; then a capture pair with the loyalty
-- payout for a completed order, or a refund pair for a rejected or expired
-- one.
judgeShopEffects :: Int -> EffectRow -> Judgement
judgeShopEffects fanout row =
  single (if expected == actual then [] else ["ledger movements differ from the order's outcome"]) (object ["orderId" .= row.orderId, "status" .= row.status, "movements" .= actual, "expected" .= expected])
  where
    actual = Map.filter (/= 0) row.movements
    pair purpose = [(purpose <> "/debit", 1), (purpose <> "/credit", 1)]
    loyalty = if fanout > 0 then [("loyalty/debit", 1), ("loyalty/credit", fromIntegral fanout)] else []
    expected :: Map Text Int64
    expected = Map.fromList case row.status of
      "completed" -> pair "hold" <> pair "capture" <> loyalty
      "rejected" -> pair "hold" <> pair "refund"
      "expired" -> pair "hold" <> pair "refund"
      _ -> [("terminal/state", 1)]

-- | I2 in the warehouse: a reservation iff fulfilment was requested, then
-- exactly one of commit or release; a refusal moves no stock.
judgeWarehouseEffects :: EffectRow -> Judgement
judgeWarehouseEffects row =
  single (if expected == actual then [] else ["stock movements differ from the fulfilment's outcome"]) (object ["orderId" .= row.orderId, "status" .= row.status, "movements" .= actual, "expected" .= expected])
  where
    actual = Map.filter (/= 0) row.movements
    pair purpose = [(purpose <> "/debit", 1), (purpose <> "/credit", 1)]
    expected :: Map Text Int64
    expected = Map.fromList case row.status of
      "shipped" -> pair "reserve" <> pair "commit"
      "expired" -> pair "reserve" <> pair "release"
      "refused" -> []
      _ -> [("terminal/state", 1)]

data SeededLedgers = SeededLedgers
  { moneyTotal :: !Int64,
    poolOpening :: !Int64,
    stockPerSku :: !Int64,
    skus :: !Int,
    fanout :: !Int
  }
  deriving stock (Eq, Show)

-- | I3 in the shop: money is conserved, escrow is empty, the merchant holds
-- exactly the captured amounts, and the pool paid exactly the referrers.
judgeShopConservation :: SeededLedgers -> ShopTotals -> Judgement
judgeShopConservation seeded totals =
  foldMap
    (\(name, observed, wanted) -> single [name | observed /= wanted] (object ["check" .= name, "observed" .= observed, "expected" .= wanted]))
    [ ("money-total", totals.total, seeded.moneyTotal),
      ("escrow-empty", totals.escrow, 0),
      ("merchant-holds-captures", totals.merchant, totals.capturedAmount),
      ("pool-paid-bonuses", totals.pool, seeded.poolOpening - payout),
      ("referrers-received-bonuses", totals.loyaltyAccounts, payout)
    ]
  where
    payout = fromIntegral seeded.fanout * totals.bonusUnits

-- | I3 in the warehouse: per SKU the buckets sum to the seeded stock, nothing
-- stays reserved, the shipped bucket equals the shipped fulfilments, every
-- seeded SKU is present, and the total shipped equals the quantity of
-- completed orders in the shop.
judgeWarehouseConservation :: SeededLedgers -> Int64 -> [SkuStock] -> Judgement
judgeWarehouseConservation seeded completedQuantity stocks =
  foldMap perSku stocks
    <> single ["seeded SKU missing" | length stocks /= seeded.skus] (object ["skus" .= length stocks, "expected" .= seeded.skus])
    <> single ["shipped quantity differs from completed orders" | shippedTotal /= completedQuantity] (object ["shipped" .= shippedTotal, "completed" .= completedQuantity])
  where
    shippedTotal = sum [stock.shippedFulfilments | stock <- stocks]
    perSku stock =
      single
        ( ["stock not conserved" | stock.available + stock.reserved + stock.shipped /= seeded.stockPerSku]
            <> ["stock left reserved" | stock.reserved /= 0]
            <> ["shipped bucket differs from shipped fulfilments" | stock.shipped /= stock.shippedFulfilments]
        )
        (object ["sku" .= stock.sku, "available" .= stock.available, "reserved" .= stock.reserved, "shipped" .= stock.shipped, "shippedFulfilments" .= stock.shippedFulfilments])

-- | I4: nothing is left behind.
judgeOrphans :: Text -> [(Text, Int64)] -> Judgement
judgeOrphans context counts = foldMap (\(name, count) -> single [name | count /= 0] (object ["context" .= context, "kind" .= name, "count" .= count])) counts

seededLedgers :: SystemConfig -> SeededLedgers
seededLedgers config =
  SeededLedgers
    { moneyTotal = fromIntegral customerCount * openingCustomerBalance + openingLoyaltyPool,
      poolOpening = openingLoyaltyPool,
      stockPerSku = openingStock,
      skus = skuCount,
      fanout = min config.routerFanout (customerCount - 1)
    }

-- | Evaluate I1 to I4 against both databases after quiescence. Every
-- invariant is read from durable state, a page at a time.
verifyEndToEnd :: SystemConfig -> ContextStore -> ContextStore -> IO [Verdict]
verifyEndToEnd config shop warehouse = do
  let seeded = seededLedgers config
  terminal <- pagedMerge shop warehouse
  shopEffects <- pagedFold shop shopEffectPageTx (\row -> row.orderId) (judgeShopEffects seeded.fanout)
  warehouseEffects <- pagedFold warehouse warehouseEffectPageTx (\row -> row.orderId) judgeWarehouseEffects
  shopLetters <- orThrow =<< runSql shop deadLetterExamplesTx
  warehouseLetters <- orThrow =<< runSql warehouse deadLetterExamplesTx
  totals <- orThrow =<< runSql shop shopTotalsTx
  stocks <- orThrow =<< runSql warehouse skuStockTx
  shopOrphans <- orThrow =<< runSql shop (orphanCountsTx "shop" False)
  warehouseOrphans <- orThrow =<< runSql warehouse (orphanCountsTx "warehouse" True)
  let letters (count, rows) = Judgement 1 count (take 20 rows)
      effects = shopEffects <> warehouseEffects <> letters shopLetters <> letters warehouseLetters
      conservation = judgeShopConservation seeded totals <> judgeWarehouseConservation seeded totals.completedQuantity stocks
      orphans = judgeOrphans "shop" shopOrphans <> judgeOrphans "warehouse" warehouseOrphans
  sequence
    [ verdictFor "terminal-exactly-once" "Every order has one placement and one terminal event, matched by the warehouse." terminal,
      verdictFor "effects-exactly-once" "Every order has exactly the ledger movements its outcome implies, with no dead-lettered dispatch." effects,
      verdictFor "conservation" "Money and stock are conserved in both contexts and agree across them." conservation,
      verdictFor "no-orphans" "No outbox, inbox, intake, workflow, timer, awakeable, queue or dead-letter work is left behind." orphans
    ]
  where
    orThrow = either (ioError . userError . show) pure

pageSize :: Int64
pageSize = 500

pagedMerge :: ContextStore -> ContextStore -> IO Judgement
pagedMerge shop warehouse = loop mempty "" "" [] [] False False
  where
    loop acc orderCursor fulfilmentCursor orders fulfilments ordersDone fulfilmentsDone = do
      (orders', orderCursor', ordersDone') <- refill shop orderOutcomePageTx orderCursor orders ordersDone
      (fulfilments', fulfilmentCursor', fulfilmentsDone') <- refill warehouse fulfilmentOutcomePageTx fulfilmentCursor fulfilments fulfilmentsDone
      let (judged, restOrders, restFulfilments) = mergeOutcomes ordersDone' fulfilmentsDone' orders' fulfilments'
          acc' = acc <> judged
      if null restOrders && null restFulfilments && ordersDone' && fulfilmentsDone'
        then pure acc'
        else loop acc' orderCursor' fulfilmentCursor' restOrders restFulfilments ordersDone' fulfilmentsDone'
    refill store page cursor buffered done
      | not (null buffered) || done = pure (buffered, cursor, done)
      | otherwise = do
          rows <- either (ioError . userError . show) pure =<< runSql store (page cursor pageSize)
          pure case reverse rows of
            [] -> ([], cursor, True)
            lastRow : _ -> (rows, lastRow.orderId, False)

pagedFold :: ContextStore -> (Text -> Int64 -> Tx.Transaction [row]) -> (row -> Text) -> (row -> Judgement) -> IO Judgement
pagedFold store page key judge = loop mempty ""
  where
    loop acc cursor = do
      rows <- either (ioError . userError . show) pure =<< runSql store (page cursor pageSize)
      case reverse rows of
        [] -> pure acc
        lastRow : _ -> loop (acc <> foldMap judge rows) (key lastRow)

verdictFor :: Text -> Text -> Judgement -> IO Verdict
verdictFor name description judgement = do
  now <- getCurrentTime
  pure
    Verdict
      { checker = name,
        invariant = name,
        cls = Contract,
        status = if judgement.violations == 0 then Held else Violated,
        reason = Nothing,
        summary = description,
        counts = Map.fromList [("examined", judgement.examined), ("violations", judgement.violations)],
        parameters = object [],
        counterExamples = judgement.examples,
        counterExamplesTruncated = judgement.violations > fromIntegral (length judgement.examples),
        inputs = [],
        replay = Nothing,
        checkedAt = now,
        durationMillis = 0
      }

-- | Doctor durable state after quiescence so that one invariant must fail.
-- Used only by sabotage controls, which prove that the SQL oracles see the
-- violations their pure judgements are unit-tested against.
data Sabotage = NoSabotage | DoubleCapture | StaleReadModel | PendingOutbox
  deriving stock (Eq, Show)

sabotageFrom :: Text -> Sabotage
sabotageFrom = \case
  "double-capture" -> DoubleCapture
  "stale-read-model" -> StaleReadModel
  "pending-outbox" -> PendingOutbox
  _ -> NoSabotage

applySabotage :: Sabotage -> ContextStore -> IO ()
applySabotage sabotage shop = case sabotage of
  NoSabotage -> pure ()
  DoubleCapture ->
    run
      "WITH c AS (SELECT * FROM ledger.entries WHERE transfer_ref LIKE '%:capture' AND direction = 'credit' ORDER BY transfer_ref LIMIT 1), \
      \i AS (INSERT INTO ledger.entries (event_id, account_id, transfer_ref, direction, counterparty, amount, global_position) SELECT gen_random_uuid(), account_id, transfer_ref, direction, counterparty, amount, global_position FROM c RETURNING account_id, amount) \
      \UPDATE kenshou_keiro.account_balance b SET balance = b.balance + i.amount FROM i WHERE b.account_id = i.account_id"
  StaleReadModel -> run "UPDATE shop.orders SET status = 'placed' WHERE order_id = (SELECT min(order_id) FROM shop.orders)"
  PendingOutbox -> run "UPDATE keiro.keiro_outbox SET status = 'pending' WHERE outbox_id = (SELECT outbox_id FROM keiro.keiro_outbox LIMIT 1)"
  where
    run sql = runSql shop (Tx.sql sql) >>= either (ioError . userError . show) pure
