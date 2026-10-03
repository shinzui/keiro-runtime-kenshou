module Kenshou.Suite.Runtime.System.Shop
  ( PaymentStep (..),
    PaymentInput (..),
    LoyaltyInput (..),
    paymentManager,
    loyaltyRouter,
    shopProducer,
    loyaltyBonus,
    handleShopDelivery,
    OrderCommandKind (..),
    shopIntakeCommand,
    dispatchOrderCommand,
    seedShop,
    customerAccount,
    loyaltyAccount,
    escrowAccount,
    merchantAccount,
    loyaltyPoolAccount,
    referralPairs,
    openingCustomerBalance,
    openingLoyaltyPool,
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Effectful ((:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiki.Core (HsPred)
import Keiro.Codec (Codec (..))
import Keiro.Command (RunCommandOptions, defaultRunCommandOptions)
import Keiro.Outbox (IntegrationProducer (..), ProducerEnqueueOutcome (..), enqueueProducerEventTx, mkIntegrationProducer)
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..), ProcessManager (..), ProcessManagerAction (..), ProcessManagerResult (..), runProcessManagerOnce)
import Keiro.Router (Router (..), RouterResult (..), runRouterOnce)
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), ShopMessage (..), TopicPrefix (..), WarehouseMessage (..))
import Kenshou.Suite.Runtime.System.Dispatch (Dispatched (..), dispatchOnce)
import Kenshou.Suite.Runtime.System.Ledger (AccountCommand, AccountEvent, AccountId (..), LedgerPhi, LedgerRegs, LedgerState, accountCommandStream, accountStream, creditTransfer, debitTransfer, ensureLedgerReadModels, ledgerEventStream, ledgerProjections, openAccount, transferRef)
import Kenshou.Suite.Runtime.System.Order
import Kenshou.Suite.Runtime.System.SagaLog (ObserveSagaData (..), SagaCommand (..), SagaEvent, SagaState, sagaEventStream, sagaStream)
import Kenshou.Suite.Runtime.System.Schema (IntakeRow (..), ensureShopTables, insertReferralsTx, orderProjection, referrersTx)
import Kenshou.Suite.Runtime.System.Store (ContextEff, ContextStore, deterministicEventId, runContext, runContextOrThrow)
import Kenshou.Suite.Runtime.System.Wire (shopEventDraft)
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Types (EventId (..), RecordedEvent (..))

-- Accounts of the shop's money ledger.

customerAccount :: CustomerId -> AccountId
customerAccount (CustomerId customer) = AccountId customer

loyaltyAccount :: Text -> AccountId
loyaltyAccount referrer = AccountId ("loyalty-" <> referrer)

escrowAccount, merchantAccount, loyaltyPoolAccount :: AccountId
escrowAccount = AccountId "escrow"
merchantAccount = AccountId "merchant"
loyaltyPoolAccount = AccountId "loyalty-pool"

openingCustomerBalance, openingLoyaltyPool :: Int64
openingCustomerBalance = 100000000
openingLoyaltyPool = 1000000000

-- | Each customer is referred by the next @fanout@ customers, so every order
-- that completes credits exactly @fanout@ loyalty accounts.
referralPairs :: Int -> Int -> [(Text, Text)]
referralPairs customers fanout =
  [ (customerName n, customerName ((n + k) `mod` customers))
  | n <- [0 .. customers - 1],
    k <- [1 .. min fanout (customers - 1)]
  ]
  where
    customerName n = "customer-" <> Text.pack (show n)

loyaltyBonus :: Int64 -> Int64
loyaltyBonus amount = max 1 (amount `div` 100)

data PaymentStep = PaymentHold | PaymentCapture | PaymentRefund
  deriving stock (Eq, Show)

data PaymentInput = PaymentInput
  { sourceEventId :: !Text,
    orderId :: !OrderId,
    step :: !PaymentStep,
    customer :: !CustomerId,
    amountCents :: !Int64
  }
  deriving stock (Eq, Show)

