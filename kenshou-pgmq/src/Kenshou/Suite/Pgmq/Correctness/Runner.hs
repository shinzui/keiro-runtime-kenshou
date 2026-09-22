module Kenshou.Suite.Pgmq.Correctness.Runner (runCorrectness) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM, void)
import Data.Aeson (object, (.=))
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List (find, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful qualified
import Effectful.Error.Static qualified
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Check.Verdict (InvariantClass (Contract), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (ArtifactDir (VerdictsDir), RunContext (..), SummarySection (Verdicts), artifactPath, declareMediaType, putSummary, requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Knob (knobBool)
import Kenshou.Core.Scenario (ScenarioReport, failedWith, passed)
import Kenshou.Suite.Pgmq.Facts (PgmqFact (..))
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (AckMode (..), PgmqKnobs (..), QueueKind (..), knobName)
import Kenshou.Suite.Pgmq.Listener (Notification (..), awaitNotifications, withListener)
import Kenshou.Suite.Pgmq.Oracle (ConservationFinding (..), conservation)
import Kenshou.Suite.Pgmq.TopicModel qualified as TopicModel
import Kenshou.Telemetry (TelemetryHandles (..))
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (lookupAttribute)
import OpenTelemetry.Context.ThreadLocal (attachContext, detachContext)
import OpenTelemetry.Trace.Core (SpanStatus (..), defaultSpanArguments, inSpan)
import Pgmq.Config qualified as Config
import Pgmq.Config.Effectful qualified as ConfigEff
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Effectful.Effect qualified as PgmqEff
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Types
import Pgmq.Types qualified as PgmqTypes

runCorrectness :: Text -> RunContext -> Maybe (IO ScenarioReport)
runCorrectness identifier context = fmap guarded (lookup identifier runners)
  where
    guarded scenario = do
      result <- try @SomeException (scenario context)
      pure $ either (failedWith ["scenario-exception"] . Text.pack . show) id result

runners :: [(Text, RunContext -> IO ScenarioReport)]
runners =
  [ ("pgmq/queue/correctness/lifecycle-by-kind", lifecycleByKind),
    ("pgmq/send/correctness/send-variants-round-trip", sendVariantsRoundTrip),
    ("pgmq/send/correctness/delayed-and-scheduled-visibility", delayedVisibility),
    ("pgmq/send/correctness/large-payload-round-trip", largePayloadRoundTrip),
    ("pgmq/send/correctness/transactional-send-rollback", transactionalSendRollback),
    ("pgmq/read/correctness/read-semantics", readSemantics),
    ("pgmq/read/correctness/plain-read-return-order", plainReadReturnOrder),
    ("pgmq/ack/correctness/delete-archive-semantics", deleteArchiveSemantics),
    ("pgmq/vt/correctness/wall-clock-expiry", wallClockExpiry),
    ("pgmq/vt/correctness/set-vt-semantics", setVtSemantics),
    ("pgmq/fifo/correctness/grouped-read-semantics", groupedReadSemantics),
    ("pgmq/fifo/correctness/grouped-result-order", groupedResultOrder),
    ("pgmq/topics/correctness/routing-model", routingModel),
    ("pgmq/notify/correctness/channel-and-throttle", channelAndThrottle),
    ("pgmq/config/correctness/reconcile-convergence", reconcileConvergence),
    ("pgmq/config/correctness/mixed-case-alias-collision", mixedCaseAliasCollision),
    ("pgmq/effectful/correctness/interpreter-parity-and-errors", interpreterParity),
    ("pgmq/effectful/correctness/traced-span-contract", tracedSpanContract)
  ]

lifecycleByKind :: RunContext -> IO ScenarioReport
lifecycleByKind context = withPgmqRun context \runtime -> do
  let queue = scenarioQueueName context "lifecycle"
  whenPartitioned runtime.knobs (requirePartman runtime.pool >>= either (ioError . userError . Text.unpack) pure)
  create runtime queue
  result <- (`finally` cleanup runtime queue) do
    create runtime queue
    (queues, sent, removed, dropped, after) <- effect runtime do
      queues <- PgmqEff.listQueues
      sent <- PgmqEff.batchSendMessage (Types.BatchSendMessage queue [bodyKey "one", bodyKey "two"] Nothing)
      removed <- PgmqEff.deleteAllMessagesFromQueue queue
      dropped <- PgmqEff.dropQueue queue
      after <- PgmqEff.listQueues
      pure (queues, sent, removed, dropped, after)
    let observed = find ((== queue) . (.name)) queues
        expectedFlags = case runtime.knobs.queueKind of
          Standard -> maybe False (\item -> not item.isPartitioned && not item.isUnlogged) observed
          Unlogged -> maybe False (\item -> not item.isPartitioned && item.isUnlogged) observed
          Partitioned -> maybe False (\item -> item.isPartitioned && not item.isUnlogged) observed
        absent = all ((/= queue) . (.name)) after
        parseBoundary = isRight (Pgmq.parseQueueName (Text.replicate 47 "a")) && isLeft (Pgmq.parseQueueName (Text.replicate 48 "a")) && isLeft (Pgmq.parseQueueName "Upper")
    verdict context "lifecycle" [("queue-flags", expectedFlags), ("batch-send", length sent == 2), ("delete-all", removed == 2), ("drop", dropped), ("catalog-clean", absent), ("name-validation", parseBoundary)]
  pure result

sendVariantsRoundTrip :: RunContext -> IO ScenarioReport
sendVariantsRoundTrip context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "send_variants" \queue -> do
    now <- getCurrentTime
    let bodies = fmap bodyKey ["single", "later", "batch-1", "batch-2", "batch-later-1", "batch-later-2", "header", "header-later", "batch-header-1", "batch-header-2", "batch-header-later-1", "batch-header-later-2", "null-body"]
    ids <- effect runtime do
      a <- Pgmq.sendMessage (Types.SendMessage queue (bodies !! 0) Nothing)
      b <- Pgmq.sendMessageForLater (Types.SendMessageForLater queue (bodies !! 1) now)
      c <- Pgmq.batchSendMessage (Types.BatchSendMessage queue (take 2 (drop 2 bodies)) Nothing)
      d <- Pgmq.batchSendMessageForLater (Types.BatchSendMessageForLater queue (take 2 (drop 4 bodies)) now)
      e <- Pgmq.sendMessageWithHeaders (Types.SendMessageWithHeaders queue (bodies !! 6) (numberedHeader 1) Nothing)
      f <- Pgmq.sendMessageWithHeadersForLater (Types.SendMessageWithHeadersForLater queue (bodies !! 7) (numberedHeader 2) now)
      g <- Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (take 2 (drop 8 bodies)) [numberedHeader 3, numberedHeader 4] Nothing)
      h <- Pgmq.batchSendMessageWithHeadersForLater (Types.BatchSendMessageWithHeadersForLater queue (take 2 (drop 10 bodies)) [numberedHeader 5, numberedHeader 6] now)
      i <- Pgmq.sendMessage (Types.SendMessage queue (bodies !! 12) Nothing)
      pure ([a, b] <> c <> d <> [e, f] <> g <> h <> [i])
    messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 100) Nothing))
    let ordered = sortOn (.messageId) (Vector.toList messages)
        actualBodies = fmap (.body) ordered
        headerValues = fmap (.headers) (take 6 (drop 6 ordered))
        increasing = ids == sort ids && length (Set.fromList ids) == length ids
    verdict context "send-variants" [("identifier-order", increasing), ("body-round-trip", actualBodies == bodies), ("headers-round-trip", all (not . isNothing) headerValues)]

