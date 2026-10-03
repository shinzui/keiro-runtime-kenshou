module Kenshou.Suite.Runtime.System.Intake
  ( IntakeOutcome (..),
    IntakeSide (..),
    shopIntakeSide,
    warehouseIntakeSide,
    consumeEnvelope,
    sweepIntake,
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value, toJSON)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Effectful (liftIO)
import Kafka.Types (TopicName (..))
import Keiro.Command (defaultRunCommandOptions)
import Keiro.Inbox (InboxDedupePolicy (..), InboxResult (..), runInboxDelegatedWithRetries, runInboxTransactionWithRetries)
import Keiro.Inbox.Types (DelegatedOutcome, KafkaDeliveryRef (..), mkDelegatedRetryContext)
import Keiro.Integration.Event (IntegrationEvent (..))
import Kenshou.Suite.Runtime.System.Config (InboxMode (..))
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..), ShopMessage (..), TopicPrefix, WarehouseMessage (..))
import Kenshou.Suite.Runtime.System.Dispatch (Dispatched (..), dispatchDelegated)
import Kenshou.Suite.Runtime.System.Fulfilment (fulfilmentEventStream, fulfilmentStream)
import Kenshou.Suite.Runtime.System.KafkaBridge (decodeEnvelope)
import Kenshou.Suite.Runtime.System.Order (orderEventStream, orderStream)
import Kenshou.Suite.Runtime.System.Schema (ContextName (..), IntakeRow (..), fulfilmentProjection, insertIntakeTx, insertPoisonTx, markIntakeDispatchedTx, orderProjection, pendingIntakeTx, undispatchedIntakeTx)
import Kenshou.Suite.Runtime.System.Shop (dispatchOrderCommand, shopIntakeCommand)
import Kenshou.Suite.Runtime.System.Store (ContextEff, ContextStore, runContext, runSql)
import Kenshou.Suite.Runtime.System.Warehouse (dispatchFulfilmentCommand, warehouseIntakeCommand)
import Kenshou.Suite.Runtime.System.Wire (KeyCheck (..), decodeShopEventWith, decodeWarehouseEventWith)
import Shibuya.Core.Types (Envelope)

data IntakeOutcome
  = -- | The delivery is durably handled (processed, duplicate or poison).
    IntakeAcknowledged !Text
  | -- | A database or dispatch failure that a retry may resolve.
    IntakeTransient !Text
  deriving stock (Eq, Show)

-- | What differs between the two consumers: which context stores the intake,
-- how the business message is decoded, and which command it becomes.
data IntakeSide = IntakeSide
  { context :: !ContextName,
    consumer :: !Text,
    decode :: TopicPrefix -> IntegrationEvent -> Either Text (Value, OrderId),
    dispatch :: IntakeRow -> IO (Either Text Dispatched),
    -- | Delegated mode: dispatch the command so that its first event is the
    -- receipt, given the inbox dedupe key and the message source.
    delegate :: IntakeRow -> Text -> Text -> ContextEff (Either Text (DelegatedOutcome ()))
  }

shopIntakeSide :: ContextStore -> IntakeSide
shopIntakeSide store =
  IntakeSide
    { context = Shop,
      consumer = "shop-consumer",
      decode = \prefix event -> case decodeWarehouseEventWith KeyUnavailable prefix event of
        Left problem -> Left (Text.pack (show problem))
        Right message -> Right (toJSON message, messageOrder message),
      dispatch = \row -> case shopIntakeCommand row of
        Left problem -> pure (Left problem)
        Right command -> either (Left . Text.pack . show) Right <$> runContext store (dispatchOrderCommand defaultRunCommandOptions row command),
      delegate = \row dedupe source -> case shopIntakeCommand row of
        Left problem -> pure (Left problem)
        Right command -> dispatchDelegated "shop-consumer" source dedupe "order-command" orderEventStream (orderStream (OrderId row.orderId)) command [orderProjection]
    }
  where
    messageOrder = \case
      FulfilmentShippedV1 {orderId} -> orderId
      FulfilmentRefusedV1 {orderId} -> orderId
      FulfilmentExpiredV1 {orderId} -> orderId

warehouseIntakeSide :: ContextStore -> IntakeSide
warehouseIntakeSide store =
  IntakeSide
    { context = Warehouse,
      consumer = "warehouse-consumer",
      decode = \prefix event -> case decodeShopEventWith KeyUnavailable prefix event of
        Left problem -> Left (Text.pack (show problem))
        Right message -> Right (toJSON message, message.orderId),
      dispatch = \row -> case warehouseIntakeCommand row of
        Left problem -> pure (Left problem)
        Right command -> either (Left . Text.pack . show) Right <$> runContext store (dispatchFulfilmentCommand defaultRunCommandOptions ("intake/" <> row.messageId) (OrderId row.orderId) command),
      delegate = \row dedupe source -> case warehouseIntakeCommand row of
        Left problem -> pure (Left problem)
        Right command -> dispatchDelegated "warehouse-consumer" source dedupe "fulfilment-command" fulfilmentEventStream (fulfilmentStream (OrderId row.orderId)) command [fulfilmentProjection]
    }

