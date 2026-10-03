module Main (main) where

import Control.Exception (evaluate)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (NoTimestamp))
import Kafka.Types (PartitionId (..), TopicName (..), headersFromList)
import Keiro.Codec (Codec (..))
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox qualified
import Kenshou.Core.Id (mkSeed)
import Kenshou.Core.Knob (resolveKnobs)
import Kenshou.Suite.Runtime.Correctness.OrderFlow qualified as OrderFlow
import Kenshou.Suite.Runtime.Driver qualified as Driver
import Kenshou.Suite.Runtime.Knobs (runtimeKnobs, systemConfigFrom)
import Kenshou.Suite.Runtime.Oracle qualified as Oracle
import Kenshou.Suite.Runtime.Oracle.Ops qualified as OpsOracle
import Kenshou.Suite.Runtime.Oracle.Pure qualified as PureOracle
import Kenshou.Suite.Runtime.Oracle.Sql qualified as Sql
import Kenshou.Suite.Runtime.Oracle.Trace qualified as TraceOracle
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), ShopMessage (..), Sku (..), TopicPrefix (..), WarehouseMessage (..), shopTopic, warehouseTopic)
import Kenshou.Suite.Runtime.System.Fulfilment qualified as Fulfilment
import Kenshou.Suite.Runtime.System.KafkaBridge qualified as KafkaBridge
import Kenshou.Suite.Runtime.System.Ledger qualified as Ledger
import Kenshou.Suite.Runtime.System.Model
import Kenshou.Suite.Runtime.System.Order qualified as Order
import Kenshou.Suite.Runtime.System.SagaLog qualified as SagaLog
import Kenshou.Suite.Runtime.System.Schema qualified as Schema
import Kenshou.Suite.Runtime.System.Shop qualified as Shop
import Kenshou.Suite.Runtime.System.Warehouse qualified as Warehouse
import Kenshou.Suite.Runtime.System.Wire qualified as Wire
import Kenshou.Suite.Runtime.Telemetry (SpanRecord (..))
import Test.Hspec

