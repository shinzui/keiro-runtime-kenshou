module Kenshou.Suite.Runtime.Topology
  ( SystemSpec (..),
    systemSpecFrom,
    RunningSystem (..),
    withReferenceSystem,
    QuiescenceReport (..),
    awaitQuiescence,
    processesOf,
    signalRole,
    stopRoles,
    RestartRecord (..),
    killAndRestart,
    restartsOf,
    recordWindow,
    driverReports,
    consumerSessionsEnded,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (forM, forM_, forever, unless, void)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Types (BrokerAddress (..), PartitionId (..), TopicName (..))
import Keiro.PGMQ.Runtime (withJobRuntime)
import Kenshou.Check.Fact (FactKind (..), ProcId (..))
import Kenshou.Check.Ledger (recordDurable)
import Kenshou.Check.Process (Child, ChildSignal, ProgressSnapshot (..), Supervisor, awaitReady, childExitCode, childPid, childProc, killChild, progress, readChildMessages, reapChild, restartChild, roleProcess, sendCommand, signalChild, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Env.Kafka (BrokerLane (..), GroupSnapshot (..), KafkaEnv (..), PartitionOffsets (..), describeGroup)
import Kenshou.Suite.Runtime.Driver (DriverReport (..))
import Kenshou.Suite.Runtime.Knobs (partitionsFrom, systemConfigFrom)
import Kenshou.Suite.Runtime.Roles (RoleArgs (..), longRunningRoles, roleNameText)
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..))
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..), customerCount, skuCount)
import Kenshou.Suite.Runtime.System.Context (RuntimeContext (..), RuntimeResources (..), withRuntimeResources)
import Kenshou.Suite.Runtime.System.Schema (Backlog (..), ContextName (..), StatusCounts (..), backlogTx, fulfilmentStatusCountsTx, orderStatusCountsTx, stuckWorkTx)
import Kenshou.Suite.Runtime.System.Shop (seedShop)
import Kenshou.Suite.Runtime.System.Store (ContextStore (..), runSql)
import Kenshou.Suite.Runtime.System.Warehouse (seedWarehouse)

-- | What a scenario asks of the reference system. Everything that changes
-- the experiment is a resolved knob, carried by the base configuration.
newtype SystemSpec = SystemSpec {base :: SystemConfig}

systemSpecFrom :: RunContext -> SystemSpec
systemSpecFrom context = SystemSpec (systemConfigFrom context.knobs)

data RunningSystem = RunningSystem
  { config :: !SystemConfig,
    shop :: !ContextStore,
    warehouse :: !ContextStore,
    -- | The two PostgreSQL environments, for fault injection.
    shopPostgres :: !PostgresEnv,
    warehousePostgres :: !PostgresEnv,
    broker :: !RuntimeBroker,
    check :: !CheckEnv,
    supervisor :: !Supervisor,
    children :: !(IORef (Map Text [Child])),
    -- | Numbers on-demand role invocations, such as the operator console, so
    -- that each gets its own log and output files.
    invocations :: !(IORef Int),
    -- | Serialises restarts with stopping, so no replacement starts after
    -- the roles were stopped.
    lifecycle :: !(MVar Bool),
    restarts :: !(IORef [RestartRecord])
  }