delayedVisibility :: RunContext -> IO ScenarioReport
delayedVisibility context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "delayed" \queue -> do
    now <- getCurrentTime
    _ <- effect runtime do
      _ <- Pgmq.sendMessage (Types.SendMessage queue (bodyKey "delay") (Just 1))
      Pgmq.sendMessageForLater (Types.SendMessageForLater queue (bodyKey "scheduled") (addUTCTime 1 now))
    early <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 0 (Just 10) Nothing))
    threadDelay 1100000
    delivered <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 10) Nothing))
    let messages = Vector.toList delivered
        notBeforeDue message = maybe False (>= addUTCTime 1 message.enqueuedAt) message.lastReadAt
    verdict context "delayed-visibility" [("hidden-before-due", Vector.null early), ("delivered", length messages == 2), ("not-before-due", all notBeforeDue messages)]

largePayloadRoundTrip :: RunContext -> IO ScenarioReport
largePayloadRoundTrip context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "large_payload" \queue -> do
    checks <- forM [1024, 65536, 1048576, 16777216] \size -> do
      let payload = Pgmq.MessageBody (object ["k" .= ("payload-" <> Text.pack (show size) :: Text), "pad" .= Text.replicate size "x"])
      (messageId, readBack, archived) <- effect runtime do
        messageId <- Pgmq.sendMessage (Types.SendMessage queue payload Nothing)
        messages <- Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing)
        archived <- Pgmq.archiveMessage (Types.MessageQuery queue messageId)
        pure (messageId, Vector.toList messages, archived)
      archivedBody <- readArchiveBody runtime.pool queue messageId
      pure (fmap (.body) readBack == [payload] && archived && archivedBody == Just payload)
    verdict context "large-payload" [("queue-and-archive-round-trip", and checks)]

