module Kenshou.Suite.Pgmq.Concurrency.Runner (runConcurrency) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, mapConcurrently, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (replicateM, void)
import Data.Aeson (Value, decodeStrict', object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as ByteString
import Data.Int (Int64)
import Data.List (sort, sortOn, zip4)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Database.PostgreSQL.LibPQ qualified as LibPQ
import Effectful qualified
import Effectful.Error.Static qualified
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Network (ProxyMode (..), proxiedConnectionString, resetConnections, setProxyMode, withTcpProxy)
import Kenshou.Check.Fault.Postgres (BackendSelector (..), CrashMode (..), crashPostmaster, terminateBackends)
import Kenshou.Check.Process
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (Contract), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (ArtifactDir (VerdictsDir), RunContext (..), SummarySection (Verdicts), artifactPath, declareMediaType, putSummary, requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Knob (knobInt, knobText)
import Kenshou.Core.Role (ControlMessage (CtlStart), WorkerMessage (WrkCustom))
import Kenshou.Core.Scenario (ScenarioReport, failedWith, passed)
import Kenshou.Suite.Pgmq.Facts (PgmqFact (Leased))
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), knobName)
import Kenshou.Suite.Pgmq.Listener (Notification (..), awaitNotifications, withListener, withListeners)
import Kenshou.Suite.Pgmq.Oracle (checkLeaseIntervals)
import Pgmq.Config qualified as Config
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Effectful.Effect qualified as PgmqEff
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Types
import Pgmq.Types qualified as PgmqTypes

runConcurrency :: Text -> RunContext -> Maybe (IO ScenarioReport)
runConcurrency identifier context = fmap guarded (lookup identifier runners)
  where
    guarded scenario = do
      result <- try @SomeException (scenario context)
      pure $ either (failedWith ["scenario-exception"] . Text.pack . show) id result

runners :: [(Text, RunContext -> IO ScenarioReport)]
runners =
  [ ("pgmq/read/concurrency/no-double-lease-threads", noDoubleLeaseThreads),
    ("pgmq/read/concurrency/no-double-lease-processes", noDoubleLeaseProcesses),
    ("pgmq/vt/concurrency/crash-redelivery-read-count", crashRedeliveryReadCount),
    ("pgmq/ack/concurrency/random-sigkill-at-least-once", randomSigkill),
    ("pgmq/send/concurrency/producer-sigkill-batch-atomicity", producerBatchAtomicity),
    ("pgmq/ack/concurrency/stale-ack-after-expiry", staleAckAfterExpiry),
    ("pgmq/read/concurrency/pool-exhaustion-long-poll", poolExhaustion),
    ("pgmq/effectful/concurrency/backend-termination-recovery", backendTermination),
    ("pgmq/effectful/concurrency/postgres-restart-recovery", postgresRestart),
    ("pgmq/queue/concurrency/unlogged-queue-crash-loss", unloggedCrashLoss),
    ("pgmq/effectful/concurrency/network-partition", networkPartition),
    ("pgmq/fifo/concurrency/head-per-group-barrier", headPerGroupBarrier),
    ("pgmq/fifo/concurrency/grouped-batch-successor-hazard", groupedBatchHazard),
    ("pgmq/fifo/concurrency/producer-commit-order-inversion", producerCommitOrderInversion),
    ("pgmq/notify/concurrency/partitioned-notify-storm", partitionedNotifyStorm),
    ("pgmq/notify/concurrency/throttle-lost-after-crash", throttleLostAfterCrash),
    ("pgmq/notify/concurrency/listener-loss-poll-fallback", listenerLossFallback),
    ("pgmq/queue/concurrency/partition-retention-drops-unread", partitionRetention),
    ("pgmq/config/concurrency/concurrent-reconcile", concurrentReconcile),
    ("pgmq/ack/concurrency/overlapping-batch-ack-deadlock", overlappingBatchAck)
  ]

