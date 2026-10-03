module Kenshou.Suite.Runtime.System.Warehouse
  ( StockStep (..),
    StockInput (..),
    PickJob (..),
    WarehouseEnv (..),
    stockManager,
    warehouseProducer,
    fulfilmentWorkflowName,
    fulfilmentWorkflow,
    fulfilmentRegistry,
    pickJob,
    pickTuning,
    handlePick,
    deadlineTimerId,
    fireDeadline,
    handleWarehouseDelivery,
    warehouseIntakeCommand,
    dispatchFulfilmentCommand,
    seedWarehouse,
    cancelOrphanedAwakeables,
    isDiscontinued,
    skuAccount,
    openingStock,
  )
where

import Control.Monad (forM, forM_, void)
import Data.Aeson (FromJSON, ToJSON, object, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe, withObject)
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiki.Core (HsPred)
import Keiro.Codec (Codec (..))
import Keiro.Command (RunCommandOptions, defaultRunCommandOptions)
import Keiro.Integration.Event (TraceContext (..))
import Keiro.Outbox (IntegrationProducer (..), ProducerEnqueueOutcome (..), enqueueProducerEventTx, mkIntegrationProducer)
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobContext, JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), RetryDelay (..), defaultJobTuning, defaultRetryPolicy, enqueueToGroup, enqueueTraced, ensureOrderedJobQueue)
import Keiro.PGMQ.Runtime (JobRuntime, queueRef, runJobEff)
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..), ProcessManager (..), ProcessManagerAction (..), ProcessManagerResult (..), runProcessManagerOnce)
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), cancelTimer)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName, WorkflowOutcome (..), mkWorkflowName, runWorkflowWith, step)
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText, awakeableNamed, cancelAwakeable, signalAwakeable)
import Keiro.Workflow.Instance (cancelWorkflow)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..), ShopMessage (..), Sku (..), TopicPrefix, WarehouseMessage (..))
import Kenshou.Suite.Runtime.System.Dispatch (Dispatched (..), dispatchOnce)
import Kenshou.Suite.Runtime.System.Fulfilment
import Kenshou.Suite.Runtime.System.Ledger (AccountCommand, AccountEvent, AccountId (..), LedgerPhi, LedgerRegs, LedgerState, accountCommandStream, accountStream, creditTransfer, debitTransfer, ensureLedgerReadModels, ledgerEventStream, ledgerProjections, openAccount)
import Kenshou.Suite.Runtime.System.Ledger qualified as Ledger
import Kenshou.Suite.Runtime.System.SagaLog (ObserveSagaData (..), SagaCommand (..), SagaEvent, SagaState, sagaEventStream, sagaStream)
import Kenshou.Suite.Runtime.System.Schema (IntakeRow (..), ensureWarehouseTables, fulfilmentProjection, upsertPickRequestTx)
import Kenshou.Suite.Runtime.System.Store (ContextEff, ContextStore, deterministicEventId, runContext, runContextOrThrow)
import Kenshou.Suite.Runtime.System.Trace (Signals (..), commandOptions, currentTraceContext, draftTraceContext, withEventTrace, withStoredTrace, workflowRunOptions)
import Kenshou.Suite.Runtime.System.Wire (tracedDraft, warehouseEventDraft)
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..), RecordedEvent (..))
import Pgmq.Types (MessageHeaders (..))

-- Accounts of the warehouse's stock ledger.

skuAccount :: Sku -> Text -> AccountId
skuAccount (Sku sku) bucket = AccountId (sku <> "-" <> bucket)

openingStock :: Int64
openingStock = 1000000

-- | The static catalogue: a discontinued SKU is refused from the inbound
-- message alone, never from a ledger rejection.
isDiscontinued :: Sku -> Bool
isDiscontinued (Sku sku) = "discontinued-" `Text.isPrefixOf` sku

data StockStep = StockReserve !UTCTime | StockCommit | StockRelease
  deriving stock (Eq, Show)

data StockInput = StockInput
  { sourceEventId :: !Text,
    orderId :: !OrderId,
    step :: !StockStep,
    sku :: !Sku,
    quantity :: !Int
  }
  deriving stock (Eq, Show)

