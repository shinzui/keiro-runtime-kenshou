module Main (main) where

import Control.Exception (evaluate)
import Data.Aeson (toJSON)
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
import Kenshou.Suite.Runtime.Driver qualified as Driver
import Kenshou.Suite.Runtime.Knobs (runtimeKnobs, systemConfigFrom)
import Kenshou.Suite.Runtime.Oracle.Pure qualified as Oracle
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
import Test.Hspec

main :: IO ()
main = hspec do
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
      Oracle.checkOrderFacts completedOrder `shouldBe` []

    it "rejects a doctored double capture while preserving the terminal outcome" do
      let doubled = completedOrder {Oracle.ledgerLegCounts = Map.insert Oracle.CaptureCredit 2 completedOrder.ledgerLegCounts}
      Oracle.checkOrderFacts doubled `shouldBe` [Oracle.LedgerLegCount Oracle.CaptureCredit 1 2]

completedOrder :: Oracle.OrderFacts
completedOrder =
  Oracle.OrderFacts
    { shopTerminals = [OrderCompleted],
      warehouseTerminals = [FulfilmentShipped],
      ledgerLegCounts = Map.fromList [(leg, count leg) | leg <- [minBound .. maxBound]],
      loyaltyFanout = 3
    }
  where
    count Oracle.LoyaltyCredit = 3
    count leg
      | leg `elem` [Oracle.RefundDebit, Oracle.RefundCredit, Oracle.ReleaseDebit, Oracle.ReleaseCredit] = 0
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