noDoubleLeaseThreads :: RunContext -> IO ScenarioReport
noDoubleLeaseThreads context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "lease_threads" \queue -> do
    let messageCount = min 5000 (fromIntegral (knobInt context.knobs (knobName "pgmq.message-count")))
        consumers = max 2 (min 32 (fromIntegral (knobInt context.knobs (knobName "pgmq.consumers")))) :: Int
        sabotage = knobText context.knobs (knobName "pgmq.sabotage")
    probeId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (body 0) Nothing))
    gate <- newEmptyMVar
    readers <- async (mapConcurrently (const (readProbe runtime queue sabotage gate)) [1 .. consumers])
    threadDelay 50000
    putMVar gate ()
    probeReads <- concat <$> wait readers
    let owners = length (filter (== probeId) probeReads)
    putSummary context Verdicts "lease-race-observations" (object ["readers" .= consumers, "owners" .= owners, "sabotage" .= sabotage])
    if sabotage == "unlocked-read"
      then verdict context "no-double-lease-threads" [("probe-read-by-every-reader", owners == consumers), ("unique-ownership", owners <= 1)]
      else do
        _ <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue probeId))
        sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. messageCount]) Nothing))
        observed <- newMVar []
        _ <- mapConcurrently (const (drain runtime queue observed)) [1 .. consumers]
        deliveries <- readMVar observed
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        verdict context "no-double-lease-threads" [("single-probe-owner", owners == 1), ("all-handled", sort deliveries == sort sent), ("unique-ownership", Set.size (Set.fromList deliveries) == length deliveries), ("queue-empty", metrics.queueLength == 0)]

readProbe :: PgmqRun -> Pgmq.QueueName -> Text -> MVar () -> IO [Pgmq.MessageId]
readProbe runtime queue sabotage gate = do
  readMVar gate
  if sabotage == "unlocked-read"
    then fmap Pgmq.MessageId <$> session runtime.pool (Session.statement () (unlockedRead queue))
    else fmap (.messageId) . Vector.toList <$> effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))

unlockedRead :: Pgmq.QueueName -> Statement.Statement () [Int64]
unlockedRead queue =
  Statement.unpreparable
    ("select msg_id from pgmq.\"q_" <> Pgmq.queueNameToText queue <> "\" order by msg_id limit 1")
    Encoders.noParams
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int8)))

noDoubleLeaseProcesses :: RunContext -> IO ScenarioReport
noDoubleLeaseProcesses context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "lease_processes" \queue -> do
    let count = 1000
        processCount = min 8 (fromIntegral (knobInt context.knobs (knobName "pgmq.processes")))
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "batchSize" .= (25 :: Int), "visibilityTimeout" .= (5 :: Int), "acknowledge" .= True]
    sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. count]) Nothing))
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        specs <- traverse (\index -> roleProcess checkEnvironment "pgmq/pgmq-consumer" index arguments) [1 .. processCount]
        children <- traverse (spawn supervisor) specs
        mapM_ (`awaitReady` 10000) children
        mapM_ (`sendCommand` CtlStart) children
        drained <- awaitQueueDrain runtime queue 100
        marks <- concat <$> traverse (readWorkerLeaseMarks context) [1 .. processCount]
        let leases = concatMap (mapMaybe leaseFact) marks
            observedIds = [PgmqTypes.MessageId identifier | Leased _ identifier _ _ _ _ <- leases]
            findings = checkLeaseIntervals leases
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        putSummary context Verdicts "process-lease-observations" (object ["readMarks" .= length marks, "leases" .= length leases, "findings" .= fmap show findings])
        verdict context "no-double-lease-processes" [("worker-processes", length children == processCount), ("all-sent-seen", Set.fromList observedIds == Set.fromList sent), ("lease-times-present", length leases == sum (fmap length marks)), ("no-overlapping-or-duplicate-leases", null findings), ("eventual-quiescence", drained && metrics.queueLength == 0)]

leaseFact :: (Pgmq.MessageId, Int64, UTCTime, Maybe UTCTime) -> Maybe PgmqFact
leaseFact (identifier, readCount, visibleAt, readAt) =
  Leased "" (PgmqTypes.unMessageId identifier) readCount <$> readAt <*> pure visibleAt <*> pure Nothing