-- | Moves stock between the available, reserved and shipped buckets. The
-- deadline timer is scheduled in the same transaction as the manager's own
-- state append, so a reservation can never exist without its deadline.
stockManager :: ProcessManager StockInput (HsPred '[] SagaCommand) '[] SagaState SagaCommand SagaEvent LedgerPhi LedgerRegs LedgerState AccountCommand AccountEvent
stockManager =
  ProcessManager
    { name = "warehouse-stock",
      correlate = \input -> orderText input.orderId,
      eventStream = sagaEventStream,
      streamFor = sagaStream "warehouseStock" . OrderId,
      targetEventStream = ledgerEventStream,
      targetProjections = ledgerProjections,
      handle = \input ->
        let movement purpose from to =
              let source = skuAccount input.sku from
                  destination = skuAccount input.sku to
                  reference = Ledger.transferRef input.orderId purpose
                  amount = fromIntegral input.quantity
               in [ PMCommand (accountCommandStream source) (ledger (debitTransfer source reference destination amount 0)),
                    PMCommand (accountCommandStream destination) (ledger (creditTransfer destination reference source amount))
                  ]
            (stage, commands, timers) = case input.step of
              StockReserve deadline ->
                ( "reserve",
                  movement "reserve" "available" "reserved",
                  [ TimerRequest
                      { timerId = deadlineTimerId input.orderId,
                        processManagerName = "warehouse-stock",
                        correlationId = orderText input.orderId,
                        fireAt = deadline,
                        payload = object ["kind" .= ("fulfilment-deadline" :: Text), "orderId" .= orderText input.orderId]
                      }
                  ]
                )
              StockCommit -> ("commit", movement "commit" "reserved" "shipped", [])
              StockRelease -> ("release", movement "release" "reserved" "available", [])
         in ProcessManagerAction
              { command = ObserveSaga (ObserveSagaData input.orderId stage input.sourceEventId),
                commands,
                timers
              }
    }

deadlineTimerId :: OrderId -> TimerId
deadlineTimerId (OrderId order) =
  TimerId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou-runtime/deadline/" <> order))))

warehouseProducer :: IntegrationProducer FulfilmentEvent
warehouseProducer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "warehouse-fulfilments" "warehouse" "warehouse" (\_ _ -> Nothing)))

data PickJob = PickJob
  { orderId :: !Text,
    sku :: !Text,
    quantity :: !Int,
    awakeableId :: !Text,
    slowPick :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

pickJob :: Job PickJob
pickJob = Job "pick" (queueRef "pick") aesonJobCodec FifoHeads defaultRetryPolicy

pickTuning :: Int -> Int -> JobTuning
pickTuning visibility batch =
  defaultJobTuning {visibilityTimeout = fromIntegral visibility, batchSize = fromIntegral (max 1 batch), polling = PollEvery 0.1, ordering = FifoHeads}

data WarehouseEnv = WarehouseEnv
  { store :: !ContextStore,
    jobs :: !JobRuntime,
    coolingOff :: !NominalDiffTime,
    deadline :: !NominalDiffTime,
    signals :: !Signals
  }

fulfilmentWorkflowName :: WorkflowName
fulfilmentWorkflowName = either (error . show) id (mkWorkflowName "fulfilment")

data OrderFacts = OrderFacts {sku :: !Text, quantity :: !Int, slowPick :: !Bool}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Cooling off, then a pick request whose confirmation arrives through an
-- awakeable, then shipping. A slow pick never signals, so the deadline timer
-- decides the order instead; the fulfilment aggregate serialises the race.
fulfilmentWorkflow :: (IOE :> es, Store :> es) => WarehouseEnv -> WorkflowId -> Eff (Workflow : es) Text
--
-- A resumed run starts a new root trace: the runtime does not carry trace
-- context across a sleep or an awakeable. The first step journals the trace
-- of the run that started the workflow, and the later steps re-attach it, so
-- the pick job and the ship command stay in the order's trace.
fulfilmentWorkflow env wid@(WorkflowId order) = do
  origin <- step (StepName "trace-origin") (liftIO (fmap (fmap traceOrigin) currentTraceContext))
  let parent = fmap fromTraceOrigin origin
  facts <- step (StepName "load-order") (liftIO (loadFacts env (OrderId order)))
  sleepNamed (StepName "cooling-off") env.coolingOff
  (aid, await) <- awakeableNamed (StepName "pick-confirmation")
  _ <- step (StepName "request-pick") (liftIO (withStoredTrace env.signals parent (requestPick env (OrderId order) facts aid)))
  (_ :: Text) <- await
  step (StepName "ship") (liftIO (withStoredTrace env.signals parent (ship env wid)))

-- | A journaled trace context: @traceparent@ and @tracestate@.
traceOrigin :: TraceContext -> (Text, Maybe Text)
traceOrigin context = (context.traceparent, context.tracestate)

fromTraceOrigin :: (Text, Maybe Text) -> TraceContext
fromTraceOrigin (parent, state) = TraceContext parent state

loadFacts :: WarehouseEnv -> OrderId -> IO OrderFacts
loadFacts env (OrderId order) = do
  found <- runContextOrThrow env.store (runTransaction (Tx.statement order orderFactsStatement))
  case found of
    Just facts -> pure facts
    Nothing -> ioError (userError ("no fulfilment request for order " <> Text.unpack order))

-- | The order facts recorded in the append transaction of the request, so
-- the workflow does not depend on which inbox mode delivered the order.
orderFactsStatement :: Statement.Statement Text (Maybe OrderFacts)
orderFactsStatement =
  Statement.preparable
    "SELECT sku, quantity, slow_pick FROM warehouse.fulfilments WHERE order_id = $1 AND sku IS NOT NULL"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe (OrderFacts <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.bool)))

