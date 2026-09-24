module Kenshou.Suite.Keiro.Outbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (bracket, finally)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int32)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Codec (Codec (..))
import Keiro.Command (defaultRunCommandOptions)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), IntegrationEventDraft (..), IntegrationProducer (..), OutboxMaintenanceOptions (..), OutboxMaintenanceSummary (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), ProducerEnqueueOutcome (..), ProducerIdentity (..), countOutboxBacklog, defaultPublishOptions, enqueueIntegrationEventTx, enqueueProducerEventTx, freshOutboxId, listOutbox, mkIntegrationProducer, outboxMaintenancePass, publishClaimedOutbox)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), LockTarget (..), holdLock, listBackends, terminateOneBackend)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, killChild, readChildMessages, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Process qualified as Process
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), inconclusiveBecause)
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountCodec, accountEventStream)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountEvent, AccountId (..), DepositData (..), OpenAccountData (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (CommandRunner (..), FixtureEnv (..), KeiroRunner (..), SubmitOutcome (..), submitAccountCommand, withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells, recordMessagingCellsClassified)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, inlineEvent, sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (SubscriptionName (..), SubscriptionResult (..), SubscriptionTarget (..), defaultSubscriptionConfig)
import Kiroku.Store.Types (CategoryName (..), EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import Streamly.Data.Stream qualified as Streamly
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [crashBetweenPublishAndMark, multiProcessPublishers, concurrentInlineEnqueueOrder, zombiePublisherFinalization]

zombiePublisherFinalization :: Scenario
zombiePublisherFinalization =
  crashBetweenPublishAndMark
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/zombie-publisher-finalization"),
      summary = "Checks that a publisher resumed after maintenance cannot finalize another publisher's claim.",
      knobs = [KnobSpec (knobName "outbox.zombie-outcome") "Outcome reported by the stale publisher" KnobText (VText "failed") (OneOf (VText "failed" :| [VText "succeeded", VText "dead"])) [VText "succeeded", VText "dead"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5" "Stale publishers can finalize a row after maintenance and another publisher re-claim it" ["stale-finalization-no-effect", "terminal-consistent-with-success"] AllCohorts),
      run = runZombiePublisherFinalization
    }

runZombiePublisherFinalization :: RunContext -> IO ScenarioReport
runZombiePublisherFinalization context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "zombie"
            outcome = knobText context.knobs (knobName "outbox.zombie-outcome")
            maxAttempts = if outcome == "dead" then 2 else 10 :: Int
            readSingle = do
              rows <- runFixture (listOutbox source) >>= either (fail . show) pure
              case rows of
                [row] -> pure row
                _ -> fail "zombie fixture did not contain exactly one outbox row"
            startPublisher index publisherOutcome = do
              spec <- roleProcess check "keiro/outbox-publisher" index (object ["parkAfterAppend" .= True, "outcome" .= publisherOutcome, "maxAttempts" .= maxAttempts])
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              awaitMark child "broker-appended" 30000
              pure child
            finishPublisher child = do
              sendCommand child (CtlCustom "continue" Null)
              awaitMark child "finished" 30000
        enqueueInline fixture source [("zombie", Just "one-key", 1)]
        first <- startPublisher 0 (if outcome == "succeeded" then "succeeded" else "failed")
        firstClaim <- readSingle
        Process.signalChild supervisor first Process.Stop
        threadDelay 1500000
        maintenanceSpec <- roleProcess check "keiro/outbox-maintenance" 0 (object ["maxAttempts" .= maxAttempts, "publishingTimeoutSeconds" .= (1 :: Double)])
        maintainer <- spawn supervisor maintenanceSpec
        awaitReady maintainer 10000
        sendCommand maintainer CtlStart
        awaitMark maintainer "finished" 30000
        maintenanceMessages <- readChildMessages maintainer
        let requeued = [count | WrkCustom "maintenance-pass" payload <- maintenanceMessages, Just count <- [parseMaybe (withObject "maintenance pass" (\value -> value .: "requeued")) payload]]
        reclaimed <- readSingle
        second <- startPublisher 1 ("succeeded" :: Text.Text)
        secondClaim <- readSingle
        Process.signalChild supervisor first Process.Cont
        finishPublisher first
        afterStale <- readSingle
        finishPublisher second
        finalRow <- readSingle
        records <- Broker.readBroker broker
        let schedule = firstClaim.status == OutboxPublishing && requeued == [1 :: Int] && reclaimed.status == OutboxFailed && secondClaim.status == OutboxPublishing && secondClaim.attemptCount == 2
            staleDidNothing = afterStale.status == OutboxPublishing && afterStale.attemptCount == 2
            terminalConsistent = finalRow.status == OutboxSent && length records == (if outcome == "succeeded" then 2 else 1)
        recordMessagingCellsClassified
          context
          (Map.fromList [("brokerRecords", fromIntegral (length records)), ("attempts", fromIntegral finalRow.attemptCount)])
          (object ["outcome" .= outcome, "firstClaim" .= show firstClaim.status, "reclaimed" .= show reclaimed.status, "secondClaim" .= show secondClaim.status, "afterStale" .= show afterStale.status, "final" .= show finalRow.status])
          [("schedule-realised", Contract, schedule), ("stale-finalization-no-effect", Implementation, staleDidNothing), ("terminal-consistent-with-success", Contract, terminalConsistent)]

concurrentInlineEnqueueOrder :: Scenario
concurrentInlineEnqueueOrder =
  crashBetweenPublishAndMark
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/concurrent-inline-enqueue-order"),
      summary = "Stages opposite transaction-start and commit order for inline events, with a serialized producer-path control.",
      tier = TierSmoke,
      knobs = [KnobSpec (knobName "outbox.enqueue-path") "Inline race or serialized producer control" KnobText (VText "inline") (OneOf (VText "inline" :| [VText "producer", VText "producer-direct"])) [VText "producer", VText "producer-direct"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16" "Concurrent inline enqueues can publish one key out of producer order" ["per-key-order"] AllCohorts),
      run = runConcurrentInlineEnqueueOrder
    }

runConcurrentInlineEnqueueOrder :: RunContext -> IO ScenarioReport
runConcurrentInlineEnqueueOrder context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      case knobText context.knobs (knobName "outbox.enqueue-path") of
        "producer" -> runProducerSubscriptionControl context fixture broker
        "producer-direct" -> runProducerPathControl context fixture broker
        _ -> runInlineOrderRace context fixture broker

runProducerSubscriptionControl :: RunContext -> FixtureEnv -> Broker.Broker -> IO ScenarioReport
runProducerSubscriptionControl context fixture broker = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "subscription-order"
      account = AccountId (sourceName context "account")
      producer :: IntegrationProducer AccountEvent
      producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "ordering-subscription" source "kenshou" mapEvent))
      mapEvent recorded _ =
        Just
          IntegrationEventDraft
            { destination = "kenshou.outbox.v1",
              key = Just source,
              eventType = "AccountOrdering",
              schemaVersion = 1,
              contentType = ApplicationJson,
              schemaReference = Nothing,
              sourceEventId = Nothing,
              sourceGlobalPosition = Nothing,
              payloadBytes = LazyByteString.toStrict (Aeson.encode recorded.payload),
              occurredAt = recorded.createdAt,
              causationId = Nothing,
              correlationId = Nothing,
              traceContext = Nothing,
              attributes = Nothing
            }
      callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) (Broker.PublishHook (const (pure ())) (const (pure ()))) "subscription-order-publisher"
      submit eventId command = submitAccountCommand fixture (accountEventStream SnapNever) RunnerPlain defaultRunCommandOptions 0 eventId command
      config = defaultSubscriptionConfig (SubscriptionName (sourceName context "ordering-producer")) (Category (CategoryName "account")) (\_ -> pure Continue)
      consume stream outcomes sourceVersions = do
        next <- timeout 10000000 (Streamly.uncons stream)
        case next of
          Nothing -> fail "producer subscription did not deliver two account events"
          Just Nothing -> fail "producer subscription stopped before two account events"
          Just (Just (item, rest)) -> do
            let recorded = item.ackEvent
            decoded <- either (fail . Text.unpack) pure (accountCodec.decode recorded.eventType recorded.payload)
            draft <- maybe (fail "producer mapper skipped account event") pure (producer.mapEvent recorded decoded)
            outcome <- runFixture (runTransaction (enqueueProducerEventTx producer recorded 0 draft)) >>= either (fail . show) pure
            let nextVersions = sourceVersions <> [recorded.streamVersion]
                nextOutcomes = outcomes <> [outcome]
            atomically (putTMVar item.ackReply (if length nextOutcomes == 2 then Stop else Continue))
            if length nextOutcomes == 2
              then do
                stopped <- timeout 10000000 (Streamly.uncons rest)
                case stopped of
                  Just Nothing -> pure (nextOutcomes, nextVersions)
                  _ -> fail "producer subscription did not stop after the second acknowledgement"
              else consume rest nextOutcomes nextVersions
  opened <- submit (EventId (UUID.fromWords 0 0 0 1)) (OpenAccount (OpenAccountData account 0))
  deposited <- submit (EventId (UUID.fromWords 0 0 0 2)) (Deposit (DepositData account 1 "ordering"))
  (stream, cancelStream) <- subscriptionAckStream fixture.store config 2
  (outcomes, sourceVersions) <- finally (consume stream [] []) cancelStream
  _ <- runFixture (publishClaimedOutbox callback defaultPublishOptions Nothing) >>= either (fail . show) pure
  rows <- runFixture (listOutbox source) >>= either (fail . show) pure
  records <- Broker.readBroker broker
  let brokerIds = [TextEncoding.decodeUtf8 value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
      expected = [identity.messageId | ProducerInserted identity <- outcomes]
      commandsAppended = [opened, deposited] == [SubmitAppended (StreamVersion 1), SubmitAppended (StreamVersion 2)]
      schedule = commandsAppended && sourceVersions == [StreamVersion 1, StreamVersion 2] && length expected == 2 && brokerIds == expected
      cells =
        [ ("schedule-realised", Contract, schedule),
          ("no-loss", Contract, length rows == 2 && all ((== OutboxSent) . (.status)) rows && sort brokerIds == sort expected),
          ("per-key-order", Implementation, brokerIds == expected)
        ]
  recordMessagingCellsClassified context (Map.fromList [("enqueued", 2), ("brokerRecords", fromIntegral (length records))]) (object ["sourceVersions" .= [version | StreamVersion version <- sourceVersions], "brokerMessageIds" .= brokerIds, "commandsAppended" .= commandsAppended]) cells

runInlineOrderRace :: RunContext -> FixtureEnv -> Broker.Broker -> IO ScenarioReport
runInlineOrderRace context fixture broker = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "inline-order"
      postgres = requirePostgres context
      model = Broker.BrokerModel 0 0 4
      hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
      callback = Broker.publishScripted broker model (const Broker.Succeed) hooks "inline-order-publisher"
      lockKey = 735715
  firstId <- runFixture freshOutboxId >>= either (fail . show) pure
  secondId <- runFixture freshOutboxId >>= either (fail . show) pure
  firstTime <- getCurrentTime
  bracket (holdLock postgres (AdvisoryLock lockKey)).inject (.heal) \handle ->
    withAsync
      ( runFixture
          ( runTransaction do
              enqueueIntegrationEventTx firstId (inlineEvent source "first" (Just "shared") 1 firstTime)
              Tx.statement () advisoryLockStatement
          )
      )
      \firstWriter -> do
        let waitBlocked = do
              backends <- listBackends postgres
              if any (\backend -> backend.waitEventType == Just "Lock" && "pg_advisory_xact_lock" `Text.isInfixOf` backend.query) backends
                then pure True
                else threadDelay 10000 >> waitBlocked
        blocked <- timeout 10000000 waitBlocked
        case blocked of
          Nothing -> fail "first inline enqueue never blocked on the advisory lock"
          Just True -> pure ()
          Just False -> fail "first inline enqueue did not reach the advisory lock"
        secondTime <- getCurrentTime
        runFixture (runTransaction (enqueueIntegrationEventTx secondId (inlineEvent source "second" (Just "shared") 2 secondTime))) >>= either (fail . show) pure
        _ <- runFixture (publishClaimedOutbox callback defaultPublishOptions Nothing) >>= either (fail . show) pure
        beforeRelease <- Broker.readBroker broker
        handle.heal
        _ <- wait firstWriter >>= either (fail . show) pure
        _ <- runFixture (publishClaimedOutbox callback defaultPublishOptions Nothing) >>= either (fail . show) pure
        rows <- runFixture (listOutbox source) >>= either (fail . show) pure
        records <- Broker.readBroker broker
        let ids = [TextEncoding.decodeUtf8 value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            beforeIds = [TextEncoding.decodeUtf8 value | record <- beforeRelease, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            firstCreated = [row.createdAt | row <- rows, row.event.messageId == "first"]
            secondCreated = [row.createdAt | row <- rows, row.event.messageId == "second"]
            schedule =
              beforeIds == ["second"] && ids == ["second", "first"] && case (firstCreated, secondCreated) of
                ([a], [b]) -> a < b
                _ -> False
            cells =
              [ ("schedule-realised", Contract, schedule),
                ("no-loss", Contract, length rows == 2 && all ((== OutboxSent) . (.status)) rows && sort ids == ["first", "second"]),
                ("per-key-order", Implementation, ids == ["first", "second"])
              ]
        report <- recordMessagingCellsClassified context (Map.fromList [("enqueued", 2), ("brokerRecords", fromIntegral (length records))]) (object ["brokerMessageIds" .= ids, "firstCreatedAt" .= firstCreated, "secondCreatedAt" .= secondCreated]) cells
        pure (if schedule then report else inconclusiveBecause "the inline enqueue inversion was not observed")

runProducerPathControl :: RunContext -> FixtureEnv -> Broker.Broker -> IO ScenarioReport
runProducerPathControl context fixture broker = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "producer-order"
      producer :: IntegrationProducer ()
      producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "ordering-control" source "kenshou" (\_ _ -> Nothing)))
      model = Broker.BrokerModel 0 0 4
      hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
      callback = Broker.publishScripted broker model (const Broker.Succeed) hooks "producer-order-publisher"
      recorded eventId version position now =
        RecordedEvent
          { eventId,
            eventType = EventType "OrderingControl",
            streamVersion = StreamVersion version,
            globalPosition = GlobalPosition position,
            originalStreamId = StreamId 1,
            originalVersion = StreamVersion version,
            payload = object [],
            metadata = Nothing,
            causationId = Nothing,
            correlationId = Nothing,
            createdAt = now
          }
      draft now sequenceNo =
        IntegrationEventDraft
          { destination = "kenshou.outbox.v1",
            key = Just "shared",
            eventType = "OrderingControl",
            schemaVersion = 1,
            contentType = ApplicationJson,
            schemaReference = Nothing,
            sourceEventId = Nothing,
            sourceGlobalPosition = Nothing,
            payloadBytes = TextEncoding.encodeUtf8 (Text.pack (show sequenceNo)),
            occurredAt = now,
            causationId = Nothing,
            correlationId = Nothing,
            traceContext = Nothing,
            attributes = Just (object ["sequence" .= sequenceNo])
          }
      enqueue event sequenceNo = runFixture (runTransaction (enqueueProducerEventTx producer event 0 (draft event.createdAt sequenceNo))) >>= either (fail . show) pure
      inserted = \case ProducerInserted identity -> Just identity.messageId; _ -> Nothing
  now <- getCurrentTime
  first <- enqueue (recorded (EventId UUID.nil) 1 1 now) (1 :: Int)
  second <- enqueue (recorded (EventId (read "00000000-0000-0000-0000-000000000001")) 2 2 (addUTCTime 0.001 now)) (2 :: Int)
  _ <- runFixture (publishClaimedOutbox callback defaultPublishOptions Nothing) >>= either (fail . show) pure
  rows <- runFixture (listOutbox source) >>= either (fail . show) pure
  records <- Broker.readBroker broker
  let ids = [TextEncoding.decodeUtf8 value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
      expected = [messageId | Just messageId <- [inserted first, inserted second]]
      created = [row.createdAt | row <- rows]
      schedule = length expected == 2 && ids == expected && case created of [a, b] -> a < b; _ -> False
      cells =
        [ ("schedule-realised", Contract, schedule),
          ("no-loss", Contract, length rows == 2 && all ((== OutboxSent) . (.status)) rows && sort ids == sort expected),
          ("per-key-order", Implementation, ids == expected)
        ]
  recordMessagingCellsClassified context (Map.fromList [("enqueued", 2), ("brokerRecords", fromIntegral (length records))]) (object ["brokerMessageIds" .= ids, "producerMessageIds" .= expected]) cells

advisoryLockStatement :: Statement.Statement () Int32
advisoryLockStatement =
  Statement.preparable
    "SELECT 1 FROM pg_advisory_xact_lock(735715)"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

multiProcessPublishers :: Scenario
multiProcessPublishers =
  crashBetweenPublishAndMark
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/multi-process-publishers"),
      summary = "Checks four live publisher processes claim disjoint rows and preserve key order.",
      knobs =
        [ KnobSpec (knobName "outbox.rows") "Number of integration events" KnobInt (VInt 20000) (IntRange 32 20000) [],
          KnobSpec (knobName "outbox.key-cardinality") "Number of partition keys" KnobInt (VInt 200) (IntRange 1 200) []
        ],
      run = runMultiProcessPublishers
    }

runMultiProcessPublishers :: RunContext -> IO ScenarioReport
runMultiProcessPublishers context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "multi-publisher"
            rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
            keyCardinality = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
            entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
        enqueuerSpec <- roleProcess check "keiro/outbox-enqueuer" 0 (object ["source" .= source, "rows" .= rowCount, "keyCardinality" .= keyCardinality])
        enqueuer <- spawn supervisor enqueuerSpec
        awaitReady enqueuer 10000
        sendCommand enqueuer CtlStart
        awaitMark enqueuer "finished" 120000
        children <- traverse (\index -> roleProcess check "keiro/outbox-publisher" index (object ["loop" .= True, "pauseMicros" .= (1000 :: Int)]) >>= spawn supervisor) [0 .. 3 :: Int]
        mapM_ (\child -> awaitReady child 10000) children
        mapM_ (\child -> sendCommand child CtlStart) children
        mapM_ (\child -> awaitMark child "finished" 300000) children
        histories <- traverse readChildMessages children
        rows <- runFixture (listOutbox source) >>= either (fail . show) pure
        records <- Broker.readBroker broker
        let messageIds = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            counts = Map.fromListWith (+) [(messageId, 1 :: Int) | messageId <- messageIds]
            expectedIds = map (TextEncoding.encodeUtf8 . (.messageId) . (.event)) rows
            expectedOrder = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, index)) | (messageId, Just key, index) <- entries]
            observedOrder = [pair | messageId <- messageIds, Just pair <- [Map.lookup messageId expectedOrder]]
            publisherCounts = Map.fromListWith (+) [(record.publisher, 1 :: Int) | record <- records]
            partitionOffsets = Map.fromListWith (<>) [((record.topic, record.partition), [record.offset]) | record <- records]
            contiguousOffsets = all (\offsets -> sort offsets == [0 .. fromIntegral (length offsets - 1)]) (Map.elems partitionOffsets)
            intervals = callbackIntervals histories
            claimedIds = [show row.outboxId | row <- rows]
            intervalCoverage = length intervals > 0 && sort (concatMap (\(_, _, _, ids) -> ids) intervals) == sort claimedIds
            ownership = intervalCoverage && Oracle.disjointIntervals [(startAt, endAt, ids) | (startAt, endAt, _, ids) <- intervals]
            cells =
              [ ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("disjoint-ownership", ownership && length records == rowCount && all (== 1) (Map.elems counts) && all ((== 1) . (.attemptCount)) rows),
                ("publisher-participation", Map.size publisherCounts >= 2),
                ("per-key-order", length observedOrder == rowCount && Oracle.perKeyOrder observedOrder),
                ("broker-partition-offsets", length records == rowCount && contiguousOffsets)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("publishers", 4)]
        recordMessagingCells context evidence (object ["publisherCounts" .= publisherCounts, "callbackIntervals" .= length intervals, "intervalCoverage" .= intervalCoverage]) cells