readWorkerLeaseMarks :: RunContext -> Int -> IO [[(Pgmq.MessageId, Int64, UTCTime, Maybe UTCTime)]]
readWorkerLeaseMarks context index = do
  let path = context.outDir <> "/logs/pgmq-pgmq-consumer-" <> show index <> ".0.control.jsonl"
  linesOfOutput <- ByteString.lines <$> ByteString.readFile path
  messages <- maybe (ioError (userError ("invalid worker control log: " <> path))) pure (traverse decodeStrict' linesOfOutput)
  filter (not . null)
    <$> traverse
      ( \case
          WrkCustom "after-read" payload -> maybe (ioError (userError ("invalid lease mark: " <> path))) pure (parseLeaseMark payload)
          _ -> pure []
      )
      messages

awaitQueueDrain :: PgmqRun -> Pgmq.QueueName -> Int -> IO Bool
awaitQueueDrain runtime queue attempts = do
  metrics <- effect runtime (Pgmq.queueMetrics queue)
  if metrics.queueLength == 0
    then pure True
    else if attempts <= 1 then pure False else threadDelay 100000 >> awaitQueueDrain runtime queue (attempts - 1)

crashRedeliveryReadCount :: RunContext -> IO ScenarioReport
crashRedeliveryReadCount context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "crash_redelivery" \queue -> do
    let kills = max 1 (min 10 (fromIntegral (knobInt context.knobs (knobName "pgmq.kills"))))
        messageCount = min 100 (fromIntegral (knobInt context.knobs (knobName "pgmq.message-count")))
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "batchSize" .= messageCount, "visibilityTimeout" .= (1 :: Int), "acknowledge" .= False, "holdAfterRead" .= True]
    sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. messageCount]) Nothing))
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        observations <-
          traverse
            ( \index -> do
                spec <- roleProcess checkEnvironment "pgmq/pgmq-consumer" index arguments
                child <- spawn supervisor spec
                awaitReady child 10000
                sendCommand child CtlStart
                awaitMark child "after-read" 10000
                snapshot <- atomically (progress child)
                observation <- maybe (ioError (userError "worker omitted after-read lease evidence")) pure (Map.lookup "after-read" snapshot.marks >>= parseLeaseMark)
                killChild supervisor child
                threadDelay 1050000
                pure observation
            )
            [1 .. kills]
        final <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just (fromIntegral messageCount)) Nothing))
        let values = Vector.toList final
            expectedIds = sort sent
            sameKeys = all ((== expectedIds) . sort . fmap (\(identifier, _, _, _) -> identifier)) observations
            expectedCounts = and [all (\(_, count, _, _) -> count == fromIntegral index) lease | (index, lease) <- zip [1 :: Int ..] observations]
            orderedObservations = fmap (sortOn (\(identifier, _, _, _) -> identifier)) observations
            orderedFinal = sortOn (.messageId) values
            completeReadTimes = all (all (isJust . (\(_, _, _, readAt) -> readAt))) observations && all (isJust . (.lastReadAt)) values
            noEarlyRedelivery = and [and [identifier == nextId && maybe False (>= visibleAt) readAt | ((identifier, _, visibleAt, _), (nextId, _, _, readAt)) <- zip previous next] | (previous, next) <- zip orderedObservations (drop 1 orderedObservations)]
            finalOnTime = and [identifier == message.messageId && maybe False (>= visibleAt) message.lastReadAt | ((identifier, _, visibleAt, _), message) <- zip (last orderedObservations) orderedFinal]
            boundedRedelivery = and [and [maybe False (\observedAt -> diffUTCTime observedAt visibleAt <= 1) readAt | ((_, _, visibleAt, _), (_, _, _, readAt)) <- zip previous next] | (previous, next) <- zip orderedObservations (drop 1 orderedObservations)]
            finalWithinBound = and [maybe False (\observedAt -> diffUTCTime observedAt visibleAt <= 1) message.lastReadAt | ((_, _, visibleAt, _), message) <- zip (last orderedObservations) orderedFinal]
        deleted <- effect runtime (Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue (fmap (.messageId) values)))
        putSummary context Verdicts "crash-redelivery-observations" (object ["kills" .= kills, "leases" .= observations, "finalDeliveries" .= [object ["id" .= message.messageId, "readCount" .= message.readCount, "readAt" .= message.lastReadAt] | message <- values]])
        verdict context "crash-redelivery" [("all-kill-rounds-leased", sameKeys), ("read-count-sequence", expectedCounts), ("database-read-times-present", completeReadTimes), ("no-early-redelivery", noEarlyRedelivery && finalOnTime), ("redelivery-within-one-second", boundedRedelivery && finalWithinBound), ("all-redelivered", sort (fmap (.messageId) values) == expectedIds), ("read-count-accounting", all ((== fromIntegral (kills + 1)) . (.readCount)) values), ("final-ack", sort deleted == expectedIds)]

parseLeaseMark :: Value -> Maybe [(Pgmq.MessageId, Int64, UTCTime, Maybe UTCTime)]
parseLeaseMark value = do
  (identifiers, counts, visibleTimes, readTimes) <-
    parseMaybe (withObject "after-read" \entry -> (,,,) <$> entry .: "ids" <*> entry .: "readCounts" <*> entry .: "visibleAt" <*> entry .: "readAt") value
  if length identifiers == length counts && length counts == length visibleTimes && length visibleTimes == length readTimes
    then Just (zip4 identifiers counts visibleTimes readTimes)
    else Nothing

