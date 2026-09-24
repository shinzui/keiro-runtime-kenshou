module Kenshou.Suite.Keiro.Inbox.Correctness (scenarios, ensureEffectTable, effectReadStatement, effectInsertStatement) where

import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..), InboxRow (..), InboxStatus (..), garbageCollectCompleted, listInbox, runInboxTransactionBatch, runInboxTransactionWith, runInboxTransactionWithRetries)
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
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Transaction qualified as KirokuTransaction

scenarios :: [Scenario]
scenarios = [envelopeRoundTrip, poisonAccounting, effectivelyOnceMatrix, batchFastPathAndFallback]

batchFastPathAndFallback :: Scenario
batchFastPathAndFallback =
  envelopeRoundTrip
    { id = either (error . show) id (parseScenarioId "keiro/inbox/correctness/batch-fast-path-and-fallback"),
      summary = "Checks one-transaction batch intake and isolated fallback after a poisoned handler.",
      run = runBatchFastPathAndFallback
    }

runBatchFastPathAndFallback :: RunContext -> IO ScenarioReport
runBatchFastPathAndFallback context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "batch"
        handler event
          | event.messageId == "poison" = pure $! error "synthetic batch poison"
          | otherwise = Tx.statement event.messageId effectInsertStatement
        runBatch events = runFixture (runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope [(event, Nothing) | event <- events] handler) >>= either (fail . show) pure
    ensureEffectTable fixture
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
    let cells =
          [ ("clean-batch-positional", cleanResults == [Right (InboxProcessed ()), Right (InboxProcessed ()), Right InboxDuplicate]),
            ("clean-batch-one-transaction", cleanTxnCount == (1 :: Int64)),
            ("fallback-isolates-poison", case fallbackResults of [Right (InboxProcessed ()), Right (InboxHandlerFailed _ 1), Right (InboxProcessed ())] -> True; _ -> False),
            ("effects-once", all (\name -> length (filter (== name) effects) == 1) ["clean-a", "clean-b", "good-c", "good-d"] && length effects == 4),
            ("poison-failed-row", case [row | row <- rows, row.event.messageId == "poison"] of [row] -> row.status == InboxFailed && row.attemptCount == 1; _ -> False)
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
      knobs = [KnobSpec (knobName "inbox.persistence") "Successful inbox row envelope storage" KnobText (VText "full-envelope") (OneOf (VText "full-envelope" :| [VText "dedupe-only"])) [VText "dedupe-only"]],
      run = runEffectivelyOnceMatrix
    }

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName

runEffectivelyOnceMatrix :: RunContext -> IO ScenarioReport
runEffectivelyOnceMatrix context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "matrix"
        persistence = if knobText context.knobs (knobName "inbox.persistence") == "dedupe-only" then PersistDedupeOnly else PersistFullEnvelope
        entries = [(Text.pack (show i), Just "key", i) | i <- [1 .. 16 :: Int]]
        handler event = Tx.statement event.messageId effectInsertStatement
        intake event = runFixture (runInboxTransactionWith Nothing persistence PreferIntegrationMessageId event Nothing handler) >>= either (fail . show) pure
    ensureEffectTable fixture
    enqueueInline fixture source entries
    events <- map (.event) <$> (runFixture (listOutbox source) >>= either (fail . show) pure)
    first <- traverse intake events
    second <- traverse intake events
    rows <- runFixture (listInbox source) >>= either (fail . show) pure
    effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
    let eventIds = map (.messageId) events
        rowIds = map (.dedupeKey) rows
        cells =
          [ ("first-delivery-processed", length first == 16 && all (\case Right (InboxProcessed _) -> True; _ -> False) first),
            ("redelivery-duplicate", length second == 16 && all (== Right InboxDuplicate) second),
            ("one-effect-per-key", length effects == 16 && all (\messageId -> length (filter (== messageId) effects) == 1) eventIds),
            ("one-completed-row-per-key", length rows == 16 && all ((== InboxCompleted) . (.status)) rows && all (`elem` rowIds) eventIds),
            ("persistence-shape", all (\row -> if persistence == PersistDedupeOnly then ByteString.null row.event.payloadBytes else not (ByteString.null row.event.payloadBytes)) rows)
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
      run = runPoisonAccounting
    }

runPoisonAccounting :: RunContext -> IO ScenarioReport
runPoisonAccounting context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
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
