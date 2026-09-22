module Kenshou.Suite.Pgmq.Concurrency.Runner (runConcurrency) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, mapConcurrently, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, SomeException, finally, throwIO, try)
import Control.Monad (forM, replicateM, void)
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
import Kenshou.Check.Fact (ProcId (..))
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Network (ProxyMode (..), proxiedConnectionString, resetConnections, setProxyMode, withTcpProxy)
import Kenshou.Check.Fault.Postgres (BackendSelector (..), CrashMode (..), crashPostmaster, terminateBackends)
import Kenshou.Check.Process
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (Contract, Implementation), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (ArtifactDir (VerdictsDir), RunContext (..), SummarySection (Verdicts), artifactPath, declareMediaType, putSummary, requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Knob (knobInt, knobText)
import Kenshou.Core.Role (ControlMessage (CtlStart), WorkerMessage (WrkCustom, WrkFacts))
import Kenshou.Core.Scenario (ScenarioReport, failedWith, passed)
import Kenshou.Suite.Pgmq.Facts (PgmqFact (Leased))
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), knobName)
import Kenshou.Suite.Pgmq.Listener (Notification (..), awaitNotifications, withListener, withListeners)
import Kenshou.Suite.Pgmq.Oracle (checkLeaseIntervals, queueKeys)
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
noDoubleLeaseProcesses context
  | knobText context.knobs (knobName "pgmq.sabotage") == "unlocked-read" = noDoubleLeaseProcessSabotage context
  | otherwise = withPgmqRun context \runtime ->
      withScenarioQueue runtime.pool context runtime.knobs "lease_processes" \queue -> do
        let count = 1000
            processCount = min 8 (fromIntegral (knobInt context.knobs (knobName "pgmq.processes")))
            producerCount = max 2 (min 4 (fromIntegral (knobInt context.knobs (knobName "pgmq.producers"))))
            messagesPerProducer = 100
            arguments = object ["queue" .= Pgmq.queueNameToText queue, "batchSize" .= (25 :: Int), "visibilityTimeout" .= (5 :: Int), "acknowledge" .= True]
            producerArguments = object ["queue" .= Pgmq.queueNameToText queue, "count" .= messagesPerProducer, "batchSize" .= messagesPerProducer]
        sent <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap body [1 .. count]) Nothing))
        withCheck context \checkEnvironment ->
          withSupervisor checkEnvironment \supervisor -> do
            specs <- traverse (\index -> roleProcess checkEnvironment "pgmq/pgmq-consumer" index arguments) [1 .. processCount]
            children <- traverse (spawn supervisor) specs
            producerSpecs <- traverse (\index -> roleProcess checkEnvironment "pgmq/pgmq-producer" index producerArguments) [1 .. producerCount]
            producers <- traverse (spawn supervisor) producerSpecs
            mapM_ (`awaitReady` 10000) children
            mapM_ (`awaitReady` 10000) producers
            mapM_ (`sendCommand` CtlStart) children
            mapM_ (`sendCommand` CtlStart) producers
            produced <- traverse (\(index, child) -> awaitWorkerCount child messagesPerProducer 100 >> readProducerSentIds context index) (zip [1 ..] producers)
            drained <- awaitQueueDrain runtime queue 100
            marks <- concat <$> traverse (readWorkerLeaseMarks context) [1 .. processCount]
            let leases = concatMap (mapMaybe leaseFact) marks
                observedIds = [PgmqTypes.MessageId identifier | Leased _ identifier _ _ _ _ <- leases]
                findings = checkLeaseIntervals leases
            metrics <- effect runtime (Pgmq.queueMetrics queue)
            putSummary context Verdicts "process-lease-observations" (object ["readMarks" .= length marks, "leases" .= length leases, "producers" .= producerCount, "produced" .= fmap length produced, "findings" .= fmap show findings])
            verdict context "no-double-lease-processes" [("worker-processes", length children == processCount), ("producer-processes", length producers == producerCount && all ((== messagesPerProducer) . length) produced), ("all-sent-seen", Set.fromList observedIds == Set.fromList (sent <> concat produced)), ("lease-times-present", length leases == sum (fmap length marks)), ("no-overlapping-or-duplicate-leases", null findings), ("eventual-quiescence", drained && metrics.queueLength == 0)]