randomSigkill :: RunContext -> IO ScenarioReport
randomSigkill context = crashRedeliveryReadCount context

producerBatchAtomicity :: RunContext -> IO ScenarioReport
producerBatchAtomicity context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "producer_kill" \queue -> do
    let batchSize = fromIntegral runtime.knobs.batchSize :: Int
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "count" .= batchSize, "batchSize" .= batchSize]
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        spec <- roleProcess checkEnvironment "pgmq/pgmq-producer" 1 arguments
        child <- spawn supervisor spec
        awaitReady child 10000
        sendCommand child CtlStart
        threadDelay 1000
        _ <- try @SomeException (killChild supervisor child)
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        verdict context "producer-batch-atomicity" [("all-or-nothing", metrics.queueLength == 0 || metrics.queueLength == fromIntegral batchSize)]

staleAckAfterExpiry :: RunContext -> IO ScenarioReport
staleAckAfterExpiry context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "stale_ack" \queue -> do
    messageId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (body 1) Nothing))
    first <- only =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just 1) Nothing))
    threadDelay 1050000
    second <- only =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
    staleDeleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue messageId))
    currentDeleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue messageId))
    extension <- effect runtime (Pgmq.changeVisibilityTimeout (Types.VisibilityTimeoutQuery queue messageId 30))
    verdict context "stale-ack" [("redelivered", first.messageId == second.messageId && second.readCount == 2), ("stale-delete-wins", staleDeleted && not currentDeleted), ("no-fencing", maybe True (const False) extension)]

poolExhaustion :: RunContext -> IO ScenarioReport
poolExhaustion context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "pool_exhaustion" \queue -> do
    let constrained = runtime.knobs {poolSize = 2, acquisitionTimeoutSeconds = 1}
    withPgmqPool (requirePostgres context) "starvation" constrained \pool -> do
      pollers <- replicateM 2 (async (runOps Nothing pool (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 Nothing 2 100 Nothing))))
      threadDelay 200000
      starved <- runOps Nothing pool (Pgmq.sendMessage (Types.SendMessage queue (body 1) Nothing))
      _ <- traverse wait pollers
      recovered <- runOps Nothing pool (Pgmq.sendMessage (Types.SendMessage queue (body 2) Nothing))
      verdict context "pool-exhaustion" [("acquisition-times-out", either Pgmq.isTransient (const False) starved), ("pool-recovers", either (const False) (const True) recovered)]

backendTermination :: RunContext -> IO ScenarioReport
backendTermination context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "backend_termination" \queue -> do
    waiting <- async (runOps runtime.tracer runtime.pool (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 Nothing 5 100 Nothing)))
    threadDelay 200000
    let fault = terminateBackends (requirePostgres context) (ByApplicationName "kenshou-pgmq-%")
    handle <- fault.inject
    interrupted <- wait waiting
    handle.heal
    recovered <- retry 20 (runOps runtime.tracer runtime.pool (Pgmq.sendMessage (Types.SendMessage queue (body 1) Nothing)))
    putSummary context Verdicts "backend-termination-observations" (object ["interrupted" .= show interrupted, "recovered" .= show recovered])
    verdict context "backend-termination" [("transient-error", either Pgmq.isTransient (const False) interrupted), ("same-pool-recovers", either (const False) (const True) recovered)]

postgresRestart :: RunContext -> IO ScenarioReport
postgresRestart context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "restart" \queue -> do
    sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. 20]) Nothing))
    let fault = crashPostmaster (requirePostgres context) ImmediateShutdown
    handle <- fault.inject
    handle.heal
    messages <- retryValue 50 (runOps runtime.tracer runtime.pool (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 20) Nothing)))
    verdict context "postgres-restart" [("committed-survives", sort (fmap (.messageId) (Vector.toList messages)) == sort sent)]

unloggedCrashLoss :: RunContext -> IO ScenarioReport
unloggedCrashLoss context = withPgmqRun context \runtime -> do
  let standard = scenarioQueueName context "logged"
      unlogged = scenarioQueueName context "unlogged"
  _ <- effect runtime (Pgmq.createQueue standard)
  _ <- effect runtime (Pgmq.createUnloggedQueue unlogged)
  (`finally` cleanupQueues runtime [standard, unlogged]) do
    _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage standard (fmap body [1 .. 20]) Nothing))
    _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage unlogged (fmap body [1 .. 20]) Nothing))
    let fault = crashPostmaster (requirePostgres context) ImmediateShutdown
    handle <- fault.inject
    handle.heal
    loggedMetrics <- retryValue 50 (runOps runtime.tracer runtime.pool (Pgmq.queueMetrics standard))
    unloggedMetrics <- effect runtime (Pgmq.queueMetrics unlogged)
    verdict context "unlogged-crash" [("logged-survives", loggedMetrics.queueLength == 20), ("unlogged-lost", unloggedMetrics.queueLength == 0)]