requestPick :: WarehouseEnv -> OrderId -> OrderFacts -> AwakeableId -> IO ()
requestPick env order facts aid = do
  runContextOrThrow env.store (runTransaction (upsertPickRequestTx order (Sku facts.sku) facts.quantity (awakeableIdText aid) facts.slowPick))
  let job = PickJob (orderText order) facts.sku facts.quantity (awakeableIdText aid) facts.slowPick
  -- The traced enqueue writes the current trace into the message headers;
  -- the group header keeps the job in its SKU's FIFO group.
  enqueued <- runJobEff env.jobs case env.signals.provider of
    Just provider -> enqueueTraced provider pickJob (MessageHeaders (object ["x-pgmq-group" .= facts.sku])) job
    Nothing -> enqueueToGroup pickJob facts.sku job
  either (ioError . userError . show) (const (pure ())) enqueued

ship :: WarehouseEnv -> WorkflowId -> IO Text
ship env (WorkflowId order) = do
  options <- commandOptions env.signals
  result <- runContextOrThrow env.store (dispatchFulfilmentCommand options ("ship/" <> order) (OrderId order) (ShipFulfilment (ShipFulfilmentData (OrderId order))))
  case result of
    DispatchAppended -> pure "shipped"
    DispatchDuplicate -> pure "shipped"
    -- The deadline won the race; the aggregate already decided the order.
    DispatchRejected -> pure "already-decided"
    DispatchFailed problem -> ioError (userError ("ship failed: " <> show problem))

fulfilmentRegistry :: WarehouseEnv -> WorkflowRegistry '[Store, Error StoreError, IOE]
fulfilmentRegistry env = Map.singleton fulfilmentWorkflowName (WorkflowDef (fulfilmentWorkflow env))

-- | The pick handler confirms the pick through the workflow's awakeable. A
-- slow pick acknowledges the job without signalling, which leaves the
-- deadline timer to expire the fulfilment.
handlePick :: (IOE :> es) => WarehouseEnv -> JobContext es -> PickJob -> Eff es JobOutcome
handlePick env _ job
  | job.slowPick = pure Done
  | otherwise = case UUID.fromText job.awakeableId of
      Nothing -> pure (Dead "invalid awakeable id")
      Just aid -> do
        signalled <- liftIO (runContext env.store (signalAwakeable (AwakeableId aid) ("picked" :: Text)))
        pure case signalled of
          Left _ -> Retry (RetryDelay 1)
          Right _ -> Done