transactionalSendRollback :: RunContext -> IO ScenarioReport
transactionalSendRollback context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "transaction" \queue -> do
    rolledBack <- session runtime.pool do
      Session.statement () beginTransaction
      messageId <- Sessions.sendMessage (Types.SendMessage queue (bodyKey "rolled-back") Nothing)
      Session.statement () rollbackTransaction
      pure messageId
    afterRollback <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 0 (Just 10) Nothing))
    committed <- session runtime.pool do
      Session.statement () beginTransaction
      messageId <- Sessions.sendMessage (Types.SendMessage queue (bodyKey "committed") Nothing)
      Session.statement () commitTransaction
      pure messageId
    afterCommit <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 10) Nothing))
    verdict context "transactional-send" [("rollback-absent", Vector.null afterRollback), ("commit-visible", fmap (.messageId) (Vector.toList afterCommit) == [committed]), ("distinct-id", rolledBack /= committed)]

readSemantics :: RunContext -> IO ScenarioReport
readSemantics context = withPgmqRun context \runtime -> do
  nullAndBatch <- withScenarioQueue runtime.pool context runtime.knobs "read_batch" \queue -> do
    ids <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap (bodyKey . Text.pack . show) [1 :: Int .. 5]) Nothing))
    one <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 Nothing Nothing))
    two <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 2) Nothing))
    pure (Vector.length one == 1 && Vector.length two == 2 && fmap (.messageId) (Vector.toList one <> Vector.toList two) == take 3 ids)
  conditional <- withScenarioQueue runtime.pool context runtime.knobs "read_conditional" \queue -> do
    _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue [Pgmq.MessageBody (object ["kind" .= ("a" :: Text)]), Pgmq.MessageBody (object ["kind" .= ("b" :: Text)])] Nothing))
    values <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 10) (Just (object ["kind" .= ("a" :: Text)]))))
    pure (fmap (.body) (Vector.toList values) == [Pgmq.MessageBody (object ["kind" .= ("a" :: Text)])])
  popCheck <- withScenarioQueue runtime.pool context runtime.knobs "read_pop" \queue -> do
    _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap (bodyKey . Text.pack . show) [1 :: Int .. 5]) Nothing))
    popped <- effect runtime (Pgmq.pop (Types.PopMessage queue Nothing))
    metrics <- effect runtime (Pgmq.queueMetrics queue)
    pure (Vector.length popped == 1 && metrics.queueLength == 4)
  polling <- withScenarioQueue runtime.pool context runtime.knobs "read_poll" \queue -> do
    started <- getMonotonicTimeNSec
    empty <- effect runtime (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 Nothing 1 50 Nothing))
    ended <- getMonotonicTimeNSec
    waiter <- async (effect runtime (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 Nothing 2 50 Nothing)))
    threadDelay 250000
    sent <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "arrival") Nothing))
    arrival <- wait waiter
    let elapsed = fromIntegral (ended - started) / 1000000000 :: Double
    pure (Vector.null empty && elapsed >= 0.5 && elapsed <= 1.5 && fmap (.messageId) (Vector.toList arrival) == [sent])
  verdict context "read-semantics" [("null-and-batch", nullAndBatch), ("conditional", conditional), ("pop", popCheck), ("poll", polling)]