-- | The payment process manager. Its own stream is the one-state saga log;
-- every reaction is a pair of ledger commands under the order's reference.
paymentManager :: ProcessManager PaymentInput (HsPred '[] SagaCommand) '[] SagaState SagaCommand SagaEvent LedgerPhi LedgerRegs LedgerState AccountCommand AccountEvent
paymentManager =
  ProcessManager
    { name = "shop-payment",
      correlate = \input -> orderText input.orderId,
      eventStream = sagaEventStream,
      streamFor = sagaStream "shopPayment" . OrderId,
      targetEventStream = ledgerEventStream,
      targetProjections = ledgerProjections,
      handle = \input ->
        let customer = customerAccount input.customer
            movement purpose source destination =
              let reference = transferRef input.orderId purpose
               in [ PMCommand (accountCommandStream source) (ledger (debitTransfer source reference destination input.amountCents 0)),
                    PMCommand (accountCommandStream destination) (ledger (creditTransfer destination reference source input.amountCents))
                  ]
            (stage, commands) = case input.step of
              PaymentHold -> ("hold", movement "hold" customer escrowAccount)
              PaymentCapture -> ("capture", movement "capture" escrowAccount merchantAccount)
              PaymentRefund -> ("refund", movement "refund" escrowAccount customer)
         in ProcessManagerAction
              { command = ObserveSaga (ObserveSagaData input.orderId stage input.sourceEventId),
                commands,
                timers = []
              }
    }

data LoyaltyInput = LoyaltyInput
  { orderId :: !OrderId,
    customer :: !CustomerId,
    amountCents :: !Int64
  }
  deriving stock (Eq, Show)

-- | The loyalty router resolves its targets from the seeded referral table at
-- dispatch time. It holds no state; its deterministic identifiers come from
-- the router name, the order and the source event.
loyaltyRouter :: (Store :> es) => Router LoyaltyInput LedgerPhi LedgerRegs LedgerState AccountCommand AccountEvent es
loyaltyRouter =
  Router
    { name = "shop-loyalty",
      key = \input -> orderText input.orderId,
      resolve = \input -> do
        referrers <- runTransaction (referrersTx input.customer)
        let bonus = loyaltyBonus input.amountCents
            reference = transferRef input.orderId "loyalty"
            total = bonus * fromIntegral (length referrers)
        pure $
          if null referrers
            then []
            else
              PMCommand (accountCommandStream loyaltyPoolAccount) (ledger (debitTransfer loyaltyPoolAccount reference (AccountId "loyalty-referrers") total 0))
                : [ PMCommand (accountCommandStream (loyaltyAccount referrer)) (ledger (creditTransfer (loyaltyAccount referrer) reference loyaltyPoolAccount bonus))
                  | referrer <- referrers
                  ],
      targetEventStream = ledgerEventStream,
      targetProjections = ledgerProjections
    }

shopProducer :: IntegrationProducer OrderEvent
shopProducer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "shop-orders" "shop" "shop" (\_ _ -> Nothing)))

-- | One idempotent handler per order event: the payment manager, the loyalty
-- router and the integration producer. Every write is keyed by a
-- deterministic identifier, so a redelivered event appends nothing new.
handleShopDelivery :: ContextStore -> TopicPrefix -> RecordedEvent -> IO (Either Text ())
handleShopDelivery context prefix recorded = case orderCodec.decode recorded.eventType recorded.payload of
  Left problem -> pure (Left ("undecodable order event: " <> problem))
  Right event -> do
    outcome <- runContext context case event of
      OrderPlaced d -> do
        payment <- runPayment (PaymentInput sourceId d.orderId PaymentHold d.customer d.amountCents)
        enqueued <-
          runTransaction
            ( enqueueProducerEventTx
                shopProducer
                recorded
                0
                (shopEventDraft prefix recorded.createdAt (OrderPlacedV1 d.orderId d.customer d.sku d.quantity d.amountCents d.slowPick))
            )
        pure (payment <> producerProblems enqueued)
      OrderCompleted d -> withOrder d.orderId \customer amount -> do
        payment <- runPayment (PaymentInput sourceId d.orderId PaymentCapture customer amount)
        loyalty <- runRouterOnce defaultRunCommandOptions loyaltyRouter recorded (LoyaltyInput d.orderId customer amount)
        pure (payment <> commandProblems loyalty.commandResults)
      OrderRejected d -> withOrder d.orderId \customer amount -> runPayment (PaymentInput sourceId d.orderId PaymentRefund customer amount)
      OrderExpired d -> withOrder d.orderId \customer amount -> runPayment (PaymentInput sourceId d.orderId PaymentRefund customer amount)
    pure case outcome of
      Left storeError -> Left (Text.pack (show storeError))
      Right [] -> Right ()
      Right problems -> Left (Text.intercalate "; " problems)
  where
    sourceId = let EventId value = recorded.eventId in UUID.toText value
    runPayment input = do
      result <- runProcessManagerOnce defaultRunCommandOptions paymentManager recorded input
      pure case result of
        Left problem -> ["payment manager state: " <> Text.pack (show problem)]
        Right value -> commandProblems value.commandResults
    withOrder order continue = do
      found <- runTransaction (orderDetailsTx order)
      case found of
        Nothing -> pure ["order read model has no row for " <> orderText order]
        Just (customer, amount) -> continue (CustomerId customer) amount