-- | The fallback fire action for non-sleep timers: an expired deadline asks
-- the fulfilment aggregate to expire. If shipping already won, the command is
-- refused and the timer is still settled.
fireDeadline :: Signals -> ContextStore -> TimerRow -> IO (Maybe EventId)
fireDeadline signals context row = case parseMaybe (withObject "deadline" \value -> (,) <$> value .: "kind" <*> value .: "orderId") row.payload of
  Just ("fulfilment-deadline" :: Text, order) -> do
    let identity = "expire/" <> order
    options <- commandOptions signals
    outcome <- runContext context (dispatchFulfilmentCommand options identity (OrderId order) (ExpireFulfilment (ExpireFulfilmentData (OrderId order))))
    pure case outcome of
      Right DispatchAppended -> Just (deterministicEventId ("warehouse/" <> identity))
      Right DispatchDuplicate -> Just (deterministicEventId ("warehouse/" <> identity))
      Right DispatchRejected -> Just (deterministicEventId ("warehouse/" <> identity))
      _ -> Nothing
  _ -> pure Nothing

dispatchFulfilmentCommand :: RunCommandOptions -> Text -> OrderId -> FulfilmentCommand -> ContextEff Dispatched
dispatchFulfilmentCommand options identity order command =
  dispatchOnce options fulfilmentEventStream (fulfilmentStream order) (deterministicEventId ("warehouse/" <> identity)) command [fulfilmentProjection]

-- | One idempotent handler per fulfilment event: the stock manager, the
-- workflow start or cancellation, timer cancellation and the producer.
handleWarehouseDelivery :: WarehouseEnv -> TopicPrefix -> RecordedEvent -> IO (Either Text ())
handleWarehouseDelivery env prefix recorded = case fulfilmentCodec.decode recorded.eventType recorded.payload of
  Left problem -> pure (Left ("undecodable fulfilment event: " <> problem))
  Right event -> withEventTrace env.signals "dispatch warehouse-dispatch" recorded do
    options <- commandOptions env.signals
    let trace = draftTraceContext env.signals recorded
    let runStock input = do
          result <- runProcessManagerOnce options stockManager recorded input
          pure case result of
            Left problem -> ["stock manager state: " <> Text.pack (show problem)]
            Right value -> [Text.pack (show stream) <> ": " <> Text.pack (show problem) | PMCommandFailed stream problem <- value.commandResults]
        produce message = do
          enqueued <- runTransaction (enqueueProducerEventTx warehouseProducer recorded 0 (tracedDraft trace (warehouseEventDraft prefix recorded.createdAt message)))
          pure (producedProblems enqueued)
    outcome <- runContext env.store case event of
      FulfilmentRequested d -> do
        let deadline = addUTCTime env.deadline recorded.createdAt
        stock <- runStock (StockInput sourceId d.orderId (StockReserve deadline) d.sku d.quantity)
        if null stock
          then do
            started <- runWorkflowWith (workflowRunOptions env.signals) fulfilmentWorkflowName (WorkflowId (orderText d.orderId)) (fulfilmentWorkflow env (WorkflowId (orderText d.orderId)))
            pure (workflowProblems started)
          else pure stock
      FulfilmentRefused d -> produce (FulfilmentRefusedV1 d.orderId d.reason)
      FulfilmentShipped d -> withFulfilment d.orderId \sku quantity -> do
        stock <- runStock (StockInput sourceId d.orderId StockCommit sku quantity)
        void (cancelTimer (deadlineTimerId d.orderId))
        produced <- produce (FulfilmentShippedV1 d.orderId sku quantity)
        pure (stock <> produced)
      FulfilmentExpired d -> withFulfilment d.orderId \sku quantity -> do
        stock <- runStock (StockInput sourceId d.orderId StockRelease sku quantity)
        void (cancelWorkflow fulfilmentWorkflowName (WorkflowId (orderText d.orderId)))
        void (cancelOrphanedAwakeables (Just (orderText d.orderId)))
        produced <- produce (FulfilmentExpiredV1 d.orderId)
        pure (stock <> produced)
    pure case outcome of
      Left storeError -> Left (Text.pack (show storeError))
      Right [] -> Right ()
      Right problems -> Left (Text.intercalate "; " problems)
  where
    sourceId = let EventId value = recorded.eventId in UUID.toText value
    withFulfilment order continue = do
      found <- runTransaction (Tx.statement (orderText order) fulfilmentDetailsStatement)
      case found of
        Just (sku, quantity) -> continue (Sku sku) (fromIntegral quantity)
        Nothing -> pure ["fulfilment read model has no reservation for " <> orderText order]