main :: IO ()
main = hspec do
  describe "trace continuity controls (I7)" do
    let span' process name trace spanId parent = SpanRecord {process, name, kind = "Consumer", traceId = trace, spanId, parentSpanId = parent, attributes = Map.empty, startNs = 0, endNs = 1}
        send = span' "runtime/a-publisher-0" (TraceOracle.sendSpanName "t") "tr" "s1" (Just "d1")
        consume = span' "runtime/b-consumer-0" (TraceOracle.consumerSpanName "t") "tr" "c1" (Just "s1")
        dispatch = span' "runtime/a-dispatch-0" "dispatch shop-dispatch" "tr" "d1" Nothing
        hop spans = (TraceOracle.judgeKafkaHop "t" (TraceOracle.indexSpans spans) spans).violations
    it "accepts a consumer span whose parent is the topic's send span in another process" do
      hop [dispatch, send, consume] `shouldBe` 0
    it "fails a severed traceparent: the consumer's parent is missing or is not a send span" do
      hop [dispatch, consume] `shouldBe` 1
      hop [dispatch, send, consume {parentSpanId = Just "d1"}] `shouldBe` 1
      hop [dispatch, send, consume {parentSpanId = Nothing}] `shouldBe` 1
    it "fails a pick span that does not continue another process's span" do
      let pick = span' "runtime/b-jobs-0" TraceOracle.pickSpanName "tr" "p1" (Just "d1")
          judge spans = (TraceOracle.judgeJobHop (TraceOracle.indexSpans spans) spans).violations
      judge [dispatch, pick] `shouldBe` 0
      judge [pick] `shouldBe` 1
      judge [dispatch {process = "runtime/b-jobs-0"}, pick] `shouldBe` 1
    it "fails outbox rows without a traceparent" do
      (TraceOracle.judgeOutboxTrace "shop" (10, 0, [])).violations `shouldBe` 0
      (TraceOracle.judgeOutboxTrace "shop" (10, 2, ["a", "b"])).violations `shouldBe` 2
    it "judges a journey single only when both streams share one trace" do
      let command name trace = span' "runtime/a-dispatch-0" name trace (name <> trace) Nothing
          journeys spans = (TraceOracle.judgeJourneys ["o-1"] spans).violations
      journeys [command "order-o-1" "tr", command "fulfilment-o-1" "tr"] `shouldBe` 0
      journeys [command "order-o-1" "tr", command "fulfilment-o-1" "other"] `shouldBe` 1
      journeys [command "order-o-1" "tr"] `shouldBe` 1
  describe "keiro-ops cross-check controls (I8)" do
    let backlog n = object ["metric" .= ("outbox_backlog" :: Text), "count" .= (n :: Int)]
        agreement reported stored = (OpsOracle.judgeOpsAgreement "outbox-backlog" Schema.Warehouse reported stored).violations
    it "accepts a console count equal to the SQL count" do
      agreement (OpsOracle.extractCount (backlog 3)) ["3"] `shouldBe` 0
    it "fails on an altered backlog count" do
      agreement (OpsOracle.extractCount (backlog 4)) ["3"] `shouldBe` 1
    it "fails when the console failed or printed something else" do
      agreement (Left "keiro-ops exited 1") ["3"] `shouldBe` 1
      agreement (OpsOracle.extractCount (object ["metric" .= ("outbox_backlog" :: Text)])) ["3"] `shouldBe` 1
    it "compares listings as multisets, independent of order" do
      let workflows = toJSON [object ["workflow_name" .= ("fulfilment" :: Text), "workflow_id" .= ("o-" <> show i), "status" .= ("suspended" :: Text)] | i <- [1 :: Int, 2]]
      OpsOracle.extractWorkflows workflows `shouldBe` Right ["fulfilment/o-1/suspended", "fulfilment/o-2/suspended"]
      agreement (OpsOracle.extractWorkflows workflows) ["fulfilment/o-2/suspended", "fulfilment/o-1/suspended"] `shouldBe` 0
      agreement (OpsOracle.extractWorkflows workflows) ["fulfilment/o-1/suspended"] `shouldBe` 1
    it "reads shard ownership with unowned buckets and shard-count groups" do
      let status = object ["subscription" .= ("shop-dispatch" :: Text), "shard_counts" .= [object ["shard_count" .= (2 :: Int), "rows" .= (2 :: Int)]], "ownership" .= [object ["bucket" .= (0 :: Int), "owner" .= ("6f1c0e4e-0000-4000-8000-000000000001" :: Text)], object ["bucket" .= (1 :: Int), "owner" .= Null]]]
      OpsOracle.extractShardStatus status `shouldBe` Right ["bucket/0/6f1c0e4e-0000-4000-8000-000000000001", "bucket/1/unowned", "shards/2/2"]
    it "reads subscription checkpoints with the captured store position" do
      let inventory = object ["store_position" .= (42 :: Int), "visible_store_head" .= (42 :: Int), "checkpoints" .= [object ["subscription" .= ("shop-dispatch" :: Text), "member" .= (3 :: Int), "checkpoint_position" .= (40 :: Int)]]]
      OpsOracle.extractCheckpoints inventory `shouldBe` Right ["store/42", "checkpoint/shop-dispatch/3/40"]
    it "reads DLQ message ids in the derived-Show rendering and flags that shape" do
      OpsOracle.parseDlqMessageId (String "MessageId {unMessageId = 7}") `shouldBe` Right "7"
      OpsOracle.parseDlqMessageId (Number 7) `shouldBe` Right "7"
      OpsOracle.parseDlqMessageId (String "MessageId {unMessageId = }") `shouldSatisfy` either (const True) (const False)
      length (OpsOracle.dlqShapeProblems (toJSON [object ["dlq_message_id" .= ("MessageId {unMessageId = 7}" :: Text)]])) `shouldBe` 1
      OpsOracle.dlqShapeProblems (toJSON [object ["dlq_message_id" .= (7 :: Int)]]) `shouldBe` []
    it "declares the compared commands for both contexts" do
      length OpsOracle.opsChecks `shouldBe` 13
  describe "end-to-end oracle controls" do
    let outcome order first terminals kind status quantity = Sql.StreamOutcome order first terminals kind (Just status) (Just quantity)
        completedOrder = outcome "o-1" 1 1 (Just "OrderCompleted") "completed" 2
        shippedFulfilment = outcome "o-1" 1 1 (Just "FulfilmentShipped") "shipped" 2
        violations judgement = judgement.violations
        seeded = Oracle.SeededLedgers {moneyTotal = 1000, poolOpening = 100, stockPerSku = 50, skus = 1, fanout = 2}
        totals = Sql.ShopTotals {total = 1000, escrow = 0, merchant = 300, pool = 96, loyaltyAccounts = 4, capturedAmount = 300, completedOrders = 1, completedQuantity = 2, bonusUnits = 2}
        movements = Map.fromList [("hold/debit", 1), ("hold/credit", 1), ("capture/debit", 1), ("capture/credit", 1), ("loyalty/debit", 1), ("loyalty/credit", 2)]
    it "accepts a matched, single-terminal pair" do
      violations (Oracle.judgePair (Just completedOrder) (Just shippedFulfilment)) `shouldBe` 0
    it "fails terminal-exactly-once when a terminal event is deleted" do
      violations (Oracle.judgePair (Just completedOrder {Sql.terminalEvents = 0, Sql.terminalKind = Nothing}) (Just shippedFulfilment)) `shouldBe` 1
    it "fails terminal-exactly-once on a second terminal event, a mismatch or a missing side" do
      violations (Oracle.judgePair (Just completedOrder {Sql.terminalEvents = 2}) (Just shippedFulfilment)) `shouldBe` 1
      violations (Oracle.judgePair (Just completedOrder) (Just shippedFulfilment {Sql.terminalKind = Just "FulfilmentExpired", Sql.readModelStatus = Just "expired"})) `shouldBe` 1
      violations (Oracle.judgePair (Just completedOrder) Nothing) `shouldBe` 1
      violations (Oracle.judgePair (Just completedOrder {Sql.readModelStatus = Just "placed"}) (Just shippedFulfilment)) `shouldBe` 1
    it "merge-joins pages and judges unmatched tails only once a side is exhausted" do
      let (pending, restOrders, _) = Oracle.mergeOutcomes False False [completedOrder, completedOrder {Sql.orderId = "o-2"}] [shippedFulfilment]
      (pending.examined, length restOrders) `shouldBe` (1, 1)
      let (finished, _, _) = Oracle.mergeOutcomes False True [completedOrder {Sql.orderId = "o-2"}] []
      violations finished `shouldBe` 1
    it "fails effects-exactly-once and conservation on a doctored second capture" do
      let row = Sql.EffectRow "o-1" "completed" movements
      violations (Oracle.judgeShopEffects 2 row) `shouldBe` 0
      violations (Oracle.judgeShopEffects 2 row {Sql.movements = Map.insert "capture/credit" 2 movements}) `shouldBe` 1
      violations (Oracle.judgeShopConservation seeded totals) `shouldBe` 0
      violations (Oracle.judgeShopConservation seeded totals {Sql.merchant = 600, Sql.total = 1300}) `shouldBe` 2
    it "fails warehouse effects and conservation on doctored stock" do
      let stock = Sql.SkuStock "sku-1" 48 0 2 2
      violations (Oracle.judgeWarehouseEffects (Sql.EffectRow "o-1" "refused" Map.empty)) `shouldBe` 0
      violations (Oracle.judgeWarehouseEffects (Sql.EffectRow "o-1" "refused" (Map.fromList [("reserve/debit", 1)]))) `shouldBe` 1
      violations (Oracle.judgeWarehouseConservation seeded 2 [stock]) `shouldBe` 0
      violations (Oracle.judgeWarehouseConservation seeded 2 [stock {Sql.reserved = 1}]) `shouldBe` 1
      violations (Oracle.judgeWarehouseConservation seeded 4 [stock]) `shouldBe` 1
    it "fails no-orphans on a pending outbox row" do
      violations (Oracle.judgeOrphans "shop" [("outbox-unsent", 0), ("inbox-unfinished", 0)]) `shouldBe` 0
      violations (Oracle.judgeOrphans "shop" [("outbox-unsent", 1), ("inbox-unfinished", 0)]) `shouldBe` 1
    it "fails checkpoints-monotonic on a decreased checkpoint" do
      let key = Sql.CheckpointKey "shop-dispatch" 0 1
          (marks, first) = Oracle.judgeCheckpointSample "shop" Map.empty [(key, 10)]
          (marks', advanced) = Oracle.judgeCheckpointSample "shop" marks [(key, 12)]
          (_, decreased) = Oracle.judgeCheckpointSample "shop" marks' [(key, 11)]
      (violations first, violations advanced, violations decreased) `shouldBe` (0, 0, 1)
    it "predicts the outcome mix from the seed alone" do
      let seed = either (error . show) id (mkSeed 42)
          config = (systemConfigFrom (either (error . show) id (resolveKnobs runtimeKnobs []))) {orders = 600, refuseFraction = 0.2, expireFraction = 0.1}
      OrderFlow.predictedMix seed config `shouldBe` Map.fromList [("completed", 432), ("expired", 49), ("rejected", 119)]
  describe "reference system wiring" do
    it "accepts a keyless envelope only when the delivery path cannot expose the key" do
      let prefix = TopicPrefix "run-1"
          placed = OrderPlacedV1 (OrderId "order-1") (CustomerId "customer-1") (Sku "sku-1") 2 900 False
          keyless = fromDraftWith "order.placed.v1" Nothing (Wire.shopEventDraft prefix (posixSecondsToUTCTime 0) placed)
      Wire.decodeShopEventWith Wire.KeyUnavailable prefix keyless `shouldBe` Right placed
      Wire.decodeShopEvent prefix keyless `shouldBe` Left (Wire.UnexpectedKey Nothing)
      Wire.decodeShopEventWith Wire.KeyUnavailable prefix (fromDraftWith "order.placed.v1" (Just "other") (Wire.shopEventDraft prefix (posixSecondsToUTCTime 0) placed))
        `shouldBe` Left (Wire.UnexpectedKey (Just "other"))
    it "derives every order from the seed and partitions them across drivers" do
      let seed = either (error . show) id (mkSeed 42)
          config = (systemConfigFrom (either (error . show) id (resolveKnobs runtimeKnobs []))) {orders = 100, processesPerRole = 3, refuseFraction = 0.2, expireFraction = 0.1}
          orders = fmap (Driver.generateOrder seed config) [0 .. 99]
      fmap (Driver.generateOrder seed config) [0 .. 99] `shouldBe` orders
      concatMap (Driver.driverIndices 100 3) [0 .. 2] `shouldMatchList` [0 .. 99]
      all (\order -> order.quantity >= 1 && order.quantity <= 3 && order.amountCents >= 100) orders `shouldBe` True
      any (Warehouse.isDiscontinued . (.sku)) orders `shouldBe` True
      any (.slowPick) orders `shouldBe` True
      any (\order -> order.slowPick && Warehouse.isDiscontinued order.sku) orders `shouldBe` False
    it "decides refusal from the inbound message and the static catalogue alone" do
      let row sku = Schema.IntakeRow "m-1" "o-1" "order.placed.v1" (toJSON (OrderPlacedV1 (OrderId "o-1") (CustomerId "customer-1") (Sku sku) 2 900 False))
      Warehouse.warehouseIntakeCommand (row "discontinued-1") `shouldBe` Right (Fulfilment.RefuseFulfilment (Fulfilment.RefuseFulfilmentData (OrderId "o-1") "discontinued"))
      Warehouse.warehouseIntakeCommand (row "sku-1") `shouldBe` Right (Fulfilment.RequestFulfilment (Fulfilment.RequestFulfilmentData (OrderId "o-1") (Sku "sku-1") 2 False))
    it "maps each warehouse outcome to exactly one order command" do
      let row kind message = Schema.IntakeRow "m-1" "o-1" kind (toJSON message)
      Shop.shopIntakeCommand (row "fulfilment.shipped.v1" (FulfilmentShippedV1 (OrderId "o-1") (Sku "sku-1") 2)) `shouldBe` Right (Order.CompleteOrder (Order.CompleteOrderData (OrderId "o-1")))
      Shop.shopIntakeCommand (row "fulfilment.refused.v1" (FulfilmentRefusedV1 (OrderId "o-1") "discontinued")) `shouldBe` Right (Order.RejectOrder (Order.RejectOrderData (OrderId "o-1") "discontinued"))
      Shop.shopIntakeCommand (row "fulfilment.expired.v1" (FulfilmentExpiredV1 (OrderId "o-1"))) `shouldBe` Right (Order.ExpireOrder (Order.ExpireOrderData (OrderId "o-1")))
    it "gives every customer exactly fanout distinct referrers other than itself" do
      let pairs = Shop.referralPairs 50 3
      length pairs `shouldBe` 150
      all (uncurry (/=)) pairs `shouldBe` True
  describe "two-context public wire contract" do
    it "routes an order and a warehouse outcome by order key with versioned types" do
      let at = posixSecondsToUTCTime 0
          prefix = TopicPrefix "run-1"
          placed = OrderPlacedV1 (OrderId "order-1") (CustomerId "customer-1") (Sku "sku-1") 2 900 False
          shipped = FulfilmentShippedV1 (OrderId "order-1") (Sku "sku-1") 2
          shopDraft = Wire.shopEventDraft prefix at placed
          warehouseDraft = Wire.warehouseEventDraft prefix at shipped
          shopEvent = fromDraft shopDraft
          warehouseEvent = fromDraft warehouseDraft
      shopDraft.key `shouldBe` Just "order-1"
      warehouseDraft.key `shouldBe` Just "order-1"
      Wire.decodeShopEvent prefix shopEvent `shouldBe` Right placed
      Wire.decodeWarehouseEvent prefix warehouseEvent `shouldBe` Right shipped
      Wire.decodeWarehouseEvent prefix (fromDraftWithType "fulfilment.refused.v1" warehouseDraft)
        `shouldBe` Left (Wire.PayloadEventTypeMismatch "fulfilment.refused.v1")
      Wire.decodeShopEvent prefix (fromDraftWith "order.placed.v1" (Just "other-order") shopDraft)
        `shouldBe` Left (Wire.UnexpectedKey (Just "other-order"))

  describe "Kafka inbox wire decoding" do
    it "rejects missing payloads and malformed UTF-8 before an inbox receipt" do
      let at = posixSecondsToUTCTime 0
          record =
            ConsumerRecord
              { crTopic = TopicName "shop-events",
                crPartition = PartitionId 0,
                crOffset = Offset 7,
                crTimestamp = NoTimestamp,
                crHeaders = headersFromList [],
                crKey = Nothing,
                crValue = Nothing
              }
      KafkaBridge.decodeConsumerRecord record at `shouldBe` Left KafkaBridge.MissingKafkaPayload
      KafkaBridge.decodeConsumerRecord (record {crKey = Just "\xc3\x28", crValue = Just "{}"}) at
        `shouldBe` Left (KafkaBridge.InvalidKafkaKeyUtf8 "\xc3\x28")

  describe "outbox Kafka trace headers" do
    it "keeps the stored trace when no producer span is active" do
      let headers = [("traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"), ("keiro-message-id", "m-1")]
      KafkaBridge.liveTraceHeaders headers `shouldReturn` headers

  describe "run-scoped broker names" do
    it "uses the Kafka fixture's valid suffixes for both context topics" do
      shopTopic (TopicPrefix "run-1") `shouldBe` "run-1-shop-events"
      warehouseTopic (TopicPrefix "run-1") `shouldBe` "run-1-warehouse-events"

  describe "assembled-runtime terminal contract" do
    it "accepts one matching order and fulfilment completion" do
      advanceOrder OrderNotPlaced PlaceOrder `shouldBe` Right OrderPlaced
      advanceOrder OrderPlaced CompleteOrder `shouldBe` Right OrderCompleted
      advanceFulfilment FulfilmentNotRequested RequestFulfilment `shouldBe` Right FulfilmentRequested
      advanceFulfilment FulfilmentRequested ShipFulfilment `shouldBe` Right FulfilmentShipped
      matchingTerminal OrderCompleted FulfilmentShipped `shouldBe` True

    it "allows either shipping or expiry to win, then rejects the rival" do
      advanceFulfilment FulfilmentRequested ShipFulfilment `shouldBe` Right FulfilmentShipped
      advanceFulfilment FulfilmentShipped ExpireFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentShipped ExpireFulfilment)
      advanceFulfilment FulfilmentRequested ExpireFulfilment `shouldBe` Right FulfilmentExpired
      advanceFulfilment FulfilmentExpired ShipFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentExpired ShipFulfilment)
      matchingTerminal OrderCompleted FulfilmentExpired `shouldBe` False

    it "rejects every terminal command after an order outcome" do
      let terminal = [OrderCompleted, OrderRejected, OrderExpired]
          commands = [CompleteOrder, RejectOrder, ExpireOrder]
      and [either (const True) (const False) (advanceOrder phase action) | phase <- terminal, action <- commands] `shouldBe` True

    it "accepts direct refusal only before fulfilment is requested" do
      advanceFulfilment FulfilmentNotRequested RefuseFulfilment `shouldBe` Right FulfilmentRefused
      advanceFulfilment FulfilmentRequested RefuseFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentRequested RefuseFulfilment)
      matchingTerminal OrderRejected FulfilmentRefused `shouldBe` True

  describe "order event stream" do
    it "validates the Keiki transition graph" do
      _ <- evaluate Order.orderEventStream
      pure ()

    it "round-trips every event through its versioned codec" do
      let identifier = OrderId "order-1"
          events =
            [ Order.OrderPlaced (Order.OrderPlacedData identifier (CustomerId "customer-1") (Sku "sku-1") 2 900 False),
              Order.OrderCompleted (Order.OrderCompletedData identifier),
              Order.OrderRejected (Order.OrderRejectedData identifier "discontinued"),
              Order.OrderExpired (Order.OrderExpiredData identifier)
            ]
          codec = Order.orderCodec
      map (\event -> codec.decode (codec.eventType event) (codec.encode event)) events `shouldBe` map Right events

  describe "fulfilment event stream" do
    it "validates the Keiki transition graph" do
      _ <- evaluate Fulfilment.fulfilmentEventStream
      pure ()

    it "round-trips every event through its versioned codec" do
      let identifier = OrderId "order-1"
          events =
            [ Fulfilment.FulfilmentRequested (Fulfilment.FulfilmentRequestedData identifier (Sku "sku-1") 2 False),
              Fulfilment.FulfilmentRefused (Fulfilment.FulfilmentRefusedData identifier "discontinued"),
              Fulfilment.FulfilmentShipped (Fulfilment.FulfilmentShippedData identifier),
              Fulfilment.FulfilmentExpired (Fulfilment.FulfilmentExpiredData identifier)
            ]
          codec = Fulfilment.fulfilmentCodec
      map (\event -> codec.decode (codec.eventType event) (codec.encode event)) events `shouldBe` map Right events

  describe "saga observation stream" do
    it "validates its repeatable one-state graph" do
      _ <- evaluate SagaLog.sagaEventStream
      pure ()

    it "round-trips its versioned observation event" do
      let event = SagaLog.SagaObserved (SagaLog.SagaObservedData (OrderId "order-1") "reserved" "source-1")
          codec = SagaLog.sagaCodec
      codec.decode (codec.eventType event) (codec.encode event) `shouldBe` Right event

  describe "fixture ledger seam" do
    it "assigns one stable transfer reference per order purpose" do
      Ledger.transferRef (OrderId "order-1") "hold" `shouldBe` Ledger.TransferRef "order-1:hold"

    it "rejects invalid amounts before building fixture commands" do
      Ledger.openAccount (Ledger.AccountId "customer") (-1) `shouldBe` Left Ledger.NegativeOpeningBalance
      Ledger.debitTransfer (Ledger.AccountId "customer") (Ledger.TransferRef "order-1:hold") (Ledger.AccountId "escrow") 0 10 `shouldBe` Left Ledger.NonPositiveTransfer

  describe "independent order effect oracle" do
    it "accepts one fully balanced completed order" do
      PureOracle.checkOrderFacts completedOrder `shouldBe` []

    it "rejects a doctored double capture while preserving the terminal outcome" do
      let doubled = completedOrder {PureOracle.ledgerLegCounts = Map.insert PureOracle.CaptureCredit 2 completedOrder.ledgerLegCounts}
      PureOracle.checkOrderFacts doubled `shouldBe` [PureOracle.LedgerLegCount PureOracle.CaptureCredit 1 2]