networkPartition :: RunContext -> IO ScenarioReport
networkPartition context = case (requirePostgres context).tcpEndpoint of
  Nothing -> pure (failedWith ["tcp-endpoint"] "PostgreSQL fixture has no TCP endpoint")
  Just (host, port) ->
    withTcpProxy (pure (Text.unpack host, fromIntegral port)) \proxy ->
      withPgmqRun context \runtime ->
        withScenarioQueue runtime.pool context runtime.knobs "network" \queue -> do
          let proxied = (requirePostgres context) {connectionString = proxiedConnectionString (requirePostgres context) proxy}
          withPgmqPool proxied "proxy" runtime.knobs \pool -> do
            baseline <- runOps Nothing pool (Pgmq.sendMessage (Types.SendMessage queue (body 1) Nothing))
            _ <- resetConnections proxy
            resetResult <- runOps Nothing pool (Pgmq.sendMessage (Types.SendMessage queue (body 2) Nothing))
            setProxyMode proxy Forward
            recovered <- retry 20 (runOps Nothing pool (Pgmq.sendMessage (Types.SendMessage queue (body 3) Nothing)))
            putSummary context Verdicts "network-partition-observations" (object ["reset" .= show resetResult, "recovered" .= show recovered])
            verdict context "network-partition" [("baseline", isRight baseline), ("reset-transient", either Pgmq.isTransient (const True) resetResult), ("recovery", isRight recovered)]

headPerGroupBarrier :: RunContext -> IO ScenarioReport
headPerGroupBarrier context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "head_barrier" \queue -> do
    _ <- effect runtime (Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (fmap body [1 .. 100]) [Pgmq.MessageHeaders (object ["x-pgmq-group" .= ("g" <> Text.pack (show (index `mod` 10)) :: Text)]) | index <- [1 :: Int .. 100]] Nothing))
    batches <- mapConcurrently (const (effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 2 10)))) [1 :: Int .. 8]
    let messages = concatMap Vector.toList batches
        groups = fmap (.headers) messages
    verdict context "head-per-group" [("one-live-head-per-group", length messages <= 10 && Set.size (Set.fromList groups) == length groups)]

groupedBatchHazard :: RunContext -> IO ScenarioReport
groupedBatchHazard context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "grouped_hazard" \queue -> do
    _ <- effect runtime (Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (fmap body [1 .. 10]) (replicate 10 (Pgmq.MessageHeaders (object ["x-pgmq-group" .= ("one" :: Text)]))) Nothing))
    grouped <- effect runtime (Pgmq.readGrouped (Types.ReadGrouped queue 30 10))
    verdict context "grouped-successor-hazard" [("successors-leased-with-head", Vector.length grouped == 10)]

producerCommitOrderInversion :: RunContext -> IO ScenarioReport
producerCommitOrderInversion context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "commit_inversion" \queue -> do
    first <-
      async
        ( session runtime.pool do
            Session.statement () begin
            messageId <- Sessions.sendMessageWithHeaders (Types.SendMessageWithHeaders queue (body 1) (Pgmq.MessageHeaders (object ["x-pgmq-group" .= ("g" :: Text)])) Nothing)
            Session.statement () sleepOne
            Session.statement () commit
            pure messageId
        )
    threadDelay 100000
    secondId <- session runtime.pool (Sessions.sendMessageWithHeaders (Types.SendMessageWithHeaders queue (body 2) (Pgmq.MessageHeaders (object ["x-pgmq-group" .= ("g" :: Text)])) Nothing))
    visible <- only =<< effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 30 1))
    firstId <- wait first
    verdict context "commit-order-inversion" [("identifier-order", firstId < secondId), ("commit-order-wins-visibility", visible.messageId == secondId)]

