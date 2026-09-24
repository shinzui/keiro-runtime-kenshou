module Kenshou.Suite.Keiro.Outbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Int (Int32)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), IntegrationEventDraft (..), IntegrationProducer (..), OutboxMaintenanceOptions (..), OutboxMaintenanceSummary (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), ProducerEnqueueOutcome (..), ProducerIdentity (..), countOutboxBacklog, defaultPublishOptions, enqueueIntegrationEventTx, enqueueProducerEventTx, freshOutboxId, listOutbox, mkIntegrationProducer, outboxMaintenancePass, publishClaimedOutbox)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), LockTarget (..), holdLock, listBackends)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, killChild, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), inconclusiveBecause)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells, recordMessagingCellsClassified)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, inlineEvent, sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [crashBetweenPublishAndMark, multiProcessPublishers, concurrentInlineEnqueueOrder]

concurrentInlineEnqueueOrder :: Scenario
concurrentInlineEnqueueOrder =
  crashBetweenPublishAndMark
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/concurrent-inline-enqueue-order"),
      summary = "Stages opposite transaction-start and commit order for inline events, with a serialized producer-path control.",
      tier = TierSmoke,
      knobs = [KnobSpec (knobName "outbox.enqueue-path") "Inline race or serialized producer control" KnobText (VText "inline") (OneOf (VText "inline" :| [VText "producer"])) [VText "producer"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16" "Concurrent inline enqueues can publish one key out of producer order" ["per-key-order"] AllCohorts),
      run = runConcurrentInlineEnqueueOrder
    }

runConcurrentInlineEnqueueOrder :: RunContext -> IO ScenarioReport
runConcurrentInlineEnqueueOrder context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      if knobText context.knobs (knobName "outbox.enqueue-path") == "producer"
        then runProducerPathControl context fixture broker
        else runInlineOrderRace context fixture broker

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
        enqueueInline fixture source entries
        children <- traverse (\index -> roleProcess check "keiro/outbox-publisher" index (object ["loop" .= True, "pauseMicros" .= (1000 :: Int)]) >>= spawn supervisor) [0 .. 3 :: Int]
        mapM_ (\child -> awaitReady child 10000) children
        mapM_ (\child -> sendCommand child CtlStart) children
        mapM_ (\child -> awaitMark child "finished" 300000) children
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
            cells =
              [ ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("disjoint-ownership", length records == rowCount && all (== 1) (Map.elems counts) && all ((== 1) . (.attemptCount)) rows),
                ("publisher-participation", Map.size publisherCounts >= 2),
                ("per-key-order", length observedOrder == rowCount && Oracle.perKeyOrder observedOrder),
                ("broker-partition-offsets", length records == rowCount && contiguousOffsets)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("publishers", 4)]
        recordMessagingCells context evidence (object ["publisherCounts" .= publisherCounts]) cells

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
          KnobSpec (knobName "outbox.crash-point") "Publisher interruption point" KnobText (VText "after-broker-append") (OneOf (VText "after-broker-append" :| [VText "after-claim"])) [VText "after-claim"]
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
            keyCardinality = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
            entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
            options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}
            hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
            callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks "recovery"
            readRows = runFixture (listOutbox source) >>= either (fail . show) pure
        enqueueInline fixture source entries
        let recordIds records = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            killOne index = do
              before <- Broker.readBroker broker
              spec <- roleProcess check "keiro/outbox-publisher" index (object ["parkBeforeAppend" .= afterClaim, "parkAfterAppend" .= not afterClaim])
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              awaitMark child (if afterClaim then "batch-claimed" else "broker-appended") 30000
              after <- Broker.readBroker broker
              killChild supervisor child
              stranded <- readRows
              threadDelay (if index == 0 then 6000000 else 1500000)
              stillStranded <- readRows
              preMaintenance <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
              maintenance <- runFixture (outboxMaintenancePass (OutboxMaintenanceOptions 10 1) Nothing) >>= either (fail . show) pure
              reclaimed <- readRows
              let publishing rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxPublishing]
                  newIds = if afterClaim then Set.toList (publishing stranded) else drop (length before) (recordIds after)
                  failed rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxFailed]
                  brokerWindow = if afterClaim then length after == length before else length after == length before + 32
                  held = brokerWindow && length newIds == 32 && publishing stranded == Set.fromList newIds && publishing stillStranded == Set.fromList newIds && preMaintenance.claimed == 0 && maintenance.requeued == 32 && Set.fromList newIds `Set.isSubsetOf` failed reclaimed
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
            expectedIds = map (TextEncoding.encodeUtf8 . (.messageId) . (.event)) rows
            killedIds = Set.fromList (concat [ids | (ids, _, _) <- kills])
            firstIds = reverse (snd (foldl (\(seen, acc) messageId -> if Set.member messageId seen then (seen, acc) else (Set.insert messageId seen, messageId : acc)) (Set.empty, []) messageIds))
            expectedOrder = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, index)) | (messageId, Just key, index) <- entries]
            observedOrder = [pair | messageId <- firstIds, Just pair <- [Map.lookup messageId expectedOrder]]
            extras = length records - rowCount
            cells =
              [ ("kill-window-realised", length kills == killCount && all (not . null . (\(ids, _, _) -> ids)) kills),
                ("reclaimed-only-by-maintenance", all (\(_, held, _) -> held) kills),
                ("drained-before-deadline", maybe False (const True) finished),
                ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("bounded-duplicates", extras <= (if afterClaim then 0 else 32 * killCount) && all (\(messageId, count) -> count <= 1 + killCount && (count == 1 || Set.member messageId killedIds)) (Map.toList counts)),
                ("per-key-order", length observedOrder == rowCount && Oracle.perKeyOrder observedOrder)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("killedPublishers", fromIntegral killCount), ("duplicatedMessages", fromIntegral (length [() | count <- Map.elems counts, count > 1]))]
        recordMessagingCells context evidence (object ["crashPoint" .= knobText context.knobs (knobName "outbox.crash-point"), "killedPids" .= [pid | (_, _, pid) <- kills]]) cells
