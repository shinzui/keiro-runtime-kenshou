module Kenshou.Suite.Runtime.Roles
  ( roles,
    RoleArgs (..),
    OpsArgs (..),
    longRunningRoles,
    roleNameText,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forever, void, when)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (liftIO)
import GHC.Generics (Generic)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Keiro.Ops (emptyAppHooks, opsCommandTree, runOpsInvocation)
import Keiro.Outbox (BackoffSchedule (..), OrderingPolicy (..), OutboxMaintenanceOptions (..), OutboxPublishOptions (..), OutboxPublishSummary (..), defaultPublishOptions, outboxMaintenancePass, publishClaimedOutbox)
import Keiro.PGMQ.Job (jobProcessorWithContext, runJobWorkers)
import Keiro.PGMQ.Runtime (runJobEff, withJobRuntime)
import Keiro.Subscription.Shard.Worker (RetryDelay (..), ShardAck (..), ShardDelivery (..), ShardedWorkerOptions (..), defaultShardedWorkerOptions, mkShardedWorkerOptions, runShardedSubscriptionGroupAck)
import Keiro.Timer (TimerWorkerOptions (..), defaultTimerWorkerOptions, drainDueTimersWith)
import Keiro.Workflow.Resume (WorkflowResumeOptions (..), defaultWorkflowResumeOptions, runWorkflowResumeWorkerPush, runWorkflowResumeWorkerWith)
import Keiro.Workflow.Sleep (workflowSleepFireAction)
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Runtime.Driver (DriverReport (..), runDriver)
import Kenshou.Suite.Runtime.System.Config
import Kenshou.Suite.Runtime.System.Contracts (TopicPrefix (..))
import Kenshou.Suite.Runtime.System.Intake (IntakeOutcome (..), IntakeSide, consumeEnvelope, shopIntakeSide, sweepIntake, warehouseIntakeSide)
import Kenshou.Suite.Runtime.System.KafkaBridge (ConsumerExit (..), ConsumerSpec (..), publishToBrokers, runKafkaInboxConsumer)
import Kenshou.Suite.Runtime.System.Shop (handleShopDelivery)
import Kenshou.Suite.Runtime.System.Store (ContextEff, ContextStore (..), runContext, withContextStore)
import Kenshou.Suite.Runtime.System.Trace (Signals (..), TraceSabotage (..), workflowRunOptions)
import Kenshou.Suite.Runtime.System.Warehouse (WarehouseEnv (..), cancelOrphanedAwakeables, fireDeadline, fulfilmentRegistry, handlePick, handleWarehouseDelivery, pickJob, pickTuning)
import Kenshou.Suite.Runtime.Telemetry (RoleTelemetry (..), withRoleTelemetry)
import Kiroku.Store (runStoreIO)
import Kiroku.Store.Subscription.Types (RetryPolicy (..), SubscriptionName (..), SubscriptionTarget (..))
import Kiroku.Store.Types (CategoryName (..))
import Options.Applicative (ParserResult (..), execParserPure, prefs, renderFailure, subparserInline)
import Shibuya.App (SupervisionStrategy (..), stopApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ack qualified as Ack
import System.Exit (ExitCode (..))
import System.IO (IOMode (WriteMode), hClose, hFlush, stdout, withFile)

-- | Each role process receives the whole system description and its own
-- index within the role.
data RoleArgs = RoleArgs
  { config :: !SystemConfig,
    index :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RoleEnv = RoleEnv
  { context :: !RoleContext,
    config :: !SystemConfig,
    index :: !Int,
    -- | Filled with @Right ()@ on a stop request, or @Left reason@ when the
    -- role decides to exit after an unrecoverable failure.
    stop :: !(MVar (Either Text ())),
    handled :: !(IORef Int64),
    -- | Tracer, Keiro metrics and telemetry handles for the run's
    -- telemetry dimensions; empty when both are @off@.
    telemetry :: !RoleTelemetry
  }

-- | The twelve long-running roles, in start order.
longRunningRoles :: [Text]
longRunningRoles =
  [ "a-maintenance",
    "b-maintenance",
    "a-publisher",
    "b-publisher",
    "a-dispatch",
    "b-dispatch",
    "b-resume",
    "b-timer",
    "b-jobs",
    "a-consumer",
    "b-consumer",
    "driver"
  ]

traceSabotageFrom :: Text -> TraceSabotage
traceSabotageFrom = \case
  "untraced-outbox" -> UntracedOutbox
  "untraced-producer" -> UntracedProducer
  _ -> NoTraceSabotage

roleNameText :: Text -> Text
roleNameText name = "runtime/" <> name

roles :: [WorkerRole]
roles =
  [ runtimeRole "driver" "Submits seeded open-loop orders to the shop's command processor." driverRole,
    runtimeRole "a-dispatch" "Shop sharded subscription: payment manager, loyalty router and order producer." shopDispatchRole,
    runtimeRole "a-publisher" "Publishes the shop outbox to Kafka with per-record acknowledgement." (publisherRole (.shopDatabase)),
    runtimeRole "a-consumer" "Consumes warehouse outcomes into the shop inbox and order commands." (consumerRole shopIntakeSide (.shopDatabase) (.warehouseTopic) (.shopConsumerGroup)),
    runtimeRole "a-maintenance" "Reclaims stale shop outbox claims." (maintenanceRole (.shopDatabase) (pure ())),
    runtimeRole "b-consumer" "Consumes shop orders into the warehouse inbox and fulfilment commands." (consumerRole warehouseIntakeSide (.warehouseDatabase) (.shopTopic) (.warehouseConsumerGroup)),
    runtimeRole "b-dispatch" "Warehouse sharded subscription: stock manager, workflow start, timers and producer." warehouseDispatchRole,
    runtimeRole "b-resume" "Advances fulfilment workflows." resumeRole,
    runtimeRole "b-timer" "Fires workflow sleeps and fulfilment deadlines." timerRole,
    runtimeRole "b-jobs" "Processes pick jobs and confirms picks through awakeables." jobsRole,
    runtimeRole "b-publisher" "Publishes the warehouse outbox to Kafka with per-record acknowledgement." (publisherRole (.warehouseDatabase)),
    runtimeRole "b-maintenance" "Reclaims stale warehouse outbox claims and cancels awakeables left by terminal workflows." (maintenanceRole (.warehouseDatabase) (void (cancelOrphanedAwakeables Nothing))),
    keiroOpsRole
  ]

-- | One operator-console invocation against one context's database.
data OpsArgs = OpsArgs
  { database :: !Text,
    arguments :: ![Text],
    -- | Where the console's standard output is written.
    output :: !FilePath
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The operator console, invoked on demand from the one deployed binary. It
-- parses its arguments with keiro-ops' own command tree, as the standalone
-- @keiro-ops@ executable does, writes the console's standard output to a
-- file in the run directory, reports the exit code, and waits to be stopped.
keiroOpsRole :: WorkerRole
keiroOpsRole = WorkerRole (roleName "keiro-ops") "Runs one keiro-ops invocation against a context database and records its output." \context -> case Aeson.fromJSON context.init.args of
  Aeson.Error problem -> context.send (WrkError ("invalid keiro-ops arguments: " <> Text.pack problem))
  Aeson.Success (args :: OpsArgs) -> do
    context.send WrkReady
    started <- awaitStart context
    when started do
      let argv = ["--database-url", Text.unpack args.database] <> fmap Text.unpack args.arguments
      result <- case execParserPure (prefs subparserInline) (opsCommandTree emptyAppHooks) argv of
        Success invocation -> do
          code <- withStdoutTo args.output (runOpsInvocation emptyAppHooks invocation)
          pure (object ["exitCode" .= exitNumber code, "output" .= args.output])
        Failure failure ->
          let (message, code) = renderFailure failure "keiro-ops"
           in pure (object ["exitCode" .= exitNumber code, "error" .= message])
        CompletionInvoked _ -> pure (object ["exitCode" .= (2 :: Int), "error" .= ("completion requested" :: Text)])
      context.send (WrkCustom "keiro-ops-finished" result)
      stop <- newEmptyMVar
      watchControl context stop
  where
    exitNumber = \case
      ExitSuccess -> 0 :: Int
      ExitFailure n -> n

-- | Run an action with this process's standard output redirected to a file.
-- The worker protocol has already moved its own channel off standard output.
withStdoutTo :: FilePath -> IO a -> IO a
withStdoutTo path action = withFile path WriteMode \handle -> do
  hFlush stdout
  saved <- hDuplicate stdout
  hDuplicateTo handle stdout
  action `finally` do
    hFlush stdout
    hDuplicateTo saved stdout
    hClose saved

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName . roleNameText

-- | Every long-running role reports ready, waits for start, sends a progress
-- heartbeat at least every two seconds, and on stop drains and exits.
runtimeRole :: Text -> Text -> (RoleEnv -> IO ()) -> WorkerRole
runtimeRole name summary body = WorkerRole (roleName name) summary \context -> case Aeson.fromJSON context.init.args of
  Aeson.Error problem -> context.send (WrkError ("invalid runtime role arguments: " <> Text.pack problem))
  Aeson.Success (args :: RoleArgs) -> do
    context.send WrkReady
    started <- awaitStart context
    when started do
      stop <- newEmptyMVar
      handled <- newIORef 0
      withRoleTelemetry (traceSabotageFrom args.config.traceSabotage) context \telemetry -> do
        let env = RoleEnv context args.config args.index stop handled telemetry
        withAsync (watchControl context stop) \_ -> withAsync (heartbeat env) \_ -> do
          outcome <- try @SomeException (body env)
          final <- tryReadMVar stop
          case (outcome, final) of
            (Left exception, _) -> ioError (userError (displayException exception))
            (Right (), Just (Left reason)) -> ioError (userError (Text.unpack reason))
            (Right (), _) -> pure ()

awaitStart :: RoleContext -> IO Bool
awaitStart context =
  context.receive >>= \case
    Just CtlStart -> pure True
    Just (CtlStop _) -> pure False
    Just _ -> awaitStart context
    Nothing -> pure False

watchControl :: RoleContext -> MVar (Either Text ()) -> IO ()
watchControl context stop = loop
  where
    loop =
      context.receive >>= \case
        Just (CtlStop _) -> void (tryPutMVar stop (Right ()))
        Nothing -> void (tryPutMVar stop (Right ()))
        Just _ -> loop

heartbeat :: RoleEnv -> IO ()
heartbeat env = forever do
  count <- readIORef env.handled
  now <- getCurrentTime
  env.context.send (WrkProgress count now)
  threadDelay 2000000

bump :: RoleEnv -> IO ()
bump env = atomicModifyIORef' env.handled (\n -> (n + 1, ()))

-- | Repeat a pass until stopped, sleeping only when the pass found no work.
untilStopped :: RoleEnv -> Int -> IO Bool -> IO ()
untilStopped env idleMicros pass = loop
  where
    loop = do
      requested <- tryReadMVar env.stop
      case requested of
        Just _ -> pure ()
        Nothing -> do
          busy <- pass
          if busy then pure () else threadDelay idleMicros
          loop

-- | Run a blocking loop until a stop is requested.
blockingUntilStopped :: RoleEnv -> IO () -> IO ()
blockingUntilStopped env action =
  race (readMVar env.stop) action >>= \case
    Left _ -> pure ()
    Right () -> void (tryPutMVar env.stop (Left "worker loop exited unexpectedly"))

timeouts :: RoleEnv -> Timeouts
timeouts env = timeoutsFor env.config.ttlProfile

prefixOf :: SystemConfig -> TopicPrefix
prefixOf config = TopicPrefix config.topicPrefix

driverRole :: RoleEnv -> IO ()
driverRole env = withContextStore env.config.shopDatabase env.config.poolSize \store -> do
  report <- runDriver env.telemetry.signals store env.context.init.seed env.config env.index env.stop \_ outcome -> do
    bump env
    case outcome of
      _ -> pure ()
  env.context.send (WrkCustom "driver-finished" (Aeson.toJSON report))
  when (report.failed > 0) (void (tryPutMVar env.stop (Left ("driver failed to submit " <> Text.pack (show report.failed) <> " orders"))))
  void (readMVar env.stop)

shardOptions :: RoleEnv -> Text -> Either Text ShardedWorkerOptions
shardOptions env category =
  either (Left . Text.pack . show) Right $
    mkShardedWorkerOptions
      (defaultShardedWorkerOptions (Category (CategoryName category)) env.config.shardCount)
        { leaseTtl = realToFrac (timeouts env).shardLeaseSeconds,
          renewInterval = realToFrac (timeouts env).shardRenewSeconds,
          retryPolicy = RetryPolicy 1000
        }

dispatchLoop :: RoleEnv -> ContextStore -> Text -> Text -> (ShardDelivery -> IO (Either Text ())) -> IO ()
dispatchLoop env store subscription category handle = case shardOptions env category of
  Left problem -> ioError (userError ("invalid shard options: " <> Text.unpack problem))
  Right options ->
    blockingUntilStopped env $
      runShardedSubscriptionGroupAck store.store (SubscriptionName subscription) options \delivery -> do
        result <- try @SomeException (handle delivery)
        case result of
          Right (Right ()) -> bump env >> pure ShardAckOk
          Right (Left problem) -> retry problem
          Left exception -> retry (Text.pack (displayException exception))
  where
    retry problem = do
      env.context.send (WrkCustom "dispatch-retry" (object ["problem" .= problem]))
      pure (ShardAckRetry (RetryDelay 1))

shopDispatchRole :: RoleEnv -> IO ()
shopDispatchRole env = withContextStore env.config.shopDatabase env.config.poolSize \store ->
  dispatchLoop env store "shop-dispatch" "order" \delivery -> handleShopDelivery env.telemetry.signals store (prefixOf env.config) delivery.event

withWarehouseEnv :: RoleEnv -> (WarehouseEnv -> IO a) -> IO a
withWarehouseEnv env action =
  withContextStore env.config.warehouseDatabase env.config.poolSize \store ->
    withJobRuntime env.config.warehouseDatabase env.telemetry.signals.tracer \jobs ->
      action
        WarehouseEnv
          { store,
            jobs,
            coolingOff = fromIntegral env.config.coolingOffMillis / 1000,
            deadline = fromIntegral env.config.fulfilmentDeadlineSeconds,
            signals = env.telemetry.signals
          }

warehouseDispatchRole :: RoleEnv -> IO ()
warehouseDispatchRole env = withWarehouseEnv env \warehouse ->
  dispatchLoop env warehouse.store "warehouse-dispatch" "fulfilment" \delivery -> handleWarehouseDelivery warehouse (prefixOf env.config) delivery.event

resumeRole :: RoleEnv -> IO ()
resumeRole env = withWarehouseEnv env \warehouse -> do
  let options =
        defaultWorkflowResumeOptions
          { runOptions = workflowRunOptions env.telemetry.signals,
            pollInterval = 200000,
            leaseTtl = realToFrac (timeouts env).workflowLeaseSeconds,
            maxConcurrentAdvances = env.config.maxConcurrentAdvances
          }
      registry = fulfilmentRegistry warehouse
  blockingUntilStopped env case env.config.wakeMode of
    WakePush -> runWorkflowResumeWorkerPush warehouse.store.store options registry
    WakePoll -> void (runStoreIO warehouse.store.store (runWorkflowResumeWorkerWith options registry))

timerRole :: RoleEnv -> IO ()
timerRole env = withContextStore env.config.warehouseDatabase env.config.poolSize \store -> do
  let options = defaultTimerWorkerOptions {requeueStuckAfter = Just (realToFrac (timeouts env).timerRequeueSeconds)}
      fire row =
        workflowSleepFireAction row >>= \case
          Just fired -> pure (Just fired)
          Nothing -> liftIO (fireDeadline env.telemetry.signals store row)
  untilStopped env 100000 do
    now <- getCurrentTime
    fired <- runContext store (drainDueTimersWith env.telemetry.signals.metrics options now 100 fire)
    case fired of
      Left problem -> env.context.send (WrkCustom "timer-pass-failed" (object ["problem" .= show problem])) >> pure False
      Right count -> do
        when (count > 0) (atomicModifyIORef' env.handled (\n -> (n + fromIntegral count, ())))
        pure (count > 0)

jobsRole :: RoleEnv -> IO ()
jobsRole env = withWarehouseEnv env \warehouse -> do
  let tuning = pickTuning (timeouts env).jobVisibilitySeconds env.config.queueBatchSize
      handler jobContext job = do
        outcome <- handlePick warehouse jobContext job
        liftIO (bump env)
        pure outcome
  result <- runJobEff warehouse.jobs do
    started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext tuning pickJob handler]
    case started of
      Left problem -> pure (Left (Text.pack (show problem)))
      Right app -> do
        reason <- liftIO (readMVar env.stop)
        stopApp app
        pure (Right reason)
  case result of
    Left problem -> ioError (userError (show problem))
    Right (Left problem) -> ioError (userError (Text.unpack problem))
    Right (Right _) -> pure ()

publisherRole :: (SystemConfig -> Text) -> RoleEnv -> IO ()
publisherRole database env = withContextStore (database env.config) env.config.poolSize \store -> do
  let policy = orderingPolicyFrom env.config.orderingPolicy
      options =
        defaultPublishOptions
          { batchSize = env.config.outboxBatchSize,
            orderingPolicy = policy,
            publishingTimeout = realToFrac (timeouts env).publishingTimeoutSeconds,
            backoff = ConstantBackoff 1
          }
      brokers = fmap BrokerAddress env.config.brokers
  untilStopped env 50000 do
    summary <- runContext store (publishClaimedOutbox (liftIO . publishToBrokers env.telemetry.signals brokers policy) options env.telemetry.signals.metrics)
    case summary of
      Left problem -> env.context.send (WrkCustom "publish-pass-failed" (object ["problem" .= show problem])) >> pure False
      Right value -> do
        when (value.published > 0) (atomicModifyIORef' env.handled (\n -> (n + fromIntegral value.published, ())))
        pure (value.claimed > 0)

orderingPolicyFrom :: Text -> OrderingPolicy
orderingPolicyFrom = \case
  "per-source-stream" -> PerSourceStream
  "stop-the-line" -> StopTheLine
  "best-effort" -> BestEffort
  _ -> PerKeyHeadOfLine

maintenanceRole :: (SystemConfig -> Text) -> ContextEff () -> RoleEnv -> IO ()
maintenanceRole database extra env = withContextStore (database env.config) env.config.poolSize \store ->
  untilStopped env 1000000 do
    result <- runContext store (outboxMaintenancePass (OutboxMaintenanceOptions 10 (realToFrac (timeouts env).publishingTimeoutSeconds)) env.telemetry.signals.metrics >> extra)
    case result of
      Left problem -> env.context.send (WrkCustom "maintenance-pass-failed" (object ["problem" .= show problem]))
      Right _ -> bump env
    pure False

-- | The Kafka consumer of one context. Under the default crash-only policy a
-- transient database failure is retried in place three times; after that the
-- process exits non-zero so that consumption resumes from the committed
-- offset when it is restarted.
consumerRole :: (Signals -> ContextStore -> IntakeSide) -> (SystemConfig -> Text) -> (SystemConfig -> Text) -> (SystemConfig -> Text) -> RoleEnv -> IO ()
consumerRole sideFor database topicOf groupOf env = withContextStore (database env.config) env.config.poolSize \store -> do
  let side = sideFor env.telemetry.signals store
  swept <- sweepIntake side store
  case swept of
    Left problem -> ioError (userError ("intake sweep failed: " <> Text.unpack problem))
    Right count -> env.context.send (WrkCustom "intake-swept" (object ["rows" .= count]))
  let topic = TopicName (topicOf env.config)
      spec =
        ConsumerSpec
          { brokers = env.config.brokers,
            topic = topicOf env.config,
            group = groupOf env.config,
            processor = topicOf env.config <> "-consumer",
            properties = [("auto.commit.interval.ms", "1000"), ("session.timeout.ms", "10000")]
          }
      handle envelope now = attempt (3 :: Int) (500000 :: Int)
        where
          attempt remaining delay = do
            outcome <- consumeEnvelope env.config.inboxMode (4 - remaining) side store (prefixOf env.config) topic envelope now
            case outcome of
              IntakeAcknowledged label -> do
                bump env
                when ("poison" `Text.isPrefixOf` label) (env.context.send (WrkCustom "intake-poison" (object ["reason" .= label])))
                pure AckOk
              IntakeTransient problem
                | env.config.transientPolicy == AckRetryPolicy -> pure (AckRetry (Ack.RetryDelay 5))
                | remaining > 0 -> threadDelay delay >> attempt (remaining - 1) (delay * 2)
                | otherwise -> do
                    void (tryPutMVar env.stop (Left ("transient intake failure: " <> problem)))
                    pure (AckHalt (HaltFatal problem))
      -- A session that ends without a stop request is the adapter's known
      -- rebalance exit (shibuya-kafka-adapter BUG-4). Crash-only consumption
      -- answers it the way a supervisor would: start a fresh session, which
      -- resumes from the committed offsets after the intake sweep.
      session (ended :: Int) = do
        result <- runKafkaInboxConsumer env.telemetry.signals.tracer spec env.stop handle
        case result of
          Left problem -> void (tryPutMVar env.stop (Left problem))
          Right (StoppedWith _) -> pure ()
          Right SessionEnded -> do
            env.context.send (WrkCustom "consumer-session-ended" (object ["sessions" .= (ended + 1), "reference" .= ("mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4" :: Text)]))
            requested <- tryReadMVar env.stop
            case requested of
              Just _ -> pure ()
              Nothing -> do
                threadDelay 500000
                _ <- sweepIntake side store
                session (ended + 1)
  session 0