plainReadReturnOrder :: RunContext -> IO ScenarioReport
plainReadReturnOrder context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "plain_order" \queue -> do
    _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap (bodyKey . Text.pack . show) [1 :: Int .. 2000]) Nothing))
    batches <- forM [1 :: Int .. 4] \_ -> effect runtime (Pgmq.readMessage (Types.ReadMessage queue 0 (Just 500) Nothing))
    let ordered batch = let ids = fmap (.messageId) (Vector.toList batch) in ids == sort ids
        unsorted = length (filter (not . ordered) batches)
    putSummary context Verdicts "plain-read-order" (object ["batches" .= length batches, "unsorted" .= unsorted])
    verdict context "plain-read-order" [("ascending-message-id", unsorted == 0)]

deleteArchiveSemantics :: RunContext -> IO ScenarioReport
deleteArchiveSemantics context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "ack" \queue -> do
    ids <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap bodyKey ["delete", "archive", "batch-delete", "batch-archive"]) Nothing))
    (deleteId, archiveId, batchDeleteId, batchArchiveId) <- case ids of
      [a, b, c, d] -> pure (a, b, c, d)
      _ -> ioError (userError "batch send did not return four identifiers")
    let unknown = Pgmq.MessageId (maximum (fmap Pgmq.unMessageId ids) + 1000)
    (deleted, deletedAgain, archived, archivedAgain, batchDeleted, batchArchived) <- effect runtime do
      deleted <- Pgmq.deleteMessage (Types.MessageQuery queue deleteId)
      deletedAgain <- Pgmq.deleteMessage (Types.MessageQuery queue deleteId)
      archived <- Pgmq.archiveMessage (Types.MessageQuery queue archiveId)
      archivedAgain <- Pgmq.archiveMessage (Types.MessageQuery queue archiveId)
      batchDeleted <- Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue [unknown, batchDeleteId])
      batchArchived <- Pgmq.batchArchiveMessages (Types.BatchMessageQuery queue [batchArchiveId, unknown])
      pure (deleted, deletedAgain, archived, archivedAgain, batchDeleted, batchArchived)
    let facts =
          [ Sent key (Pgmq.unMessageId messageId) Nothing Nothing Nothing | (key, messageId) <- zip ["delete", "archive", "batch-delete", "batch-archive"] ids
          ]
            <> [ Acked (Pgmq.unMessageId deleteId) AckDelete deleted,
                 Acked (Pgmq.unMessageId archiveId) AckArchive archived,
                 Acked (Pgmq.unMessageId batchDeleteId) AckBatchDelete (batchDeleted == [batchDeleteId]),
                 Acked (Pgmq.unMessageId batchArchiveId) AckBatchArchive (batchArchived == [batchArchiveId])
               ]
    conserved <- conservation runtime.pool queue facts
    verdict context "ack-semantics" [("single-idempotence", deleted && not deletedAgain && archived && not archivedAgain), ("batch-affected-only", batchDeleted == [batchDeleteId] && batchArchived == [batchArchiveId]), ("conservation", Set.null conserved.missingKeys && Set.null conserved.unexpectedKeys)]

wallClockExpiry :: RunContext -> IO ScenarioReport
wallClockExpiry context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "vt_expiry" \queue -> do
    messageId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "lease") Nothing))
    first <- onlyMessage =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just 1) Nothing))
    hidden <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just 1) Nothing))
    metrics <- effect runtime (Pgmq.queueMetrics queue)
    threadDelay 1050000
    second <- onlyMessage =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just 1) Nothing))
    let timely = case (first.lastReadAt, second.lastReadAt) of
          (Just _, Just secondAt) -> secondAt >= first.visibilityTime && diffUTCTime secondAt first.visibilityTime <= 0.5
          _ -> False
    verdict context "wall-clock-expiry" [("same-message", first.messageId == messageId && second.messageId == messageId), ("hidden", Vector.null hidden && metrics.queueVisibleLength == 0), ("read-count", first.readCount == 1 && second.readCount == 2), ("database-clock", timely)]