partitionedNotifyStorm :: RunContext -> IO ScenarioReport
partitionedNotifyStorm context = withPgmqRun context \runtime -> do
  support <- requirePartman runtime.pool
  case support of
    Left message -> pure (failedWith ["pg-partman"] message)
    Right () -> do
      let queue = scenarioQueueName context "notify_storm"
      _ <- effect runtime (Pgmq.createPartitionedQueue (Types.CreatePartitionedQueue queue "10000" "100000"))
      (`finally` cleanupQueues runtime [queue]) do
        _ <- effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just 250)))
        partitions <- session runtime.pool (Session.statement (Pgmq.queueNameToText queue) partitionNames)
        let canonical = PgmqTypes.notifyChannelName queue
            channels = canonical : fmap (\partition -> "pgmq." <> partition <> ".INSERT") partitions
            messageCount = 1000
            threshold = 5000 `div` 250 + 1
        (enabledSeconds, notifications) <-
          withListeners (requirePostgres context).connectionString channels \connection -> do
            elapsed <- timedSeconds $ void $ mapConcurrently (sendOne runtime queue) [1 .. messageCount]
            observed <- collectNotifications connection
            pure (elapsed, observed)
        _ <- effect runtime (Pgmq.disableNotifyInsert queue)
        disabledSeconds <- timedSeconds $ void $ mapConcurrently (sendOne runtime queue) [messageCount + 1 .. messageCount * 2]
        let observedCount = length notifications
            partitionCount = length [() | notification <- notifications, notification.channel /= canonical]
        putSummary
          context
          Verdicts
          "partitioned-notify-storm-observations"
          ( object
              [ "notifications" .= observedCount,
                "partitionNotifications" .= partitionCount,
                "allowedByThrottle" .= threshold,
                "channels" .= channels,
                "sendSecondsWithNotify" .= enabledSeconds,
                "sendSecondsWithoutNotify" .= disabledSeconds
              ]
          )
        if observedCount > threshold && partitionCount == observedCount
          then pure (failedWith ["known-defect"] ("observed " <> Text.pack (show observedCount) <> " unthrottled notifications on partition channels; allowed " <> Text.pack (show threshold)))
          else verdict context "partitioned-notify-storm" [("notifications-observed", observedCount > 0), ("throttle-bounded", observedCount <= threshold), ("canonical-channel", partitionCount == 0)]

throttleLostAfterCrash :: RunContext -> IO ScenarioReport
throttleLostAfterCrash context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "throttle_crash" \queue -> do
    _ <- effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just 1000)))
    before <- effect runtime Pgmq.listNotifyInsertThrottles
    let fault = crashPostmaster (requirePostgres context) ImmediateShutdown
    handle <- fault.inject
    handle.heal
    after <- retryValue 50 (runOps runtime.tracer runtime.pool Pgmq.listNotifyInsertThrottles)
    report <- session runtime.pool (Config.ensureQueuesReport [Config.withNotifyInsert (Just 1000) (Config.standardQueue queue)])
    let reenabled = any (\case Config.EnabledNotify {} -> True; _ -> False) report
    verdict context "throttle-crash" [("configured-before", not (null before)), ("unlogged-state-lost", null after), ("reconcile-restores", reenabled)]

listenerLossFallback :: RunContext -> IO ScenarioReport
listenerLossFallback context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "listener_fallback" \queue -> do
    _ <- effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just 0)))
    let listenerConnection = (requirePostgres context).connectionString <> " application_name=kenshou-pgmq-listener"
        channel = PgmqTypes.notifyChannelName queue
        fallbackSeconds = fromIntegral (knobInt context.knobs (knobName "pgmq.poll.fallback-seconds")) :: Int
    listener <- async (try @SomeException (withListener listenerConnection channel (\connection -> awaitNotifications connection 5000)))
    threadDelay 200000
    faultHandle <- (terminateBackends (requirePostgres context) (ByApplicationName "kenshou-pgmq-listener")).inject
    sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. 20]) Nothing))
    cancel listener
    missed <- withListener listenerConnection channel (\connection -> awaitNotifications connection 300)
    started <- getMonotonicTimeNSec
    polled <- effect runtime (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 (Just 20) (fromIntegral fallbackSeconds) 100 Nothing))
    finished <- getMonotonicTimeNSec
    faultHandle.heal
    let elapsedSeconds = fromIntegral (finished - started) / 1000000000 :: Double
    putSummary context Verdicts "listener-loss-observations" (object ["missedWhileDisconnected" .= null missed, "fallbackSeconds" .= fallbackSeconds, "deliverySeconds" .= elapsedSeconds, "handled" .= Vector.length polled])
    verdict context "listener-fallback" [("disconnected-notifications-do-not-replay", null missed), ("poll-fallback-drains", sort (fmap (.messageId) (Vector.toList polled)) == sort sent), ("delivery-within-bound", elapsedSeconds <= fromIntegral fallbackSeconds + 1)]