noDoubleLeaseProcessSabotage :: RunContext -> IO ScenarioReport
noDoubleLeaseProcessSabotage context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "lease_process_sabotage" \queue -> do
    let processCount = max 2 (min 8 (fromIntegral (knobInt context.knobs (knobName "pgmq.processes"))))
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "unlockedRead" .= True]
    target <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (body 0) Nothing))
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        specs <- traverse (\index -> roleProcess checkEnvironment "pgmq/pgmq-consumer" index arguments) [1 .. processCount]
        children <- traverse (spawn supervisor) specs
        mapM_ (`awaitReady` 10000) children
        mapM_ (`sendCommand` CtlStart) children
        mapM_ (\child -> awaitMark child "after-read" 10000) children
        mapM_ (\child -> awaitWorkerCount child 1 100) children
        marks <- concat <$> traverse (readWorkerLeaseMarks context) [1 .. processCount]
        let leases = concatMap (mapMaybe leaseFact) marks
            findings = checkLeaseIntervals leases
            allReadTarget = length leases == processCount && all (\case Leased _ identifier _ _ _ _ -> identifier == PgmqTypes.unMessageId target; _ -> False) leases
        putSummary context Verdicts "process-sabotage-observations" (object ["processes" .= processCount, "leases" .= length leases, "findings" .= fmap show findings])
        verdict context "no-double-lease-processes" [("all-probes-read-target", allReadTarget), ("unique-ownership", null findings)]

awaitWorkerCount :: Child -> Int -> Int -> IO ()
awaitWorkerCount child expected attempts = do
  snapshot <- atomically (progress child)
  if snapshot.count >= fromIntegral expected
    then pure ()
    else if attempts <= 1 then ioError (userError "producer did not report its committed batch") else threadDelay 100000 >> awaitWorkerCount child expected (attempts - 1)