-- A repeated custom mark is retained in each child's control log. Pair marks
-- by child and batch number, and reject missing or mismatched end marks.
callbackIntervals :: [[WorkerMessage]] -> [(UTCTime, UTCTime, Int, [String])]
callbackIntervals histories =
  [ (startAt, endAt, childIndex, rowIds)
  | (childIndex, messages) <- zip [0 :: Int ..] histories,
    let ends = Map.fromList [(batch, (at, ids)) | WrkCustom "callback-end" payload <- messages, Just (batch, at, ids) <- [decodeMark payload]],
    WrkCustom "callback-start" payload <- messages,
    Just (batch, startAt, rowIds) <- [decodeMark payload],
    Just (endAt, endIds) <- [Map.lookup batch ends],
    rowIds == endIds
  ]
  where
    decodeMark :: Value -> Maybe (Int, UTCTime, [String])
    decodeMark = parseMaybe (withObject "callback mark" (\value -> (,,) <$> value .: "batch" <*> value .: "at" <*> value .: "rowIds"))

crashBetweenPublishAndMark :: Scenario
crashBetweenPublishAndMark =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/crash-between-publish-and-mark"),
      revision = 1,
      summary = "Kills a publisher before or after broker append and checks maintenance reclamation and bounded replay.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "outbox.rows") "Number of integration events" KnobInt (VInt 2000) (IntRange 32 20000) [],
          KnobSpec (knobName "outbox.kills") "Number of publisher processes killed" KnobInt (VInt 3) (IntRange 1 8) [],
          KnobSpec (knobName "outbox.key-cardinality") "Number of partition keys" KnobInt (VInt 20) (IntRange 1 200) [],
          KnobSpec (knobName "outbox.crash-point") "Publisher interruption point" KnobText (VText "after-broker-append") (OneOf (VText "after-broker-append" :| [VText "after-claim", VText "backend-kill-during-mark"])) [VText "after-claim", VText "backend-kill-during-mark"],
          KnobSpec (knobName "outbox.exhaust-attempts") "Make the last kill consume the attempt ceiling" KnobBool (VBool False) (OneOf (VBool False :| [VBool True])) []
        ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runCrashBetweenPublishAndMark
    }

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName

runCrashBetweenPublishAndMark :: RunContext -> IO ScenarioReport
runCrashBetweenPublishAndMark context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "crash"
            rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
            killCount = fromIntegral (knobInt context.knobs (knobName "outbox.kills"))
            afterClaim = knobText context.knobs (knobName "outbox.crash-point") == "after-claim"
            backendKill = knobText context.knobs (knobName "outbox.crash-point") == "backend-kill-during-mark"
            exhaustAttempts = knobBool context.knobs (knobName "outbox.exhaust-attempts")
            keyCardinality = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
            entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
            options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}
            hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
            callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks "recovery"
            readRows = runFixture (listOutbox source) >>= either (fail . show) pure
        enqueueInline fixture source entries
        let recordIds records = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            killBackendDuringMark child =
              bracket (holdLock (requirePostgres context) (TableLock "keiro" "keiro_outbox")).inject (.heal) \_ -> do
                let waitFor predicate = do
                      backends <- listBackends (requirePostgres context)
                      case filter predicate backends of
                        backend : _ -> pure backend
                        [] -> threadDelay 10000 >> waitFor predicate
                holder <- timeout 10000000 (waitFor (\backend -> backend.applicationName == "kenshou-fault-lock" && backend.waitEvent == Just "PgSleep"))
                case holder of
                  Nothing -> fail "table lock holder did not reach its sleep point"
                  Just _ -> pure ()
                sendCommand child (CtlCustom "continue" Null)
                victim <- timeout 10000000 (waitFor (\backend -> backend.applicationName /= "kenshou-fault-lock" && backend.waitEventType == Just "Lock" && "keiro_outbox" `Text.isInfixOf` backend.query))
                case victim of
                  Nothing -> fail "publisher did not block while finalizing the claimed rows"
                  Just backend -> do
                    _ <- (terminateOneBackend (requirePostgres context) (ByPid backend.pid)).inject
                    pure ()
            killOne index = do
              before <- Broker.readBroker broker
              spec <- roleProcess check "keiro/outbox-publisher" index (object ["parkBeforeAppend" .= afterClaim, "parkAfterAppend" .= not afterClaim])
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              awaitMark child (if afterClaim then "batch-claimed" else "broker-appended") 30000
              after <- Broker.readBroker broker
              if backendKill then killBackendDuringMark child else pure ()
              if backendKill then pure () else killChild supervisor child
              stranded <- readRows
              threadDelay (if index == 0 then 6000000 else 1500000)
              stillStranded <- readRows
              preMaintenance <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
              maintenance <- runFixture (outboxMaintenancePass (OutboxMaintenanceOptions (if exhaustAttempts then killCount else 10) 1) Nothing) >>= either (fail . show) pure
              reclaimed <- readRows
              let publishing rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxPublishing]
                  newIds = if afterClaim then Set.toList (publishing stranded) else drop (length before) (recordIds after)
                  failed rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxFailed]
                  dead rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxDead]
                  exhausted = exhaustAttempts && index == killCount - 1
                  reclaimedCorrectly = if exhausted then maintenance.deadLettered == 32 && Set.fromList newIds `Set.isSubsetOf` dead reclaimed else maintenance.requeued == 32 && Set.fromList newIds `Set.isSubsetOf` failed reclaimed
                  brokerWindow = if afterClaim then length after == length before else length after == length before + 32
                  held = brokerWindow && length newIds == 32 && publishing stranded == Set.fromList newIds && publishing stillStranded == Set.fromList newIds && preMaintenance.claimed == 0 && reclaimedCorrectly
              pure (newIds, held, fromIntegral (childPid child) :: Int)
        kills <- traverse killOne [0 .. killCount - 1]
        let drain = do
              backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
              if backlog == 0
                then pure ()
                else do
                  _ <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
                  threadDelay 10000
                  drain
        finished <- timeout (300 * 1000000) drain
        rows <- readRows
        records <- Broker.readBroker broker
        let messageIds = recordIds records
            counts = Map.fromListWith (+) [(messageId, 1 :: Int) | messageId <- messageIds]
            killedIds = Set.fromList (concat [ids | (ids, _, _) <- kills])
            firstIds = reverse (snd (foldl (\(seen, acc) messageId -> if Set.member messageId seen then (seen, acc) else (Set.insert messageId seen, messageId : acc)) (Set.empty, []) messageIds))
            expectedOrder = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, index)) | (messageId, Just key, index) <- entries]
            observedOrder = [pair | messageId <- firstIds, Just pair <- [Map.lookup messageId expectedOrder]]
            sentRows = [row | row <- rows, row.status == OutboxSent]
            deadRows = [row | row <- rows, row.status == OutboxDead]
            extras = length records - length sentRows
            cells =
              [ ("kill-window-realised", length kills == killCount && all (not . null . (\(ids, _, _) -> ids)) kills),
                ("reclaimed-only-by-maintenance", all (\(_, held, _) -> held) kills),
                ("drained-before-deadline", maybe False (const True) finished),
                ("no-loss", length rows == rowCount && length sentRows + length deadRows == rowCount && all (\row -> Map.member (TextEncoding.encodeUtf8 row.event.messageId) counts) sentRows && (if exhaustAttempts then not (null deadRows) else null deadRows)),
                ("attempts-exhausted-by-crashes", not exhaustAttempts || (afterClaim && all ((== killCount) . (.attemptCount)) deadRows && all (\row -> Map.notMember (TextEncoding.encodeUtf8 row.event.messageId) counts) deadRows)),
                ("bounded-duplicates", extras <= (if afterClaim then 0 else 32 * killCount) && all (\(messageId, count) -> count <= 1 + killCount && (count == 1 || Set.member messageId killedIds)) (Map.toList counts)),
                ("per-key-order", length observedOrder == length sentRows && Oracle.perKeyOrder observedOrder)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("killedPublishers", fromIntegral killCount), ("deadRows", fromIntegral (length deadRows)), ("duplicatedMessages", fromIntegral (length [() | count <- Map.elems counts, count > 1]))]
        recordMessagingCells context evidence (object ["crashPoint" .= knobText context.knobs (knobName "outbox.crash-point"), "killedPids" .= [pid | (_, _, pid) <- kills]]) cells