setVtSemantics :: RunContext -> IO ScenarioReport
setVtSemantics context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "set_vt" \queue -> do
    firstId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "relative") Nothing))
    leased <- onlyMessage =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
    relative <- effect runtime (Pgmq.changeVisibilityTimeout (Types.VisibilityTimeoutQuery queue firstId 0))
    redelivered <- onlyMessage =<< effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
    secondId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "absolute") Nothing))
    absoluteAt <- addUTCTime 1 <$> getCurrentTime
    absolute <- effect runtime (PgmqEff.setVisibilityTimeoutAt (Types.VisibilityTimeoutAtQuery queue secondId absoluteAt))
    _ <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue secondId))
    missingRelative <- effect runtime (Pgmq.changeVisibilityTimeout (Types.VisibilityTimeoutQuery queue secondId 0))
    missingAbsolute <- effect runtime (PgmqEff.setVisibilityTimeoutAt (Types.VisibilityTimeoutAtQuery queue secondId absoluteAt))
    let unchanged = maybe False ((== leased.readCount) . (.readCount)) relative
        absoluteExact = maybe False ((== absoluteAt) . (.visibilityTime)) absolute
    verdict context "set-vt" [("relative-visible", unchanged && redelivered.messageId == firstId && redelivered.readCount == leased.readCount + 1), ("absolute", absoluteExact), ("missing-is-nothing", isNothing missingRelative && isNothing missingAbsolute)]

groupedReadSemantics :: RunContext -> IO ScenarioReport
groupedReadSemantics context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "fifo" \queue -> do
    _ <- effect runtime do
      PgmqEff.createFifoIndex queue
      PgmqEff.createFifoIndex queue
      Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (fmap bodyKey ["g1-1", "g1-2", "g2-1", "g2-2"]) (fmap groupHeader ["g1", "g1", "g2", "g2"]) Nothing)
    indexes <- effect runtime PgmqEff.listFifoIndexQueueNames
    headBatch <- effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 1 10))
    let heads = Vector.toList headBatch
    hidden <- effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 1 10))
    threadDelay 1050000
    redelivered <- effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 1 10))
    _ <- effect runtime (Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue (fmap (.messageId) (Vector.toList redelivered))))
    successors <- effect runtime (Pgmq.readGroupedRoundRobin (Types.ReadGrouped queue 30 10))
    let sameHeads = sort (fmap (.messageId) heads) == sort (fmap (.messageId) (Vector.toList redelivered))
    verdict context "grouped-read" [("fifo-index", Pgmq.queueNameToText queue `elem` indexes), ("one-head-per-group", length heads == 2), ("invisible-head-blocks", Vector.null hidden), ("head-redelivery", sameHeads && all ((== 2) . (.readCount)) (Vector.toList redelivered)), ("successors", Vector.length successors == 2)]

groupedResultOrder :: RunContext -> IO ScenarioReport
groupedResultOrder context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "grouped_order" \queue -> do
    let count = 1000
    _ <- effect runtime (Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (fmap (bodyKey . Text.pack . show) [1 .. count]) (fmap (groupHeader . ("g" <>) . Text.pack . show . (`mod` (200 :: Int))) [1 .. count]) Nothing))
    grouped <- effect runtime (Pgmq.readGrouped (Types.ReadGrouped queue 0 (fromIntegral count)))
    heads <- effect runtime (Pgmq.readGroupedHead (Types.ReadGrouped queue 0 (fromIntegral count)))
    let ascending messages = let ids = fmap (.messageId) (Vector.toList messages) in ids == sort ids
        reproduced = not (ascending grouped && ascending heads)
    putSummary context Verdicts "grouped-result-order" (object ["groupedAscending" .= ascending grouped, "headAscending" .= ascending heads, "knownDefectReproduced" .= reproduced])
    if reproduced then pure (failedWith ["known-defect"] "grouped reads returned a non-deterministically ordered vector") else pure passed