-- | Inbox intake with application-table idempotence. The inbox transaction
-- records the message identity and inserts the intake row atomically; the
-- command is then dispatched under an identifier derived from the intake row,
-- and the row is marked dispatched. A redelivery of an already-recorded
-- message re-attempts only an unfinished dispatch.
--
-- In delegated mode no inbox or intake row is written: the command's first
-- event carries a marker identifier derived from the delivery, and a
-- redelivery finds it in the target stream.
consumeEnvelope :: InboxMode -> Int -> IntakeSide -> ContextStore -> TopicPrefix -> TopicName -> Envelope (Maybe ByteString) -> UTCTime -> IO IntakeOutcome
consumeEnvelope mode attempt side store prefix topic envelope now = case decodeEnvelope topic envelope now of
  Left problem -> poison (-1) (-1) ("undecodable record: " <> Text.pack (show problem))
  Right (event, ref) -> case side.decode prefix event of
    Left problem -> poison (fromIntegral ref.partition) ref.offset ("unsupported message: " <> problem)
    Right (message, OrderId order) -> do
      let row = IntakeRow {messageId = event.messageId, orderId = order, kind = event.eventType, payload = message}
      recorded <- case mode of
        InboxTable -> runContext store (runInboxTransactionWithRetries Nothing 5 PreferIntegrationMessageId event (Just ref) (\_ -> insertIntakeTx side.context row))
        InboxDelegated -> case mkDelegatedRetryContext 5 (max 1 attempt) of
          Left problem -> pure (Right (Right (InboxHandlerFailed problem attempt)))
          Right retry ->
            runContext store $
              runInboxDelegatedWithRetries Nothing retry PreferIntegrationMessageId event (Just ref) \dedupe delivered ->
                side.delegate row dedupe delivered.source >>= either (liftIO . throwIO . userError . Text.unpack) pure
      case recorded of
        Left storeError -> pure (IntakeTransient ("inbox store failure: " <> Text.pack (show storeError)))
        Right (Left inboxError) -> poison (fromIntegral ref.partition) ref.offset ("inbox refused message: " <> Text.pack (show inboxError))
        Right (Right result) -> case result of
          InboxProcessed () | mode == InboxDelegated -> pure (IntakeAcknowledged "delegated-fresh")
          InboxDuplicate | mode == InboxDelegated -> pure (IntakeAcknowledged "delegated-duplicate")
          InboxProcessed () -> finish event.messageId "processed"
          InboxDuplicate -> finish event.messageId "duplicate"
          InboxInProgress -> pure (IntakeTransient "inbox row in progress")
          InboxPreviouslyFailed reason -> pure (IntakeTransient ("inbox row previously failed: " <> Text.pack (show reason)))
          InboxHandlerFailed reason attempts -> pure (IntakeTransient ("inbox handler failed (" <> Text.pack (show attempts) <> "): " <> reason))
  where
    poison partition offset reason = do
      stored <- runSql store (insertPoisonTx side.context (unTopicName topic) partition offset reason)
      pure case stored of
        Left storeError -> IntakeTransient ("poison record not stored: " <> Text.pack (show storeError))
        Right () -> IntakeAcknowledged ("poison: " <> reason)
    finish message label = do
      pending <- runSql store (pendingIntakeTx side.context message)
      case pending of
        Left storeError -> pure (IntakeTransient (Text.pack (show storeError)))
        Right Nothing -> pure (IntakeAcknowledged label)
        Right (Just row) -> do
          dispatched <- dispatchRow side store row
          pure case dispatched of
            Left problem -> IntakeTransient problem
            Right outcome -> IntakeAcknowledged (label <> "/" <> outcome)

dispatchRow :: IntakeSide -> ContextStore -> IntakeRow -> IO (Either Text Text)
dispatchRow side store row = do
  outcome <- side.dispatch row
  case outcome of
    Left problem -> pure (Left problem)
    Right (DispatchFailed problem) -> pure (Left (Text.pack (show problem)))
    Right decided -> do
      marked <- runSql store (markIntakeDispatchedTx side.context row.messageId)
      pure case marked of
        Left storeError -> Left (Text.pack (show storeError))
        Right () -> Right (Text.pack (show decided))

-- | Dispatch any intake row left undispatched by a crash between the inbox
-- commit and the command append. Run once when a consumer starts.
sweepIntake :: IntakeSide -> ContextStore -> IO (Either Text Int)
sweepIntake side store = do
  rows <- runSql store (undispatchedIntakeTx side.context)
  case rows of
    Left storeError -> pure (Left (Text.pack (show storeError)))
    Right pending -> do
      results <- traverse (dispatchRow side store) pending
      pure case [problem | Left problem <- results] of
        [] -> Right (length pending)
        problem : _ -> Left problem