producedProblems :: ProducerEnqueueOutcome -> [Text]
producedProblems = \case
  ProducerIdentityConflict identity fields -> ["producer identity conflict " <> Text.pack (show identity) <> " " <> Text.pack (show fields)]
  _ -> []

workflowProblems :: WorkflowOutcome Text -> [Text]
workflowProblems = \case
  Failed -> ["fulfilment workflow failed"]
  _ -> []

fulfilmentDetailsStatement :: Statement.Statement Text (Maybe (Text, Int64))
fulfilmentDetailsStatement =
  Statement.preparable
    "SELECT sku, quantity FROM warehouse.fulfilments WHERE order_id = $1 AND sku IS NOT NULL"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4))))

-- | Keiro's workflow cancellation does not cascade to awakeables, and an
-- allocation already in flight may commit after the cancellation marker. The
-- application therefore cancels every pending awakeable whose owning
-- workflow is terminal: for one order when its fulfilment expires, and for
-- all orders on every warehouse maintenance pass.
cancelOrphanedAwakeables :: Maybe Text -> ContextEff Int
cancelOrphanedAwakeables order = do
  pending <- runTransaction (Tx.statement order orphanedAwakeablesStatement)
  cancelled <- traverse (cancelAwakeable . AwakeableId) pending
  pure (length (filter id cancelled))

orphanedAwakeablesStatement :: Statement.Statement (Maybe Text) [UUID.UUID]
orphanedAwakeablesStatement =
  Statement.preparable
    "SELECT a.awakeable_id FROM keiro.keiro_awakeables a JOIN keiro.keiro_workflows w ON w.workflow_name = a.owner_workflow_name AND w.workflow_id = a.owner_workflow_id WHERE a.status = 'pending' AND a.owner_workflow_name = 'fulfilment' AND w.status IN ('completed', 'cancelled', 'failed') AND ($1::text IS NULL OR a.owner_workflow_id = $1)"
    (Encoders.param (Encoders.nullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.uuid)))

-- | Translate one intake row into the fulfilment command it stands for. The
-- decision uses only the inbound message and the static catalogue.
warehouseIntakeCommand :: IntakeRow -> Either Text FulfilmentCommand
warehouseIntakeCommand row = case (row.kind, Aeson.fromJSON row.payload) of
  ("order.placed.v1", Aeson.Success (message :: ShopMessage))
    | isDiscontinued message.sku -> Right (RefuseFulfilment (RefuseFulfilmentData message.orderId "discontinued"))
    | otherwise -> Right (RequestFulfilment (RequestFulfilmentData message.orderId message.sku message.quantity message.slowPick))
  (kind, Aeson.Error problem) -> Left ("undecodable warehouse intake " <> kind <> ": " <> Text.pack problem)
  (kind, _) -> Left ("unexpected warehouse intake kind " <> kind)

seedWarehouse :: ContextStore -> JobRuntime -> Int -> IO ()
seedWarehouse context jobs skus = do
  runContextOrThrow context (ensureLedgerReadModels >> ensureWarehouseTables)
  let accounts =
        concat
          [ [(skuAccount sku "available", openingStock), (skuAccount sku "reserved", 0), (skuAccount sku "shipped", 0)]
          | n <- [0 .. skus - 1],
            let sku = Sku ("sku-" <> Text.pack (show n))
          ]
  results <- forM accounts \(account@(AccountId name), balance) ->
    runContextOrThrow context $
      dispatchOnce defaultRunCommandOptions ledgerEventStream (accountStream account) (deterministicEventId ("open/" <> name)) (ledger (openAccount account balance)) (ledgerProjections (accountCommandStream account))
  forM_ results \case
    DispatchAppended -> pure ()
    DispatchDuplicate -> pure ()
    other -> ioError (userError ("could not open warehouse account: " <> show other))
  provisioned <- runJobEff jobs (ensureOrderedJobQueue pickJob)
  either (ioError . userError . show) pure provisioned

ledger :: (Show problem) => Either problem AccountCommand -> AccountCommand
ledger = either (\problem -> error ("ledger command outside the generator's guarantees: " <> show problem)) id

orderText :: OrderId -> Text
orderText (OrderId value) = value