routingModel :: RunContext -> IO ScenarioReport
routingModel context = withPgmqRun context \runtime -> do
  let queueA = scenarioQueueName context "topic_a"
      queueB = scenarioQueueName context "topic_b"
      patternA = parsed Pgmq.parseTopicPattern "orders.*.created"
      patternB = parsed Pgmq.parseTopicPattern "orders.#"
      key = parsed Pgmq.parseRoutingKey "orders.us.created"
  withScenarioQueue runtime.pool context runtime.knobs "topic_a" \_ ->
    withScenarioQueue runtime.pool context runtime.knobs "topic_b" \_ -> do
      (matches, sent, batch, unbound, unboundAgain, valid) <- effect runtime do
        Pgmq.bindTopic (Types.BindTopic patternA queueA)
        Pgmq.bindTopic (Types.BindTopic patternA queueA)
        Pgmq.bindTopic (Types.BindTopic patternB queueB)
        matches <- Pgmq.testRouting key
        sent <- Pgmq.sendTopic (Types.SendTopic key (bodyKey "topic-single") Nothing)
        batch <- Pgmq.batchSendTopic (Types.BatchSendTopic key [bodyKey "topic-batch-1", bodyKey "topic-batch-2"] Nothing)
        unbound <- Pgmq.unbindTopic (Types.UnbindTopic patternA queueA)
        unboundAgain <- Pgmq.unbindTopic (Types.UnbindTopic patternA queueA)
        valid <- Pgmq.validateRoutingKey key
        pure (matches, sent, batch, unbound, unboundAgain, valid)
      a <- effect runtime (Pgmq.readMessage (Types.ReadMessage queueA 30 (Just 10) Nothing))
      b <- effect runtime (Pgmq.readMessage (Types.ReadMessage queueB 30 (Just 10) Nothing))
      let modelMatches = TopicModel.matches patternA key && TopicModel.matches patternB key
      verdict context "routing-model" [("model", modelMatches && length matches == 2), ("single-fanout", sent == 2), ("batch-cardinality", length batch == 4), ("queue-copies", Vector.length a == 3 && Vector.length b == 3), ("unbind-idempotence", unbound && not unboundAgain), ("validation", valid)]

channelAndThrottle :: RunContext -> IO ScenarioReport
channelAndThrottle context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "notify" \queue -> do
    _ <- effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just 0)))
    notifications <- withListener (requirePostgres context).connectionString (PgmqTypes.notifyChannelName queue) \connection -> do
      _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap (bodyKey . Text.pack . show) [1 :: Int .. 3]) Nothing))
      awaitNotifications connection 2000
    _ <- effect runtime (Pgmq.disableNotifyInsert queue)
    afterDisable <- withListener (requirePostgres context).connectionString (PgmqTypes.notifyChannelName queue) \connection -> do
      _ <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "disabled") Nothing))
      awaitNotifications connection 300
    let channels = fmap (.channel) notifications
    verdict context "notify-channel" [("notifications-arrive", not (null notifications)), ("exact-channel", all (== PgmqTypes.notifyChannelName queue) channels), ("disabled", null afterDisable)]

reconcileConvergence :: RunContext -> IO ScenarioReport
reconcileConvergence context = withPgmqRun context \runtime -> do
  let queue = scenarioQueueName context "reconcile"
      pattern = parsed Pgmq.parseTopicPattern "jobs.#"
      declaration = Config.withTopicBinding pattern . Config.withFifoIndex . Config.withNotifyInsert (Just 250) $ Config.standardQueue queue
  first <- session runtime.pool (Config.ensureQueuesReport [declaration])
  second <- session runtime.pool (Config.ensureQueuesReport [declaration])
  effectReport <- effect runtime (ConfigEff.ensureQueuesReportEff [declaration])
  changed <- session runtime.pool (Config.ensureQueuesReport [Config.withNotifyInsert (Just 500) declaration])
  _ <- effect runtime (Pgmq.dropQueue queue)
  let created = any isCreated first
      skipped = all isSkipped second && all isSkipped effectReport
      updated = any isUpdated changed
  verdict context "reconcile" [("first-creates", created), ("converged", skipped), ("effectful-parity", fmap show second == fmap show effectReport), ("throttle-update", updated)]
  where
    isCreated = \case Config.CreatedQueue {} -> True; _ -> False
    isSkipped = \case Config.SkippedQueue {} -> True; Config.SkippedNotify {} -> True; Config.SkippedFifoIndex {} -> True; Config.SkippedTopicBinding {} -> True; _ -> False
    isUpdated = \case Config.UpdatedNotifyThrottle {} -> True; _ -> False