partitionRetention :: RunContext -> IO ScenarioReport
partitionRetention context = withPgmqRun context \runtime -> do
  support <- requirePartman runtime.pool
  case support of
    Left message -> pure (failedWith ["pg-partman"] message)
    Right () -> do
      let queue = scenarioQueueName context "partition_retention"
          queueText = Pgmq.queueNameToText queue
          firstChunk = [1 .. 100]
          remainingChunks = [[start .. start + 99] | start <- [101, 201 .. 1901]]
      _ <- effect runtime (Pgmq.createPartitionedQueue (Types.CreatePartitionedQueue queue "100" "200"))
      (`finally` cleanupQueues runtime [queue]) do
        firstIds <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body firstChunk) Nothing))
        session runtime.pool (Session.statement queueText runPartmanMaintenance)
        leased <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 5 (Just 50) Nothing))
        remainingIds <-
          fmap concat $
            traverse
              ( \chunk -> do
                  identifiers <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body chunk) Nothing))
                  session runtime.pool (Session.statement queueText runPartmanMaintenance)
                  pure identifiers
              )
              remainingChunks
        session runtime.pool (Session.statement queueText runPartmanMaintenance)
        threadDelay 5100000
        handledVar <- newMVar []
        drain runtime queue handledVar
        handled <- readMVar handledVar
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        let sent = firstIds <> remainingIds
            lost = Set.toList (Set.fromList sent `Set.difference` Set.fromList handled)
            leasedIds = fmap (.messageId) (Vector.toList leased)
            lostLeased = Set.toList (Set.fromList leasedIds `Set.intersection` Set.fromList lost)
        putSummary
          context
          Verdicts
          "partition-retention-observations"
          ( object
              [ "sent" .= length sent,
                "handled" .= length handled,
                "lost" .= length lost,
                "leasedBeforeMaintenance" .= length leasedIds,
                "lostWhileLeased" .= length lostLeased,
                "queueLengthAfterDrain" .= metrics.queueLength,
                "defaultPartitionLength" .= metrics.defaultPartitionLength
              ]
          )
        if null lost
          then verdict context "partition-retention" [("all-sent-handled", sort handled == sort sent), ("queue-drained", metrics.queueLength == 0)]
          else pure (failedWith ["known-defect"] ("partition retention dropped " <> Text.pack (show (length lost)) <> " messages, including " <> Text.pack (show (length lostLeased)) <> " leased messages"))

concurrentReconcile :: RunContext -> IO ScenarioReport
concurrentReconcile context = withPgmqRun context \runtime -> do
  let queue = scenarioQueueName context "concurrent_reconcile"
      declaration = Config.withNotifyInsert (Just 250) . Config.withFifoIndex $ Config.standardQueue queue
  results <- mapConcurrently (const (Pool.use runtime.pool (Config.ensureQueuesReport [declaration]))) [1 :: Int .. 8]
  queues <- effect runtime PgmqEff.listQueues
  _ <- effect runtime (Pgmq.dropQueue queue)
  verdict context "concurrent-reconcile" [("no-errors", all isRight results), ("one-final-queue", length (filter ((== queue) . (.name)) queues) == 1)]

overlappingBatchAck :: RunContext -> IO ScenarioReport
overlappingBatchAck context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "overlap_ack" \queue -> do
    identifiers <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. 200]) Nothing))
    let slices = [take 100 (drop offset (cycle identifiers)) | offset <- [0, 13 .. 195]]
    results <- mapConcurrently (runOps runtime.tracer runtime.pool . Pgmq.batchDeleteMessages . Types.BatchMessageQuery queue) slices
    metrics <- effect runtime (Pgmq.queueMetrics queue)
    let affected = concat [values | Right values <- results]
        allTransient = all (either Pgmq.isTransient (const True)) results
    verdict context "overlapping-batch-ack" [("errors-transient", allTransient), ("affected-once", Set.size (Set.fromList affected) == length affected), ("queue-drained", metrics.queueLength == 0)]

drain :: PgmqRun -> Pgmq.QueueName -> MVar [Pgmq.MessageId] -> IO ()
drain runtime queue observed = do
  messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just runtime.knobs.batchSize) Nothing))
  if Vector.null messages
    then pure ()
    else do
      let identifiers = fmap (.messageId) (Vector.toList messages)
      _ <- effect runtime (Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue identifiers))
      modifyMVar_ observed (pure . (<> identifiers))
      drain runtime queue observed

effect :: PgmqRun -> Effectful.Eff '[Pgmq.Pgmq, Effectful.Error.Static.Error Pgmq.PgmqRuntimeError, Effectful.IOE] value -> IO value
effect runtime action = either (throwIO . userError . show) pure =<< runOps runtime.tracer runtime.pool action

