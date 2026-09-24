module Kenshou.Suite.Keiro.Inbox.Correctness (scenarios, ensureEffectTable, effectReadStatement, effectInsertStatement) where

import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (..), CommandResult (..), defaultRunCommandOptions, runCommand)
import Keiro.Inbox (DelegatedOutcome (..), InboxDedupePolicy (..), InboxError (..), InboxPersistence (..), InboxResult (..), InboxRow (..), InboxStatus (..), KafkaDeliveryRef (..), dedupeKeyFor, garbageCollectCompleted, listInbox, mkDelegatedRetryContext, runInboxDelegated, runInboxDelegatedBatch, runInboxDelegatedWithRetries, runInboxTransactionBatch, runInboxTransactionWith, runInboxTransactionWithRetries)
import Keiro.Inbox.Delegated (DelegatedCommandError (..), delegatedCommand, delegatedEventId)
import Keiro.Inbox.Kafka (KafkaDecodeError (..), KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Integration.Event (IntegrationEvent (..), headerContentType, headerDestination, headerEventType, headerMessageId, headerSchemaVersion, headerSource)
import Keiro.Outbox (OutboxPublishOptions (..), OutboxRow (..), defaultPublishOptions, listOutbox, publishClaimedOutbox)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountEventStream, accountStream, accountStreamName)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountId (..), DepositData (..), OpenAccountData (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (CommandRunner (..), FixtureEnv (..), KeiroRunner (..), SubmitOutcome (..), submitAccountCommand, withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction qualified as KirokuTransaction
import Kiroku.Store.Types (EventId (..), RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [envelopeRoundTrip, poisonAccounting, effectivelyOnceMatrix, batchFastPathAndFallback]

batchFastPathAndFallback :: Scenario
batchFastPathAndFallback =
  envelopeRoundTrip
    { id = either (error . show) id (parseScenarioId "keiro/inbox/correctness/batch-fast-path-and-fallback"),
      summary = "Checks one-transaction batch intake and isolated fallback after a poisoned handler.",
      knobs =
        [ KnobSpec (knobName "inbox.failure-mode") "Batch poison mode" KnobText (VText "pure-exception") (OneOf (VText "pure-exception" :| [VText "condemn"])) [VText "condemn"],
          KnobSpec (knobName "inbox.idempotence") "Inbox receipt owner" KnobText (VText "inbox-table") (OneOf (VText "inbox-table" :| [VText "delegated"])) [VText "delegated"]
        ],
      run = runBatchFastPathAndFallback
    }

runBatchFastPathAndFallback :: RunContext -> IO ScenarioReport
runBatchFastPathAndFallback context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    if knobText context.knobs (knobName "inbox.idempotence") == "delegated"
      then runDelegatedBatch context fixture
      else runTransactionalBatch context fixture

runDelegatedBatch :: RunContext -> FixtureEnv -> IO ScenarioReport
runDelegatedBatch context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "delegated-batch"
  enqueueInline fixture source [("clean", Just "key", 1), ("poison", Just "key", 2), ("tail", Just "key", 3)]
  events <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  let byId name = case [event | event <- events, event.messageId == name] of
        [event] -> event
        _ -> error "delegated batch fixture event missing"
      clean = byId "clean"
      poison = byId "poison"
      tailEvent = byId "tail"
  calls <- newIORef ([] :: [Text.Text])
  poisonAttempts <- newIORef (0 :: Int)
  let handler _ event = do
        liftIO (modifyIORef' calls (<> [event.messageId]))
        if event.messageId == "poison"
          then do
            attempt <- liftIO (atomicModifyIORef' poisonAttempts (\n -> (n + 1, n + 1)))
            if attempt == 1 then pure $! error "synthetic delegated batch poison" else pure (DelegatedFresh ())
          else pure (DelegatedFresh ())
      intake batch = runFixture (runInboxDelegatedBatch Nothing PreferIntegrationMessageId [(event, Nothing) | event <- batch] handler) >>= either (fail . show) pure
  results <- intake [clean, clean, poison, poison, tailEvent]
  afterBatch <- readIORef calls
  nextCall <- intake [clean]
  afterNextCall <- readIORef calls
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  recordCells
    context
    [ ("delegated-batch-positional", case results of [Right (InboxProcessed ()), Right InboxDuplicate, Right (InboxHandlerFailed _ 1), Right (InboxProcessed ()), Right (InboxProcessed ())] -> True; _ -> False),
      ("delegated-batch-retries-failed-key", afterBatch == ["clean", "poison", "poison", "tail"]),
      ("delegated-batch-memory-is-call-local", nextCall == [Right (InboxProcessed ())] && afterNextCall == ["clean", "poison", "poison", "tail", "clean"]),
      ("delegated-batch-skips-inbox-table", null rows)
    ]

runTransactionalBatch :: RunContext -> FixtureEnv -> IO ScenarioReport
runTransactionalBatch context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "batch"
      condemning = knobText context.knobs (knobName "inbox.failure-mode") == "condemn"
      handler event
        | event.messageId == "poison" && condemning = do
            _ <- Tx.statement () poisonCallStatement
            Tx.condemn
        | event.messageId == "poison" = pure $! error "synthetic batch poison"
        | otherwise = Tx.statement event.messageId effectInsertStatement
      runBatch events = runFixture (runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope [(event, Nothing) | event <- events] handler) >>= either (fail . show) pure
  ensureEffectTable fixture
  _ <- runFixture (KirokuTransaction.runTransaction (Tx.sql "CREATE SEQUENCE IF NOT EXISTS kenshou_fx.poison_calls")) >>= either (fail . show) pure
  enqueueInline fixture source [("clean-a", Just "key", 1), ("clean-b", Just "key", 2), ("good-c", Just "key", 3), ("poison", Just "key", 4), ("good-d", Just "key", 5)]
  events <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  let byId name = case [event | event <- events, event.messageId == name] of
        [event] -> event
        _ -> error "batch fixture event missing"
      clean = [byId "clean-a", byId "clean-b", byId "clean-a"]
      poisoned = [byId "good-c", byId "poison", byId "good-d"]
  cleanResults <- runBatch clean
  cleanTxnCount <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectTxnCountStatement)) >>= either (fail . show) pure
  fallbackResults <- runBatch poisoned
  effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  poisonCalls <- runFixture (KirokuTransaction.runTransaction (Tx.statement () poisonCallCountStatement)) >>= either (fail . show) pure
  let cells =
        [ ("clean-batch-positional", cleanResults == [Right (InboxProcessed ()), Right (InboxProcessed ()), Right InboxDuplicate]),
          ("clean-batch-one-transaction", cleanTxnCount == (1 :: Int64)),
          ("fallback-isolates-poison", if condemning then fallbackResults == [Right (InboxProcessed ()), Right (InboxProcessed ()), Right (InboxProcessed ())] else case fallbackResults of [Right (InboxProcessed ()), Right (InboxHandlerFailed _ 1), Right (InboxProcessed ())] -> True; _ -> False),
          ("effects-once", all (\name -> length (filter (== name) effects) == 1) ["clean-a", "clean-b", "good-c", "good-d"] && length effects == 4),
          ("poison-receipt", if condemning then null [row | row <- rows, row.event.messageId == "poison"] && poisonCalls == 2 else case [row | row <- rows, row.event.messageId == "poison"] of [row] -> row.status == InboxFailed && row.attemptCount == 1; _ -> False)
        ]
  recordCells context cells

runDelegatedMatrix :: RunContext -> FixtureEnv -> IO ScenarioReport
runDelegatedMatrix context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "delegated-matrix"
      policyName = knobText context.knobs (knobName "inbox.dedupe-policy")
      account index = AccountId (source <> "-account-" <> Text.pack (show index))
      policy event = case policyName of
        "source-event" -> PreferSourceEventIdentity
        "kafka-delivery" -> KafkaDeliveryIdentity
        "custom" -> CustomDedupeKey (TextEncoding.decodeUtf8 event.payloadBytes)
        _ -> PreferIntegrationMessageId
      ref :: Int -> KafkaDeliveryRef
      ref index = KafkaDeliveryRef "kenshou.delegated" 0 (fromIntegral index)
      marker target event deliveryRef = do
        dedupe <- dedupeKeyFor (policy event) event deliveryRef
        pure (delegatedEventId "kenshou-consumer" event.source dedupe (accountStreamName target) "deposit")
      intake target event deliveryRef =
        runFixture
          ( runInboxDelegated Nothing (policy event) event deliveryRef \dedupe delivered -> do
              let targetName = accountStreamName target
                  receipt = delegatedEventId "kenshou-consumer" delivered.source dedupe targetName "deposit"
              result <- delegatedCommand defaultRunCommandOptions targetName receipt \prepared ->
                runCommand prepared (accountEventStream SnapNever) (accountStream target) (Deposit (DepositData target 1 "delegated"))
              either (error . show) pure result
          )
          >>= either (fail . show) pure
  enqueueInline fixture source [(Text.pack (show index), Just "key", index) | index <- [1 .. 16 :: Int]]
  original <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  let events = zipWith (\index event -> event {sourceEventId = Just (EventId (UUID.fromWords 0 0 0 (fromIntegral index)))}) [1 .. 16 :: Int] original
      republish = [event {messageId = event.messageId <> "-republished"} | event <- events]
      doubled = policyName == "message-id" || policyName == "kafka-delivery"
      coordinates = zip3 [1 .. 16 :: Int] events republish
  firstEvent <- case events of
    event : _ -> pure event
    [] -> fail "delegated matrix fixture produced no events"
  let malformed = case policyName of
        "source-event" -> firstEvent {sourceEventId = Nothing, sourceGlobalPosition = Nothing, messageId = "malformed"}
        "custom" -> firstEvent {payloadBytes = ByteString.empty, messageId = "malformed"}
        _ -> firstEvent {messageId = ""}
  seeded <- traverse (\(index, _, _) -> submitAccountCommand fixture (accountEventStream SnapNever) RunnerPlain defaultRunCommandOptions 0 (EventId (UUID.fromWords 0 1 0 (fromIntegral index))) (OpenAccount (OpenAccountData (account index) 0))) coordinates
  first <- traverse (\(index, event, _) -> intake (account index) event (Just (ref index))) coordinates
  second <- traverse (\(index, event, _) -> intake (account index) event (Just (ref index))) coordinates
  republished <- traverse (\(index, _, event) -> intake (account index) event (Just (ref (index + 16)))) coordinates
  missing <- intake (account 1) malformed (if policyName == "kafka-delivery" then Nothing else Just (ref 100))
  streamChecks <-
    traverse
      ( \(index, event, republishedEvent) -> do
          recorded <- runFixture (readStreamForward (accountStreamName (account index)) (StreamVersion 0) 10) >>= either (fail . show) pure
          firstMarker <- either (fail . show) pure (marker (account index) event (Just (ref index)))
          secondMarker <- either (fail . show) pure (marker (account index) republishedEvent (Just (ref (index + 16))))
          let ids = map (.eventId) (Vector.toList recorded)
              openingId = EventId (UUID.fromWords 0 1 0 (fromIntegral index))
          pure (ids == (if doubled then [openingId, firstMarker, secondMarker] else [openingId, firstMarker]))
      )
      coordinates
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  let negativeTarget = account 1
      negativeName = accountStreamName negativeTarget
      noOpMarker = delegatedEventId "kenshou-consumer" source "no-op" negativeName "deposit"
      rejectedMarker = delegatedEventId "kenshou-consumer" source "rejected" negativeName "deposit"
  noOp <-
    runFixture
      ( delegatedCommand defaultRunCommandOptions negativeName noOpMarker \_ ->
          pure (Right (CommandResult (accountStream negativeTarget) (StreamVersion 2) Nothing 0))
      )
      >>= either (fail . show) pure
  rejected <-
    runFixture
      ( delegatedCommand defaultRunCommandOptions negativeName rejectedMarker \_ ->
          pure (Left CommandRejected)
      )
      >>= either (fail . show) pure
  afterRefusals <- runFixture (readStreamForward negativeName (StreamVersion 0) 10) >>= either (fail . show) pure
  let processed = \case Right (InboxProcessed _) -> True; _ -> False
      cells =
        [ ("seeded-account-targets", length seeded == 16 && all (== SubmitAppended (StreamVersion 1)) seeded),
          ("delegated-first-delivery", length first == 16 && all processed first),
          ("delegated-redelivery", length second == 16 && all (== Right InboxDuplicate) second),
          ("delegated-republish-policy", length republished == 16 && all (if doubled then processed else (== Right InboxDuplicate)) republished),
          ("delegated-stream-receipts", and streamChecks),
          ("delegated-missing-policy-field-fails-closed", case missing of Left (DedupePolicyUnsatisfied _) -> True; _ -> False),
          ("delegated-skips-inbox-table", null rows),
          ("delegated-no-op-refused", noOp == Left (DelegatedCommandWithoutReceipt negativeName)),
          ("delegated-rejection-refused", rejected == Left (DelegatedCommandFailed negativeName CommandRejected)),
          ("delegated-refusals-leave-stream-unchanged", Vector.length afterRefusals == if doubled then 3 else 2)
        ]
  recordCells context cells

effectTxnCountStatement :: Statement.Statement () Int64
effectTxnCountStatement = Statement.preparable "SELECT count(DISTINCT txid) FROM kenshou_fx.inbox_effects" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

ensureEffectTable :: FixtureEnv -> IO ()
ensureEffectTable fixture = do
  let KeiroRunner runFixture = fixture.runner
  _ <- runFixture (KirokuTransaction.runTransaction (Tx.sql "CREATE SCHEMA IF NOT EXISTS kenshou_fx")) >>= either (fail . show) pure
  _ <- runFixture (KirokuTransaction.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS kenshou_fx.inbox_effects (message_id text NOT NULL, txid bigint NOT NULL)")) >>= either (fail . show) pure
  pure ()

effectivelyOnceMatrix :: Scenario
effectivelyOnceMatrix =
  envelopeRoundTrip
    { id = either (error . show) id (parseScenarioId "keiro/inbox/correctness/effectively-once-matrix"),
      summary = "Checks message identity deduplication and persisted envelope shape under redelivery.",
      tier = TierStandard,
      knobs =
        [ KnobSpec (knobName "inbox.persistence") "Successful inbox row envelope storage" KnobText (VText "full-envelope") (OneOf (VText "full-envelope" :| [VText "dedupe-only"])) [VText "dedupe-only"],
          KnobSpec (knobName "inbox.dedupe-policy") "Inbox dedupe identity" KnobText (VText "message-id") (OneOf (VText "message-id" :| [VText "source-event", VText "kafka-delivery", VText "custom"])) [VText "source-event", VText "kafka-delivery", VText "custom"],
          KnobSpec (knobName "inbox.idempotence") "Inbox receipt owner" KnobText (VText "inbox-table") (OneOf (VText "inbox-table" :| [VText "delegated"])) [VText "delegated"]
        ],
      run = runEffectivelyOnceMatrix
    }

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName

runEffectivelyOnceMatrix :: RunContext -> IO ScenarioReport
runEffectivelyOnceMatrix context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    if knobText context.knobs (knobName "inbox.idempotence") == "delegated"
      then runDelegatedMatrix context fixture
      else runTableMatrix context fixture

runTableMatrix :: RunContext -> FixtureEnv -> IO ScenarioReport
runTableMatrix context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "matrix"
      persistence = if knobText context.knobs (knobName "inbox.persistence") == "dedupe-only" then PersistDedupeOnly else PersistFullEnvelope
      policyName = knobText context.knobs (knobName "inbox.dedupe-policy")
      policy event = case policyName of
        "source-event" -> PreferSourceEventIdentity
        "kafka-delivery" -> KafkaDeliveryIdentity
        "custom" -> CustomDedupeKey (TextEncoding.decodeUtf8 event.payloadBytes)
        _ -> PreferIntegrationMessageId
      entries = [(Text.pack (show i), Just "key", i) | i <- [1 .. 16 :: Int]]
      handler event = Tx.statement event.messageId effectInsertStatement
      intake event deliveryRef = runFixture (runInboxTransactionWith Nothing persistence (policy event) event deliveryRef handler) >>= either (fail . show) pure
      ref :: Int -> KafkaDeliveryRef
      ref index = KafkaDeliveryRef "kenshou.matrix" 0 (fromIntegral index)
  ensureEffectTable fixture
  enqueueInline fixture source entries
  original <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  let events = zipWith (\index event -> event {sourceEventId = Just (EventId (UUID.fromWords 0 0 0 (fromIntegral index)))}) [1 .. 16 :: Int] original
      republish = [event {messageId = event.messageId <> "-republished"} | event <- events]
  firstEvent <- case events of
    event : _ -> pure event
    [] -> fail "matrix fixture produced no events"
  let malformed = case policyName of
        "source-event" -> firstEvent {sourceEventId = Nothing, sourceGlobalPosition = Nothing, messageId = "malformed"}
        "custom" -> firstEvent {payloadBytes = ByteString.empty, messageId = "malformed"}
        _ -> firstEvent {messageId = ""}
  first <- traverse (\(index, event) -> intake event (Just (ref index))) (zip [1 .. 16 :: Int] events)
  second <- traverse (\(index, event) -> intake event (Just (ref index))) (zip [1 .. 16 :: Int] events)
  republished <- traverse (\(index, event) -> intake event (Just (ref (index + 16)))) (zip [1 .. 16 :: Int] republish)
  missing <- intake malformed (if policyName == "kafka-delivery" then Nothing else Just (ref 100))
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
  let eventIds = map (.messageId) events
      doubled = policyName == "message-id" || policyName == "kafka-delivery"
      expectedEffects = if doubled then 32 else 16
      processed = \case Right (InboxProcessed _) -> True; _ -> False
      cells =
        [ ("first-delivery-processed", length first == 16 && all processed first),
          ("redelivery-duplicate", length second == 16 && all (== Right InboxDuplicate) second),
          ("republish-policy", length republished == 16 && all (if doubled then processed else (== Right InboxDuplicate)) republished),
          ("effect-count-by-policy", length effects == expectedEffects && all (\messageId -> length (filter (== messageId) effects) == 1) eventIds),
          ("one-completed-row-per-key", length rows == expectedEffects && all ((== InboxCompleted) . (.status)) rows),
          ("missing-policy-field-fails-closed", case missing of Left (DedupePolicyUnsatisfied _) -> True; _ -> False),
          ("persistence-shape", all (\row -> if persistence == PersistDedupeOnly then ByteString.null row.event.payloadBytes && row.event.attributes == Nothing && row.event.traceContext == Nothing && row.event.schemaReference == Nothing else not (ByteString.null row.event.payloadBytes) && row.event.attributes /= Nothing) rows)
        ]
  recordCells context cells

effectInsertStatement :: Statement.Statement Text.Text ()
effectInsertStatement = Statement.preparable "INSERT INTO kenshou_fx.inbox_effects (message_id, txid) VALUES ($1, txid_current())" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult

effectReadStatement :: Statement.Statement () [Text.Text]
effectReadStatement = Statement.preparable "SELECT message_id FROM kenshou_fx.inbox_effects" Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

poisonAccounting :: Scenario
poisonAccounting =
  envelopeRoundTrip
    { id = either (error . show) id (parseScenarioId "keiro/inbox/correctness/poison-accounting"),
      summary = "Checks retry ceiling, failure receipt retention, and recovery after two failed attempts.",
      knobs =
        [ KnobSpec (knobName "inbox.failure-mode") "Inbox handler failure mode" KnobText (VText "pure-exception") (OneOf (VText "pure-exception" :| [VText "sql-error", VText "condemn"])) [VText "sql-error", VText "condemn"],
          KnobSpec (knobName "inbox.idempotence") "Inbox receipt owner" KnobText (VText "inbox-table") (OneOf (VText "inbox-table" :| [VText "delegated"])) [VText "delegated"]
        ],
      run = runPoisonAccounting
    }

runPoisonAccounting :: RunContext -> IO ScenarioReport
runPoisonAccounting context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    case (knobText context.knobs (knobName "inbox.idempotence"), knobText context.knobs (knobName "inbox.failure-mode")) of
      ("delegated", _) -> runPoisonDelegated context fixture
      (_, "sql-error") -> runPoisonSpecial context fixture "sql-error"
      (_, "condemn") -> runPoisonSpecial context fixture "condemn"
      _ -> runPoisonException context fixture

runPoisonDelegated :: RunContext -> FixtureEnv -> IO ScenarioReport
runPoisonDelegated context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "delegated-poison"
  enqueueInline fixture source [("poison", Just "key", 1)]
  events <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  event <- case events of
    [one] -> pure one
    _ -> fail "delegated poison fixture did not contain exactly one event"
  calls <- newIORef (0 :: Int)
  let intake attempt = do
        retryContext <- either (fail . Text.unpack) pure (mkDelegatedRetryContext 3 attempt)
        runFixture
          ( runInboxDelegatedWithRetries Nothing retryContext PreferIntegrationMessageId event Nothing \_ _ -> do
              liftIO (modifyIORef' calls (+ 1))
              pure (DelegatedFresh ())
          )
          >>= either (fail . show) pure
  aboveCeiling <- intake 4
  callsAfterCeiling <- readIORef calls
  withinCeiling <- intake 3
  callsAfterAttempt <- readIORef calls
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  recordCells
    context
    [ ("delegated-ceiling-stops-handler", aboveCeiling == Right (InboxPreviouslyFailed Nothing) && callsAfterCeiling == 0),
      ("delegated-within-ceiling-runs-handler", withinCeiling == Right (InboxProcessed ()) && callsAfterAttempt == 1),
      ("delegated-retry-has-no-inbox-row", null rows)
    ]

runPoisonException :: RunContext -> FixtureEnv -> IO ScenarioReport
runPoisonException context fixture = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context "poison"
      poisonHandler :: IntegrationEvent -> Tx.Transaction ()
      poisonHandler _ = pure $! error "synthetic poison"
      successHandler :: IntegrationEvent -> Tx.Transaction ()
      successHandler _ = pure ()
      intake event handler = runFixture (runInboxTransactionWithRetries Nothing 3 PreferIntegrationMessageId event Nothing handler) >>= either (fail . show) pure
  enqueueInline fixture source [("poison", Just "key", 1), ("recovery", Just "key", 2)]
  sourceRows <- runFixture (listOutbox source) >>= either (fail . show) pure
  let poison = case [row.event | row <- sourceRows, row.event.messageId == "poison"] of
        [event] -> event
        _ -> error "poison event missing"
      recovery = case [row.event | row <- sourceRows, row.event.messageId == "recovery"] of
        [event] -> event
        _ -> error "recovery event missing"
  poisonResults <- sequence [intake poison poisonHandler | _ <- [1 .. 4 :: Int]]
  recoveryFailures <- sequence [intake recovery poisonHandler | _ <- [1 .. 2 :: Int]]
  recovered <- intake recovery successHandler
  duplicate <- intake recovery successHandler
  now <- getCurrentTime
  _ <- runFixture (garbageCollectCompleted 0 now) >>= either (fail . show) pure
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  let poisonRows = [row | row <- rows, row.event.messageId == "poison"]
      recoveryRows = [row | row <- rows, row.event.messageId == "recovery"]
      isFailed attempt = \case
        Right (InboxHandlerFailed _ actual) -> actual == attempt
        _ -> False
      cells =
        [ ("failure-attempts", and (zipWith isFailed [1 .. 3] (take 3 poisonResults))),
          ("ceiling-stops-retry", case drop 3 poisonResults of [Right (InboxPreviouslyFailed _)] -> True; _ -> False),
          ("failed-row-survives-gc", case poisonRows of [row] -> row.status == InboxFailed && row.attemptCount == 3; _ -> False),
          ("recovery-after-two-failures", and (zipWith isFailed [1, 2] recoveryFailures) && recovered == Right (InboxProcessed ()) && duplicate == Right InboxDuplicate && null recoveryRows)
        ]
  recordCells context cells

runPoisonSpecial :: RunContext -> FixtureEnv -> Text.Text -> IO ScenarioReport
runPoisonSpecial context fixture mode = do
  let KeiroRunner runFixture = fixture.runner
      source = sourceName context ("poison-" <> mode)
      handler :: IntegrationEvent -> Tx.Transaction ()
      handler _ = do
        _ <- Tx.statement () poisonCallStatement
        if mode == "condemn"
          then Tx.condemn
          else do
            _ <- Tx.statement () poisonSqlErrorStatement
            pure ()
      intake event = runFixture (runInboxTransactionWithRetries Nothing 3 PreferIntegrationMessageId event Nothing handler)
  ensureEffectTable fixture
  _ <- runFixture (KirokuTransaction.runTransaction (Tx.sql "CREATE SEQUENCE IF NOT EXISTS kenshou_fx.poison_calls")) >>= either (fail . show) pure
  enqueueInline fixture source [("poison", Just "key", 1)]
  events <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
  event <- case events of
    [one] -> pure one
    _ -> fail "poison fixture did not contain exactly one event"
  first <- intake event
  second <- if mode == "condemn" then Just <$> intake event else pure Nothing
  rows <- runFixture (listInbox source) >>= either (fail . show) pure
  effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
  calls <- runFixture (KirokuTransaction.runTransaction (Tx.statement () poisonCallCountStatement)) >>= either (fail . show) pure
  let noCompletion = null effects && all ((/= InboxCompleted) . (.status)) rows
      cells
        | mode == "condemn" =
            [ ("condemned-call-reports-processed", first == Right (Right (InboxProcessed ())) && second == Just (Right (Right (InboxProcessed ())))),
              ("condemned-call-rolls-back", noCompletion && null rows),
              ("redelivery-runs-handler-again", calls == 2)
            ]
        | otherwise =
            [ ("sql-error-has-no-completed-effect", noCompletion),
              ("sql-error-handler-attempted", calls == 1)
            ]
  recordMessagingCells context (Map.fromList [("handlerCalls", calls), ("inboxRows", fromIntegral (length rows))]) (object ["failureMode" .= mode, "firstClassification" .= show first, "secondClassification" .= fmap show second]) cells

poisonCallStatement :: Statement.Statement () Int64
poisonCallStatement = Statement.preparable "SELECT nextval('kenshou_fx.poison_calls')" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

poisonCallCountStatement :: Statement.Statement () Int64
poisonCallCountStatement = Statement.preparable "SELECT last_value FROM kenshou_fx.poison_calls" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

poisonSqlErrorStatement :: Statement.Statement () Int64
poisonSqlErrorStatement = Statement.preparable "SELECT (1 / 0)::bigint" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

envelopeRoundTrip :: Scenario
envelopeRoundTrip =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/inbox/correctness/envelope-round-trip"),
      revision = 1,
      summary = "Checks the Keiro outbox wire record decodes to the original integration event and required headers fail closed.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runEnvelopeRoundTrip
    }

runEnvelopeRoundTrip :: RunContext -> IO ScenarioReport
runEnvelopeRoundTrip context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "envelope"
        entries = [(Text.pack (show i), Just ("key-" <> Text.pack (show (i `mod` (4 :: Int)))), i) | i <- [1 .. 16 :: Int]]
        options = defaultPublishOptions {batchSize = 16}
        hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
    enqueueInline fixture source entries
    original <- runFixture (listOutbox source) >>= either (fail . show) pure
    broker <- Broker.newBroker
    _ <- runFixture (publishClaimedOutbox (Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks "envelope") options Nothing) >>= either (fail . show) pure
    records <- Broker.readBroker broker
    let decoded = [(event, reference) | record <- records, Right (event, reference) <- [integrationEventFromKafka (Broker.toInboundRecord record.appendedAt record)]]
        originalEvents = map (.event) original
        decodedEvents = map fst decoded
        required = [headerMessageId, headerSource, headerDestination, headerEventType, headerSchemaVersion, headerContentType]
        headerFails record name =
          let inbound = Broker.toInboundRecord record.appendedAt record
           in integrationEventFromKafka inbound {headers = filter ((/= name) . fst) inbound.headers} == Left (MissingHeader name)
        cells =
          [ ("all-records-decoded", length records == 16 && length decoded == 16),
            ("envelope-round-trip", all (`elem` decodedEvents) originalEvents && all (`elem` originalEvents) decodedEvents),
            ("required-headers", all (\record -> all (headerFails record) required) records)
          ]
    recordCells context cells