mixedCaseAliasCollision :: RunContext -> IO ScenarioReport
mixedCaseAliasCollision context = withPgmqRun context \runtime -> do
  let lowercase = scenarioQueueName context "alias"
      mixed = "Alias" <> Text.drop 5 (Pgmq.queueNameToText lowercase)
  _ <- session runtime.pool (Session.statement mixed createForeignQueue)
  report <- session runtime.pool (Config.ensureQueuesReport [Config.standardQueue lowercase])
  rows <- session runtime.pool (Session.statement (Pgmq.queueNameToText lowercase, mixed) metaAliasCount)
  _ <- session runtime.pool (Session.statement mixed dropForeignQueue)
  let created = any (\case Config.CreatedQueue {} -> True; _ -> False) report
  if created || rows /= 1
    then pure (failedWith ["known-defect"] "mixed-case metadata alias collision was reproduced")
    else pure passed

interpreterParity :: RunContext -> IO ScenarioReport
interpreterParity context = withPgmqRun context \runtime -> do
  effectResult <- withScenarioQueue runtime.pool context runtime.knobs "effect_parity" \queue -> do
    messageId <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "parity") Nothing))
    messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
    deleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue messageId))
    pure (fmap (.body) (Vector.toList messages), deleted)
  sessionResult <- withScenarioQueue runtime.pool context runtime.knobs "session_parity" \queue -> do
    messageId <- session runtime.pool (Sessions.sendMessage (Types.SendMessage queue (bodyKey "parity") Nothing))
    messages <- session runtime.pool (Sessions.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
    deleted <- session runtime.pool (Sessions.deleteMessage (Types.MessageQuery queue messageId))
    pure (fmap (.body) (Vector.toList messages), deleted)
  missing <- runOps runtime.tracer runtime.pool (Pgmq.sendMessage (Types.SendMessage (parsed Pgmq.parseQueueName "missing_queue") (bodyKey "missing") Nothing))
  verdict context "interpreter-parity" [("observable-parity", effectResult == sessionResult), ("missing-queue-permanent", either (not . Pgmq.isTransient) (const False) missing)]

tracedSpanContract :: RunContext -> IO ScenarioReport
tracedSpanContract context = withPgmqRun context \runtime ->
  withScenarioQueue runtime.pool context runtime.knobs "traced_span" \queue -> do
    propagated <-
      if knobBool context.knobs (knobName "pgmq.trace.propagate")
        then propagateRoundTrip runtime queue
        else do
          _ <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (bodyKey "span") Nothing))
          _ <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
          pure Nothing
    _ <- runOps runtime.tracer runtime.pool (Pgmq.deleteMessage (Types.MessageQuery (parsed Pgmq.parseQueueName "missing_span_queue") (Pgmq.MessageId 1)))
    void runtime.telemetry.flushTelemetry
    spans <- maybe (pure []) readSpans runtime.telemetry.spans
    let publish = find ((== "publish " <> Pgmq.queueNameToText queue) . (.name)) spans
        receive = find ((== "receive " <> Pgmq.queueNameToText queue) . (.name)) spans
        failed = find isError spans
        hasCoreAttributes spanValue =
          all (not . isNothing . lookupAttribute spanValue.attributes) ["messaging.system", "messaging.destination.name"]
            && any (not . isNothing . lookupAttribute spanValue.attributes) ["db.operation", "db.operation.name"]
        spanCount = if propagated == Nothing then length spans == 3 else length spans == 5
        continuity = case propagated of
          Nothing -> True
          Just () -> case (find ((== "pgmq.producer") . (.name)) spans, find ((== "pgmq.consumer") . (.name)) spans) of
            (Just producer, Just consumer) -> consumer.traceId == producer.traceId && consumer.parentSpanId == Just producer.spanId
            _ -> False
    verdict context "traced-span" [("operation-span-count", spanCount), ("publish-shape", maybe False hasCoreAttributes publish), ("receive-shape", maybe False hasCoreAttributes receive), ("error-status", maybe False (const True) failed), ("propagated-context", continuity)]
  where
    isError spanValue = case spanValue.status of Error _ -> True; _ -> False