readProducerSentIds :: RunContext -> Int -> IO [Pgmq.MessageId]
readProducerSentIds context index = do
  let path = context.outDir <> "/logs/pgmq-pgmq-producer-" <> show index <> ".0.control.jsonl"
  linesOfOutput <- readControlLines path 20
  messages <- maybe (ioError (userError ("invalid producer control log: " <> path))) pure (traverse decodeStrict' linesOfOutput)
  let sent = [identifiers | WrkFacts facts <- messages, fact <- facts, Just identifiers <- [parseMaybe (withObject "sent" (.: "ids")) fact]]
  case sent of
    [identifiers] -> pure identifiers
    _ -> ioError (userError ("producer omitted its committed batch: " <> path))

leaseFact :: (Pgmq.MessageId, Int64, UTCTime, Maybe UTCTime) -> Maybe PgmqFact
leaseFact (identifier, readCount, visibleAt, readAt) =
  Leased "" (PgmqTypes.unMessageId identifier) readCount <$> readAt <*> pure visibleAt <*> pure Nothing

readWorkerLeaseMarks :: RunContext -> Int -> IO [[(Pgmq.MessageId, Int64, UTCTime, Maybe UTCTime)]]
readWorkerLeaseMarks context index = do
  let path = context.outDir <> "/logs/pgmq-pgmq-consumer-" <> show index <> ".0.control.jsonl"
  linesOfOutput <- readControlLines path 20
  messages <- maybe (ioError (userError ("invalid worker control log: " <> path))) pure (traverse decodeStrict' linesOfOutput)
  filter (not . null)
    <$> traverse
      ( \case
          WrkCustom "after-read" payload -> maybe (ioError (userError ("invalid lease mark: " <> path))) pure (parseLeaseMark payload)
          _ -> pure []
      )
      messages

readControlLines :: FilePath -> Int -> IO [ByteString.ByteString]
readControlLines path attempts =
  try @IOException (ByteString.readFile path) >>= \case
    Right contents -> pure (ByteString.lines contents)
    Left exception
      | attempts <= 1 -> throwIO exception
      | otherwise -> threadDelay 100000 >> readControlLines path (attempts - 1)

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
randomSigkill context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "random_sigkill" \queue -> do
    let processCount = max 2 (min 8 (fromIntegral (knobInt context.knobs (knobName "pgmq.processes"))))
        duration = fromIntegral (knobInt context.knobs (knobName "pgmq.duration-seconds")) :: Int
        killInterval = fromIntegral (knobInt context.knobs (knobName "pgmq.kill-interval-seconds")) :: Int
        killRounds = max 1 (duration `div` killInterval)
        killSpacingMicros = min (killInterval * 1000000) (duration * 1000000 `div` (killRounds + 1))
        rate = max 1 (min 5000 (fromIntegral (knobInt context.knobs (knobName "pgmq.rate-per-second"))))
        batchCount = max 1 (min 500 (rate `div` 10))
        visibility = max 2 (fromIntegral runtime.knobs.visibilityTimeoutSeconds)
        handlerMs = max 50 (min 100 (fromIntegral (knobInt context.knobs (knobName "pgmq.handler-ms")))) :: Int
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "batchSize" .= (10 :: Int), "visibilityTimeout" .= visibility, "handlerMs" .= handlerMs, "acknowledge" .= True]
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        specs <- traverse (\index -> roleProcess checkEnvironment "pgmq/pgmq-consumer" index arguments) [1 .. processCount]
        initial <- traverse (spawn supervisor) specs
        mapM_ (`awaitReady` 10000) initial
        mapM_ (`sendCommand` CtlStart) initial
        active <- newMVar initial
        producer <- async (produceFor runtime queue duration batchCount)
        killed <- forM [1 .. killRounds] \roundIndex -> do
          let jitter = fromIntegral ((unSeed context.seed + fromIntegral roundIndex * 2654435761) `mod` 100000)
          threadDelay (killSpacingMicros - jitter)
          modifyMVar active \children -> do
            let slot = fromIntegral ((unSeed context.seed + fromIntegral roundIndex * 17) `mod` fromIntegral processCount)
                victim = children !! slot
            killChild supervisor victim
            replacement <- restartChild supervisor victim
            sendCommand replacement CtlStart
            let updated = take slot children <> [replacement] <> drop (slot + 1) children
            pure (updated, ((childProc victim).index, (childProc victim).incarnation))
        sent <- wait producer
        drained <- awaitQueueDrain runtime queue ((visibility * 2 + 10) * 10)
        threadDelay 100000
        finalChildren <- readMVar active
        evidence <- concat <$> traverse (\child -> traverse (readConsumerEvidence context (childProc child).index) [0 .. (childProc child).incarnation]) finalChildren
        let leases = concatMap (\(_, _, readMarks, _, _) -> concatMap (mapMaybe leaseFact) readMarks) evidence
            handled = concatMap (\(_, _, _, ids, _) -> ids) evidence
            acked = concatMap (\(_, _, _, _, ids) -> ids) evidence
            sentSet = Set.fromList sent
            handledCounts = Map.fromListWith (+) [(identifier, 1 :: Int) | identifier <- handled]
            killedLeases = Map.fromListWith (+) [(identifier, 1 :: Int) | (workerIndex, incarnation) <- killed, (index, generation, readMarks, _, acknowledged) <- evidence, workerIndex == index && incarnation == generation, let acknowledgedSet = Set.fromList acknowledged, mark <- readMarks, (identifier, _, _, _) <- mark, identifier `Set.notMember` acknowledgedSet]
            boundedDuplicates = all (\(identifier, count) -> count <= 1 + Map.findWithDefault 0 identifier killedLeases) (Map.toList handledCounts)
            leaseFindings = checkLeaseIntervals leases
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        putSummary context Verdicts "random-sigkill-observations" (object ["sent" .= length sent, "handled" .= length handled, "acked" .= length acked, "kills" .= [object ["worker" .= index, "incarnation" .= incarnation] | (index, incarnation) <- killed], "unacknowledgedKilledLeases" .= sum (Map.elems killedLeases), "leaseFindings" .= fmap show leaseFindings, "queueLength" .= metrics.queueLength])
        verdict context "random-sigkill" [("produced-under-load", length sent >= batchCount && length killed == killRounds), ("kill-interrupted-a-lease", not (Map.null killedLeases)), ("no-sent-message-lost", Set.fromList handled == sentSet && Set.fromList acked `Set.isSubsetOf` sentSet), ("duplicates-bounded-by-killed-leases", boundedDuplicates), ("lease-intervals", null leaseFindings), ("drained-after-load", drained && metrics.queueLength == 0)]
  where
    produceFor runtime queue duration batchCount = do
      started <- getMonotonicTimeNSec
      let end = started + fromIntegral duration * 1000000000
          loop next index batches = do
            now <- getMonotonicTimeNSec
            if now >= end && not (null batches)
              then pure (concat (reverse batches))
              else do
                let values = fmap body [index .. index + batchCount - 1]
                ids <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue values Nothing))
                after <- getMonotonicTimeNSec
                let due = next + 100000000
                if after < due then threadDelay (fromIntegral ((due - after) `div` 1000)) else pure ()
                loop due (index + batchCount) (ids : batches)
      loop started 1 []

    readConsumerEvidence runContext index incarnation = do
      let path = runContext.outDir <> "/logs/pgmq-pgmq-consumer-" <> show index <> "." <> show incarnation <> ".control.jsonl"
      linesOfOutput <- readControlLines path 20
      messages <- maybe (ioError (userError ("invalid consumer control log: " <> path))) pure (traverse decodeStrict' linesOfOutput)
      marks <- traverse (\case WrkCustom "after-read" payload -> maybe (ioError (userError ("invalid lease mark: " <> path))) pure (parseLeaseMark payload); _ -> pure []) messages
      let facts kind = [ids | WrkFacts entries <- messages, entry <- entries, Just (factKind, ids) <- [parseMaybe (withObject "fact" \value -> (,) <$> value .: "kind" <*> value .: "ids") entry], factKind == kind]
      pure (index, incarnation, filter (not . null) marks, concat (facts ("handled" :: Text)), concat (facts ("acked" :: Text)))

producerBatchAtomicity :: RunContext -> IO ScenarioReport
producerBatchAtomicity context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "producer_kill" \queue -> do
    let batchSize = fromIntegral runtime.knobs.batchSize :: Int
        rounds = max 3 (min 20 (fromIntegral (knobInt context.knobs (knobName "pgmq.kills"))))
        arguments = object ["queue" .= Pgmq.queueNameToText queue, "count" .= batchSize, "batchSize" .= batchSize]
    withCheck context \checkEnvironment ->
      withSupervisor checkEnvironment \supervisor -> do
        observations <- traverse (runRound checkEnvironment supervisor arguments batchSize) [1 .. rounds]
        durable <- queueKeys runtime.pool queue
        let perBatch =
              [ let actual = Set.size (Set.intersection durable (Set.fromList intended))
                 in object ["round" .= index, "intentKeys" .= length intended, "durableKeys" .= actual, "sentIds" .= length sent, "killDelayMicros" .= delay, "killed" .= killed]
              | (index, intended, sent, delay, killed) <- observations
              ]
            fullOrEmpty = all (\(_, intended, _, _, _) -> let actual = Set.size (Set.intersection durable (Set.fromList intended)) in actual == 0 || actual == batchSize) observations
            sentComplete = all (\(_, intended, sent, _, _) -> null sent || length sent == batchSize && Set.fromList intended `Set.isSubsetOf` durable) observations
            noUnknownKeys = durable `Set.isSubsetOf` Set.fromList (concatMap (\(_, intended, _, _, _) -> intended) observations)
        putSummary context Verdicts "producer-batch-observations" (object ["batches" .= perBatch, "durableKeys" .= Set.size durable])
        verdict context "producer-batch-atomicity" [("all-rounds-have-intent", all (\(_, intended, _, _, _) -> length intended == batchSize) observations), ("at-least-one-sigkill", any (\(_, _, _, _, killed) -> killed) observations), ("all-or-nothing-per-batch", fullOrEmpty), ("every-reported-send-complete", sentComplete), ("no-unexpected-keys", noUnknownKeys), ("non-vacuous-committed-control", not (Set.null durable))]
  where
    runRound checkEnvironment supervisor arguments batchSize index = do
      spec <- roleProcess checkEnvironment "pgmq/pgmq-producer" index arguments
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "before-send" 10000
      let delay = if index == 1 then 50000 else fromIntegral ((unSeed context.seed + fromIntegral index * 7919) `mod` 3000)
      if index == 1 then awaitWorkerCount child batchSize 100 else threadDelay delay
      killed <- if index == 1 then pure False else either (const False) (const True) <$> try @SomeException (killChild supervisor child)
      (intended, sent) <- readBatchFacts context index
      pure (index, intended, sent, delay, killed)

readBatchFacts :: RunContext -> Int -> IO ([Text], [Pgmq.MessageId])
readBatchFacts context index = do
  let path = context.outDir <> "/logs/pgmq-pgmq-producer-" <> show index <> ".0.control.jsonl"
  linesOfOutput <- readControlLines path 20
  messages <- maybe (ioError (userError ("invalid producer control log: " <> path))) pure (traverse decodeStrict' linesOfOutput)
  let intents = [keys | WrkFacts facts <- messages, fact <- facts, Just keys <- [parseMaybe (withObject "intent" (.: "keys")) fact]]
      sends = [ids | WrkFacts facts <- messages, fact <- facts, Just ids <- [parseMaybe (withObject "sent" (.: "ids")) fact]]
  case (intents, sends) of
    ([keys], []) -> pure (keys, [])
    ([keys], [ids]) -> pure (keys, ids)
    _ -> ioError (userError ("producer omitted or duplicated batch evidence: " <> path))

staleAckAfterExpiry :: RunContext -> IO ScenarioReport
staleAckAfterExpiry context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "stale_ack" \queue -> do
    messageId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (body 1) Nothing))
    withPgmqPool (requirePostgres context) "stale-owner-a" runtime.knobs \ownerA ->
      withPgmqPool (requirePostgres context) "stale-owner-b" runtime.knobs \ownerB -> do
        first <- only =<< lease ownerA queue 1
        threadDelay 1050000
        second <- only =<< lease ownerB queue 30
        staleDeleted <- delete ownerA queue messageId
        currentDeleted <- delete ownerB queue messageId
        extension <- either (throwIO . userError . show) pure =<< runOps Nothing ownerB (Pgmq.changeVisibilityTimeout (Types.VisibilityTimeoutQuery queue messageId 30))
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        putSummary context Verdicts "stale-ack-observations" (object ["first" .= object ["id" .= first.messageId, "readCount" .= first.readCount, "readAt" .= first.lastReadAt, "visibleAt" .= first.visibilityTime], "second" .= object ["id" .= second.messageId, "readCount" .= second.readCount, "readAt" .= second.lastReadAt, "visibleAt" .= second.visibilityTime], "staleDeleted" .= staleDeleted, "currentDeleted" .= currentDeleted, "extensionSucceeded" .= isJust extension, "queueLength" .= metrics.queueLength])
        verdictClass Implementation context "stale-ack" [("same-message-redelivered-after-expiry", first.messageId == second.messageId && first.messageId == messageId && second.readCount == first.readCount + 1 && maybe False (>= first.visibilityTime) second.lastReadAt), ("stale-delete-wins", staleDeleted && not currentDeleted), ("no-fencing", maybe True (const False) extension), ("queue-empty", metrics.queueLength == 0)]
  where
    lease pool queue seconds = either (throwIO . userError . show) pure =<< runOps Nothing pool (Pgmq.readMessage (Types.ReadMessage queue seconds (Just 1) Nothing))
    delete pool queue identifier = either (throwIO . userError . show) pure =<< runOps Nothing pool (Pgmq.deleteMessage (Types.MessageQuery queue identifier))

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
    outage <- runOps runtime.tracer runtime.pool (Pgmq.sendMessage (Types.SendMessage queue (body 21) Nothing))
    recoveryStarted <- getMonotonicTimeNSec
    handle.heal
    messages <- retryValue 50 (runOps runtime.tracer runtime.pool (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 20) Nothing)))
    recoveredAt <- getMonotonicTimeNSec
    fsyncSetting <- session runtime.pool (Session.statement () showFsync)
    let observed = sort (fmap (.messageId) (Vector.toList messages))
        recoveryMillis = (recoveredAt - recoveryStarted) `div` 1000000
    putSummary context Verdicts "postgres-restart-observations" (object ["outageError" .= show outage, "recoveryMillis" .= recoveryMillis, "fsync" .= fsyncSetting, "sent" .= sent, "recovered" .= observed])
    verdict context "postgres-restart" [("outage-error-transient", either Pgmq.isTransient (const False) outage), ("committed-survives", observed == sort sent), ("same-pool-recovers-within-five-seconds", recoveryMillis <= 5000), ("durability-still-on", fsyncSetting == "on")]

showFsync :: Statement.Statement () Text
showFsync = Statement.preparable "show fsync" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

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
verdict = verdictClass Contract

verdictClass :: InvariantClass -> RunContext -> Text -> [(Text, Bool)] -> IO ScenarioReport
verdictClass cls context name checks = do
  putSummary context Verdicts name (object ["checks" .= [object ["name" .= label, "passed" .= ok] | (label, ok) <- checks]])
  let failures = [label | (label, False) <- checks]
  checkedAt <- getCurrentTime
  directory <- artifactPath context VerdictsDir ""
  _ <- writeVerdict directory (RunInfo context.runId context.scenario) (simpleVerdict cls name checks failures checkedAt)
  declareMediaType context ("verdicts/" <> sanitiseChecker name <> ".json") "application/json"
  pure $ if null failures then passed else failedWith failures (name <> " failed: " <> Text.intercalate ", " failures)

simpleVerdict :: InvariantClass -> Text -> [(Text, Bool)] -> [Text] -> UTCTime -> Verdict
simpleVerdict cls name checks failures checkedAt =
  Verdict
    { checker = name,
      invariant = name,
      cls,
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