-- | One role process replaced by the supervision loop or a fault injector.
data RestartRecord = RestartRecord
  { role :: !Text,
    index :: !Int,
    cause :: !Text,
    exitCode :: !Text,
    diedAt :: !UTCTime,
    readyAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON RestartRecord where
  toJSON record = object ["role" .= record.role, "index" .= record.index, "cause" .= record.cause, "exitCode" .= record.exitCode, "diedAt" .= record.diedAt, "readyAt" .= record.readyAt, "seconds" .= (realToFrac (diffUTCTime record.readyAt record.diedAt) :: Double)]

-- | Acquire both PostgreSQL environments and the broker, create the topics,
-- run the application DDL, seed accounts and referrals, and start every role
-- in dependency order: maintenance, publishers, dispatchers, resume, timer,
-- jobs, consumers, driver. On exit the roles stop in reverse order, the
-- supervisor reaps every process group, and the run's topics and groups are
-- removed.
withReferenceSystem :: RunContext -> SystemSpec -> (RunningSystem -> IO a) -> IO a
withReferenceSystem context spec action =
  withRuntimeResources context (partitionsFrom context.knobs) \resources -> do
    let environment = resources.broker.environment
        TopicName shopTopic = resources.broker.shopEvents
        TopicName warehouseTopic = resources.broker.warehouseEvents
        ConsumerGroupId shopGroup = resources.broker.shopConsumerGroup
        ConsumerGroupId warehouseGroup = resources.broker.warehouseConsumerGroup
        config =
          spec.base
            { shopDatabase = resources.shop.postgres.connectionString,
              warehouseDatabase = resources.warehouse.postgres.connectionString,
              brokers = [address | BrokerAddress address <- (NonEmpty.head environment.lanes).laneBrokers],
              topicPrefix = environment.prefix,
              shopTopic,
              warehouseTopic,
              shopConsumerGroup = shopGroup,
              warehouseConsumerGroup = warehouseGroup
            }
        shop = ContextStore resources.shop.store
        warehouse = ContextStore resources.warehouse.store
    seedShop shop customerCount config.routerFanout
    withJobRuntime config.warehouseDatabase Nothing \jobs -> seedWarehouse warehouse jobs skuCount
    withCheck context \check -> withSupervisor check \supervisor -> do
      children <- newIORef Map.empty
      invocations <- newIORef 0
      lifecycle <- newMVar False
      restarts <- newIORef []
      let system = RunningSystem config shop warehouse resources.shop.postgres resources.warehouse.postgres resources.broker check supervisor children invocations lifecycle restarts
          startRole role = do
            started <- forM [0 .. max 1 config.processesPerRole - 1] \index -> do
              process <- roleProcess check (roleNameText role) index (toJSON (RoleArgs config index))
              child <- spawn supervisor process
              awaitReady child 60000
              sendCommand child CtlStart
              pure child
            modifyIORef' children (Map.insert role started)
      (mapM_ startRole longRunningRoles >> withAsync (superviseRoles system) \_ -> action system) `finally` stopRoles system

processesOf :: RunningSystem -> Text -> IO [Child]
processesOf system role = Map.findWithDefault [] role <$> readIORef system.children

-- | Stop every long-running role in reverse start order and forget it, so a
-- scenario can read what the processes write when they stop (their span
-- files) before the system is torn down.
stopRoles :: RunningSystem -> IO ()
stopRoles system = modifyMVar_ system.lifecycle \_ -> do
  running <- atomicModifyIORef' system.children (Map.empty,)
  forM_ (reverse longRunningRoles) \role ->
    forM_ (Map.findWithDefault [] role running) \child -> void (stopGracefully system.supervisor child 10000)
  pure True

-- | Crash-only supervision: a role process that exits while the system runs
-- is replaced after a short backoff, as a process supervisor would, and its
-- replacement resumes from durable state. The crash-only Kafka consumers
-- rely on this after a persistent transient failure.
superviseRoles :: RunningSystem -> IO ()
superviseRoles system = forever do
  threadDelay 250000
  running <- readIORef system.children
  forM_ (Map.toList running) \(role, members) ->
    forM_ members \child -> do
      exited <- childExitCode child
      case exited of
        Nothing -> pure ()
        Just code -> withMVar system.lifecycle \stopping -> do
          -- A fault injector may have replaced this process while the loop
          -- waited for the lock.
          current <- processesOf system role
          unless (stopping || all (\member -> childPid member /= childPid child) current) (restartExited role child code)
  where
    restartExited role child code = do
      diedAt <- getCurrentTime
      _ <- reapChild system.supervisor child
      let target = processTarget role child
      recordWindow system "restart" target DisturbanceStart
      threadDelay 500000
      _ <- replace system role child "exited" (Text.pack (show code)) diedAt
      recordWindow system "restart" target DisturbanceEnd

-- | SIGKILL one process of a role and start its replacement once it has
-- exited. The window from the signal to the replacement's start is recorded
-- as @fault/sigkill@. Returns the restart, or nothing when the system is
-- stopping or the role has no process at that index.
killAndRestart :: RunningSystem -> Text -> Int -> IO (Maybe RestartRecord)
killAndRestart system role index = withMVar system.lifecycle \stopping ->
  if stopping
    then pure Nothing
    else do
      members <- processesOf system role
      case drop index members of
        [] -> pure Nothing
        child : _ -> do
          let target = processTarget role child
          recordWindow system "fault/sigkill" target DisturbanceStart
          diedAt <- getCurrentTime
          killChild system.supervisor child
          record <- replace system role child "sigkill" "SIGKILL" diedAt
          recordWindow system "fault/sigkill" target DisturbanceEnd
          pure (Just record)

replace :: RunningSystem -> Text -> Child -> Text -> Text -> UTCTime -> IO RestartRecord
replace system role child cause code diedAt = do
  replacement <- restartChild system.supervisor child
  sendCommand replacement CtlStart
  readyAt <- getCurrentTime
  modifyIORef' system.children (Map.adjust (fmap (\member -> if childPid member == childPid child then replacement else member)) role)
  let record = RestartRecord role (childProc child).index cause code diedAt readyAt
  modifyIORef' system.restarts (record :)
  pure record

restartsOf :: RunningSystem -> IO [RestartRecord]
restartsOf system = reverse <$> readIORef system.restarts

-- | Disturbance windows are identified by their label and target, so a
-- window survives a process restart. The role and index name the target.
processTarget :: Text -> Child -> Text
processTarget role child = role <> "/" <> Text.pack (show (childProc child).index)

-- | Record one edge of a labelled disturbance window in the harness ledger.
recordWindow :: RunningSystem -> Text -> Text -> FactKind -> IO ()
recordWindow system label target kind =
  recordDurable system.check.ledger kind target 0 label (KeyMap.fromList [("label", Aeson.String label), ("target", Aeson.String target)])

-- | Deliver a signal to every process of a long-running role. The supervisor
-- records each delivery as a disturbance window.
signalRole :: RunningSystem -> ChildSignal -> Text -> IO ()
signalRole system signal role = processesOf system role >>= mapM_ \child -> signalChild system.supervisor child signal

-- | How often a consumer session ended without a stop request (the
-- adapter's known rebalance exit) and was resumed, per consumer role.
consumerSessionsEnded :: RunningSystem -> IO [(Text, Int)]
consumerSessionsEnded system =
  forM ["a-consumer", "b-consumer"] \role -> do
    consumers <- processesOf system role
    counts <- forM consumers \child -> do
      messages <- readChildMessages child
      pure (length [() | WrkCustom "consumer-session-ended" _ <- messages])
    pure (role, sum counts)

-- | The reports of every driver process that has finished submitting.
driverReports :: RunningSystem -> IO [Maybe DriverReport]
driverReports system = do
  drivers <- processesOf system "driver"
  forM drivers \child -> do
    snapshot <- atomically (progress child)
    pure case Map.lookup "driver-finished" snapshot.marks of
      Nothing -> Nothing
      Just value -> case Aeson.fromJSON value of
        Aeson.Success report -> Just report
        Aeson.Error _ -> Nothing

data QuiescenceReport = QuiescenceReport
  { reached :: !Bool,
    driversFinished :: !Bool,
    secondsAfterDrivers :: !Double,
    submitted :: !Int,
    shopOrders :: !StatusCounts,
    warehouseFulfilments :: !StatusCounts,
    shopBacklog :: !(Maybe Backlog),
    warehouseBacklog :: !(Maybe Backlog),
    stuck :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

instance ToJSON QuiescenceReport where
  toJSON report =
    object
      [ "reached" .= report.reached,
        "driversFinished" .= report.driversFinished,
        "secondsAfterDrivers" .= report.secondsAfterDrivers,
        "submitted" .= report.submitted,
        "shopOrders" .= countsValue report.shopOrders,
        "warehouseFulfilments" .= countsValue report.warehouseFulfilments,
        "shopBacklog" .= fmap backlogValue report.shopBacklog,
        "warehouseBacklog" .= fmap backlogValue report.warehouseBacklog,
        "stuck" .= report.stuck
      ]
    where
      countsValue counts = object ["total" .= counts.total, "byStatus" .= Map.fromList counts.byStatus, "multipleTerminals" .= counts.multipleTerminals]
      backlogValue backlog =
        object
          [ "outboxUnsent" .= backlog.outboxUnsent,
            "inboxUnfinished" .= backlog.inboxUnfinished,
            "intakeUndispatched" .= backlog.intakeUndispatched,
            "workflowsUnfinished" .= backlog.workflowsUnfinished,
            "timersPending" .= backlog.timersPending,
            "awakeablesPending" .= backlog.awakeablesPending
          ]

-- | Wait for every driver to finish, then for the system to drain: every
-- accepted order and every fulfilment terminal, and no unsent outbox row,
-- unfinished inbox or intake row, unfinished workflow or pending timer in
-- either context. The deadline counts from the moment the drivers finished.
awaitQuiescence :: RunningSystem -> NominalDiffTime -> NominalDiffTime -> IO QuiescenceReport
awaitQuiescence system driverDeadline deadline = do
  started <- getCurrentTime
  waitDrivers started
  where
    waitDrivers started = do
      reports <- driverReports system
      now <- getCurrentTime
      if all (/= Nothing) reports
        then waitDrain now [report | Just report <- reports]
        else
          if diffUTCTime now started > driverDeadline
            then observe False 0 []
            else threadDelay 500000 >> waitDrivers started
    waitDrain finishedAt reports = do
      now <- getCurrentTime
      report <- observe True (realToFrac (diffUTCTime now finishedAt)) reports
      if report.reached || diffUTCTime now finishedAt > deadline
        then pure report
        else threadDelay 500000 >> waitDrain finishedAt reports
    observe finished elapsed reports = do
      shopCounts <- either (const (StatusCounts 0 [] 0)) id <$> runSql system.shop orderStatusCountsTx
      warehouseCounts <- either (const (StatusCounts 0 [] 0)) id <$> runSql system.warehouse fulfilmentStatusCountsTx
      shopBacklog <- either (const Nothing) Just <$> runSql system.shop (backlogTx Shop)
      warehouseBacklog <- either (const Nothing) Just <$> runSql system.warehouse (backlogTx Warehouse)
      -- A restarted driver resubmits its share and sees earlier placements as
      -- duplicates, so completeness is judged against the configured order
      -- count, while the drivers' acceptances are reported.
      let submitted = sum [report.accepted | report <- reports]
          expected = if system.config.orders > 0 then system.config.orders else system.config.durationSeconds * max 1 system.config.ratePerSecond
          nonTerminal counts statuses = sum [count | (status, count) <- counts.byStatus, status `elem` statuses]
          drained backlog = case backlog of
            Just value -> value == Backlog 0 0 0 0 0 0
            Nothing -> False
          reached =
            finished
              && shopCounts.total == fromIntegral expected
              && warehouseCounts.total == shopCounts.total
              && nonTerminal shopCounts ["placed"] == (0 :: Int64)
              && nonTerminal warehouseCounts ["requested"] == 0
              && drained shopBacklog
              && drained warehouseBacklog
      stuck <-
        if reached
          then pure Nothing
          else do
            shopStuck <- runSql system.shop (stuckWorkTx Shop)
            warehouseStuck <- runSql system.warehouse (stuckWorkTx Warehouse)
            let render = either (Aeson.String . Text.pack . show) id
            groups <- forM [system.broker.shopConsumerGroup, system.broker.warehouseConsumerGroup] \group -> do
              described <- try @SomeException (describeGroup system.broker.environment group)
              pure case described of
                Left problem -> Aeson.String (Text.pack (displayException problem))
                Right snapshot ->
                  object
                    [ "group" .= (let ConsumerGroupId name = snapshot.group in name),
                      "state" .= snapshot.state,
                      "members" .= length snapshot.members,
                      "partitions"
                        .= [ object ["topic" .= (let TopicName name = offsets.topic in name), "partition" .= (let PartitionId number = offsets.partition in number), "committed" .= offsets.committed, "logEnd" .= offsets.logEnd, "lag" .= offsets.lag]
                           | offsets <- snapshot.offsets
                           ]
                    ]
            pure (Just (object ["shop" .= render shopStuck, "warehouse" .= render warehouseStuck, "consumerGroups" .= groups]))
      pure (QuiescenceReport reached finished elapsed submitted shopCounts warehouseCounts shopBacklog warehouseBacklog stuck)