propagateRoundTrip :: PgmqRun -> Pgmq.QueueName -> IO (Maybe ())
propagateRoundTrip runtime queue = case (runtime.telemetry.tracer, runtime.telemetry.tracerProvider) of
  (Just tracer, Just provider) -> do
    _ <- inSpan tracer "pgmq.producer" defaultSpanArguments (effect runtime (Pgmq.sendMessageTraced provider queue (bodyKey "span") Nothing))
    values <- effect runtime (Pgmq.readMessageWithContext provider (Types.ReadMessage queue 30 (Just 1) Nothing))
    case Vector.toList values of
      [(_, parent)] -> bracket (attachContext parent) detachContext (const (inSpan tracer "pgmq.consumer" defaultSpanArguments (pure ()))) >> pure (Just ())
      _ -> pure Nothing
  _ -> pure Nothing

create :: PgmqRun -> Pgmq.QueueName -> IO ()
create runtime queue = case runtime.knobs.queueKind of
  Standard -> () <$ effect runtime (Pgmq.createQueue queue)
  Unlogged -> () <$ effect runtime (Pgmq.createUnloggedQueue queue)
  Partitioned -> () <$ effect runtime (Pgmq.createPartitionedQueue (Types.CreatePartitionedQueue queue "10000" "100000"))

cleanup :: PgmqRun -> Pgmq.QueueName -> IO ()
cleanup runtime queue = do
  _ <- runOps Nothing runtime.pool (Pgmq.dropQueue queue)
  pure ()

whenPartitioned :: PgmqKnobs -> IO () -> IO ()
whenPartitioned knobs action = if knobs.queueKind == Partitioned then action else pure ()

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

bodyKey :: Text -> Pgmq.MessageBody
bodyKey key = Pgmq.MessageBody (object ["k" .= key])

groupHeader :: Text -> Pgmq.MessageHeaders
groupHeader group = Pgmq.MessageHeaders (object ["x-pgmq-group" .= group])

numberedHeader :: Int -> Pgmq.MessageHeaders
numberedHeader number = Pgmq.MessageHeaders (object ["kind" .= ("header" :: Text), "n" .= number])

onlyMessage :: Vector.Vector Pgmq.Message -> IO Pgmq.Message
onlyMessage messages = case Vector.toList messages of
  [message] -> pure message
  other -> ioError (userError ("expected one message, got " <> show (length other)))

parsed :: (Text -> Either error value) -> Text -> value
parsed parser value = either (const (error "pgmq correctness fixture did not parse")) id (parser value)

isLeft, isRight :: Either left right -> Bool
isLeft = either (const True) (const False)
isRight = not . isLeft

readArchiveBody :: Pool.Pool -> Pgmq.QueueName -> Pgmq.MessageId -> IO (Maybe Pgmq.MessageBody)
readArchiveBody pool queue messageId = session pool (Session.statement (Pgmq.unMessageId messageId) statement)
  where
    statement =
      Statement.unpreparable
        ("select message from pgmq.\"a_" <> Pgmq.queueNameToText queue <> "\" where msg_id=$1")
        (Encoders.param (Encoders.nonNullable Encoders.int8))
        (fmap (fmap Pgmq.MessageBody) (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.jsonb))))

createForeignQueue :: Statement.Statement Text ()
createForeignQueue = Statement.unpreparable "select from pgmq.create($1)" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult

dropForeignQueue :: Statement.Statement Text ()
dropForeignQueue = Statement.unpreparable "select from pgmq.drop_queue($1)" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult

metaAliasCount :: Statement.Statement (Text, Text) Int64
metaAliasCount =
  Statement.unpreparable
    "select count(*) from pgmq.meta where lower(queue_name) = lower($1) and queue_name in ($1, $2)"
    ((fst >$< Encoders.param (Encoders.nonNullable Encoders.text)) <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text)))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

beginTransaction, rollbackTransaction, commitTransaction :: Statement.Statement () ()
beginTransaction = command "begin"
rollbackTransaction = command "rollback"
commitTransaction = command "commit"

command :: Text -> Statement.Statement () ()
command sql = Statement.unpreparable sql Encoders.noParams Decoders.noResult