commandProblems :: [PMCommandResult target] -> [Text]
commandProblems results = [Text.pack (show stream) <> ": " <> Text.pack (show problem) | PMCommandFailed stream problem <- results]

producerProblems :: ProducerEnqueueOutcome -> [Text]
producerProblems = \case
  ProducerIdentityConflict identity fields -> ["producer identity conflict " <> Text.pack (show identity) <> " " <> Text.pack (show fields)]
  _ -> []

orderDetailsTx :: OrderId -> Tx.Transaction (Maybe (Text, Int64))
orderDetailsTx (OrderId order) =
  Tx.statement order $
    Statement.preparable
      "SELECT customer, amount_cents FROM shop.orders WHERE order_id = $1"
      (Encoders.param (Encoders.nonNullable Encoders.text))
      (Decoders.rowMaybe ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

data OrderCommandKind = CommandComplete | CommandReject | CommandExpire
  deriving stock (Eq, Show)

-- | Translate one intake row (written by the inbox transaction) into the
-- order command it stands for.
shopIntakeCommand :: IntakeRow -> Either Text OrderCommand
shopIntakeCommand row = case row.kind of
  "fulfilment.shipped.v1" -> Right (CompleteOrder (CompleteOrderData order))
  "fulfilment.refused.v1" -> Right (RejectOrder (RejectOrderData order (reasonOf row.payload)))
  "fulfilment.expired.v1" -> Right (ExpireOrder (ExpireOrderData order))
  other -> Left ("unexpected shop intake kind " <> other)
  where
    order = OrderId row.orderId
    reasonOf value = case Aeson.fromJSON value of
      Aeson.Success FulfilmentRefusedV1 {reason} -> reason
      _ -> "refused"

-- | The intake row's identity determines the command identifier, so a crash
-- between the inbox commit and the command append is repaired by a replay.
dispatchOrderCommand :: RunCommandOptions -> IntakeRow -> OrderCommand -> ContextEff Dispatched
dispatchOrderCommand options row command =
  dispatchOnce options orderEventStream (orderStream (OrderId row.orderId)) (deterministicEventId ("shop-intake/" <> row.messageId)) command [orderProjection]

-- | Create the application tables, open every account with its opening
-- balance and record the referral graph. Safe to repeat.
seedShop :: ContextStore -> Int -> Int -> IO ()
seedShop context customers fanout = do
  runContextOrThrow context (ensureLedgerReadModels >> ensureShopTables)
  let accounts =
        [(AccountId ("customer-" <> Text.pack (show n)), openingCustomerBalance) | n <- [0 .. customers - 1]]
          <> [(AccountId ("loyalty-customer-" <> Text.pack (show n)), 0) | n <- [0 .. customers - 1]]
          <> [(escrowAccount, 0), (merchantAccount, 0), (loyaltyPoolAccount, openingLoyaltyPool)]
  results <- forM accounts \(account@(AccountId name), balance) ->
    runContextOrThrow context $
      dispatchOnce defaultRunCommandOptions ledgerEventStream (accountStream account) (deterministicEventId ("open/" <> name)) (ledger (openAccount account balance)) (ledgerProjections (accountCommandStream account))
  forM_ results \case
    DispatchAppended -> pure ()
    DispatchDuplicate -> pure ()
    other -> ioError (userError ("could not open shop account: " <> show other))
  runContextOrThrow context (runTransaction (insertReferralsTx (referralPairs customers fanout)))

ledger :: (Show problem) => Either problem AccountCommand -> AccountCommand
ledger = either (\problem -> error ("ledger command outside the generator's guarantees: " <> show problem)) id

orderText :: OrderId -> Text
orderText (OrderId value) = value