session :: Pool.Pool -> Session.Session value -> IO value
session pool action = either (throwIO . userError . show) pure =<< Pool.use pool action

verdict :: RunContext -> Text -> [(Text, Bool)] -> IO ScenarioReport
verdict context name checks = do
  putSummary context Verdicts name (object ["checks" .= [object ["name" .= label, "passed" .= ok] | (label, ok) <- checks]])
  let failures = [label | (label, False) <- checks]
  checkedAt <- getCurrentTime
  directory <- artifactPath context VerdictsDir ""
  _ <- writeVerdict directory (RunInfo context.runId context.scenario) (simpleVerdict name checks failures checkedAt)
  declareMediaType context ("verdicts/" <> sanitiseChecker name <> ".json") "application/json"
  pure $ if null failures then passed else failedWith failures (name <> " failed: " <> Text.intercalate ", " failures)

simpleVerdict :: Text -> [(Text, Bool)] -> [Text] -> UTCTime -> Verdict
simpleVerdict name checks failures checkedAt =
  Verdict
    { checker = name,
      invariant = name,
      cls = Contract,
      status = if null failures then Held else Violated,
      reason = if null failures then Nothing else Just (name <> " failed: " <> Text.intercalate ", " failures),
      summary = if null failures then name <> " held" else name <> " violated",
      counts = Map.fromList [("examined", fromIntegral (length checks)), ("violations", fromIntegral (length failures))],
      parameters = object ["checks" .= [object ["name" .= label, "passed" .= ok] | (label, ok) <- checks]],
      counterExamples = [object ["check" .= label] | label <- failures],
      counterExamplesTruncated = False,
      inputs = [],
      replay = Nothing,
      checkedAt,
      durationMillis = 0
    }

sanitiseChecker :: Text -> FilePath
sanitiseChecker = fmap (\character -> if character == '/' then '-' else character) . Text.unpack

body :: Int -> Pgmq.MessageBody
body index = Pgmq.MessageBody (object ["k" .= ("message-" <> Text.pack (show index) :: Text)])

only :: Vector.Vector Pgmq.Message -> IO Pgmq.Message
only messages = case Vector.toList messages of [message] -> pure message; values -> ioError (userError ("expected one message, got " <> show (length values)))

retry :: Int -> IO (Either error value) -> IO (Either error value)
retry attempts action =
  action >>= \case
    result@(Right _) -> pure result
    result@(Left _) | attempts <= 1 -> pure result
    Left _ -> threadDelay 100000 >> retry (attempts - 1) action

retryValue :: (Show error) => Int -> IO (Either error value) -> IO value
retryValue attempts action = retry attempts action >>= either (throwIO . userError . show) pure

cleanupQueues :: PgmqRun -> [Pgmq.QueueName] -> IO ()
cleanupQueues runtime = mapM_ (\queue -> void (runOps Nothing runtime.pool (Pgmq.dropQueue queue)))

isRight :: Either left right -> Bool
isRight = either (const False) (const True)

begin, commit, sleepOne :: Statement.Statement () ()
begin = command "begin"
commit = command "commit"
sleepOne = command "select from pg_sleep(1)"

command :: Text -> Statement.Statement () ()
command sql = Statement.unpreparable sql Encoders.noParams Decoders.noResult

partitionNames :: Statement.Statement Text [Text]
partitionNames =
  Statement.unpreparable
    "select child.relname::text from pg_inherits inheritance join pg_class child on child.oid=inheritance.inhrelid where inheritance.inhparent=to_regclass('pgmq.q_' || $1) order by child.relname"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

runPartmanMaintenance :: Statement.Statement Text ()
runPartmanMaintenance =
  Statement.unpreparable
    "select from partman.run_maintenance('pgmq.q_' || $1)"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

sendOne :: PgmqRun -> Pgmq.QueueName -> Int -> IO Pgmq.MessageId
sendOne runtime queue index = effect runtime (Pgmq.sendMessage (Types.SendMessage queue (body index) Nothing))

collectNotifications :: LibPQ.Connection -> IO [Notification]
collectNotifications connection = go []
  where
    go accumulated = do
      notifications <- awaitNotifications connection 250
      if null notifications then pure accumulated else go (accumulated <> notifications)

timedSeconds :: IO value -> IO Double
timedSeconds action = do
  started <- getMonotonicTimeNSec
  _ <- action
  finished <- getMonotonicTimeNSec
  pure (fromIntegral (finished - started) / 1000000000)