completedOrder :: PureOracle.OrderFacts
completedOrder =
  PureOracle.OrderFacts
    { shopTerminals = [OrderCompleted],
      warehouseTerminals = [FulfilmentShipped],
      ledgerLegCounts = Map.fromList [(leg, count leg) | leg <- [minBound .. maxBound]],
      loyaltyFanout = 3
    }
  where
    count PureOracle.LoyaltyCredit = 3
    count leg
      | leg `elem` [PureOracle.RefundDebit, PureOracle.RefundCredit, PureOracle.ReleaseDebit, PureOracle.ReleaseCredit] = 0
      | otherwise = 1

fromDraft :: Keiro.Outbox.IntegrationEventDraft -> IntegrationEvent
fromDraft draft = fromDraftWithType draft.eventType draft

fromDraftWithType :: Text -> Keiro.Outbox.IntegrationEventDraft -> IntegrationEvent
fromDraftWithType wireType draft = fromDraftWith wireType draft.key draft

fromDraftWith :: Text -> Maybe Text -> Keiro.Outbox.IntegrationEventDraft -> IntegrationEvent
fromDraftWith wireType partitionKey draft =
  IntegrationEvent
    { messageId = "message-1",
      source = "shop",
      destination = draft.destination,
      key = partitionKey,
      eventType = wireType,
      schemaVersion = draft.schemaVersion,
      contentType = draft.contentType,
      schemaReference = draft.schemaReference,
      sourceEventId = draft.sourceEventId,
      sourceGlobalPosition = draft.sourceGlobalPosition,
      payloadBytes = draft.payloadBytes,
      occurredAt = draft.occurredAt,
      causationId = draft.causationId,
      correlationId = draft.correlationId,
      traceContext = draft.traceContext,
      attributes = draft.attributes
    }
