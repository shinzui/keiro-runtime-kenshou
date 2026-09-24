module Kenshou.Suite.Keiro.Outbox.Correctness (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), IntegrationEventDraft (..), IntegrationProducer (..), OrderingPolicy (..), OutboxId (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), ProducerEnqueueOutcome (..), PublishOutcome (..), countOutboxBacklog, defaultMaintenanceOptions, defaultPublishOptions, enqueueProducerEventTx, garbageCollectSent, listOutbox, mkIntegrationProducer, mkPublishRejection, outboxMaintenancePass, publishClaimedOutbox, publishRejectionCode)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobValue (..), knobDouble, knobInt, mkKnobName, renderKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Knobs qualified as OutboxKnobs
import Kenshou.Suite.Keiro.Outbox.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [failureSkipsSuccessors, terminalStateMatrix, perKeyOrderSerialized, publisherMisbehaviour]

publisherMisbehaviour :: Scenario
publisherMisbehaviour =
  failureSkipsSuccessors
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/publisher-misbehaviour"),
      summary = "Checks callback exceptions, missing and unknown outcomes, and terminal rejection.",
      run = runPublisherMisbehaviour
    }

runPublisherMisbehaviour :: RunContext -> IO ScenarioReport
runPublisherMisbehaviour context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        options = defaultPublishOptions {batchSize = 16, backoff = ConstantBackoff 60}
        enqueueCase suffix = do
          let source = sourceName context suffix
              key index = Just (if suffix == "reject" then suffix else suffix <> index)
          enqueueInline fixture source [(suffix <> "1", key "1", 1), (suffix <> "2", key "2", 2)]
          pure source
        readCase source = runFixture (listOutbox source) >>= either (fail . show) pure
        publish callback = runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
    throwSource <- enqueueCase "throw"
    throwSummary <- publish (\_ -> error "synthetic callback threw")
    throwRows <- readCase throwSource

    missingSource <- enqueueCase "missing"
    missingSummary <- publish (\_ -> pure [])
    missingRows <- readCase missingSource

    unknownSource <- enqueueCase "unknown"
    unknownSummary <- publish (\rows -> pure ([(row.outboxId, PublishSucceeded) | row <- rows] <> [(OutboxId UUID.nil, PublishSucceeded)]))
    unknownRows <- readCase unknownSource

    rejectionSource <- enqueueCase "reject"
    rejection <- either (fail . show) pure (mkPublishRejection "synthetic_rejection" (Just "refused by broker"))
    broker <- Broker.newBroker
    let model = Broker.BrokerModel 0 0 4
        hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
        choose row = if row.event.messageId == "reject1" then Broker.RejectWith rejection else Broker.Succeed
    rejectSummary <- publish (Broker.publishScripted broker model choose hooks "publisher")
    rejectRows <- readCase rejectionSource
    _ <- runFixture (outboxMaintenancePass defaultMaintenanceOptions Nothing) >>= either (fail . show) pure
    now <- getCurrentTime
    _ <- runFixture (garbageCollectSent 0 now) >>= either (fail . show) pure
    afterGc <- readCase rejectionSource
    brokerRows <- Broker.readBroker broker
    let runRejectionPolicy policy suffix = do
          let source = sourceName context suffix
              firstId = suffix <> "1"
              secondId = suffix <> "2"
          enqueueInline fixture source [(firstId, Just suffix, 1), (secondId, Just suffix, 2)]
          policyBroker <- Broker.newBroker
          let decide row = if row.event.messageId == firstId then Broker.RejectWith rejection else Broker.Succeed
          policySummary <- runFixture (publishClaimedOutbox (Broker.publishScripted policyBroker model decide hooks "publisher") options {orderingPolicy = policy} Nothing) >>= either (fail . show) pure
          policyRows <- readCase source
          policyRecords <- Broker.readBroker policyBroker
          let policyById = Map.fromList [(row.event.messageId, row) | row <- policyRows]
          pure (policySummary.rejected == 1 && policySummary.published == 1 && policySummary.haltedOn == Nothing && maybe False ((== OutboxRejected) . (.status)) (Map.lookup firstId policyById) && maybe False ((== OutboxSent) . (.status)) (Map.lookup secondId policyById) && length policyRecords == 1)
    perSourceRejection <- runRejectionPolicy PerSourceStream "reject-source"
    stopLineRejection <- runRejectionPolicy StopTheLine "reject-stop"
    producerReplay <- do
      at <- getCurrentTime
      let source = sourceName context "reject-producer"
          producer :: IntegrationProducer ()
          producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "reject-producer" source "kenshou" (\_ _ -> Nothing)))
          recorded =
            RecordedEvent
              { eventId = EventId UUID.nil,
                eventType = EventType "RejectProbe",
                streamVersion = StreamVersion 1,
                globalPosition = GlobalPosition 1,
                originalStreamId = StreamId 1,
                originalVersion = StreamVersion 1,
                payload = Aeson.object [],
                metadata = Nothing,
                causationId = Nothing,
                correlationId = Nothing,
                createdAt = at
              }
          draft =
            IntegrationEventDraft
              { destination = "kenshou.outbox.v1",
                key = Just "reject-producer",
                eventType = "RejectProbe",
                schemaVersion = 1,
                contentType = ApplicationJson,
                schemaReference = Nothing,
                sourceEventId = Nothing,
                sourceGlobalPosition = Nothing,
                payloadBytes = TextEncoding.encodeUtf8 "reject-producer",
                occurredAt = at,
                causationId = Nothing,
                correlationId = Nothing,
                traceContext = Nothing,
                attributes = Nothing
              }
          enqueue = runFixture (runTransaction (enqueueProducerEventTx producer recorded 0 draft)) >>= either (fail . show) pure
      baselineBacklog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      inserted <- enqueue
      replayBroker <- Broker.newBroker
      _ <- publish (Broker.publishScripted replayBroker model (const (Broker.RejectWith rejection)) hooks "replay-publisher")
      beforeReplay <- readCase source
      _ <- runFixture (outboxMaintenancePass defaultMaintenanceOptions Nothing) >>= either (fail . show) pure
      gcAt <- getCurrentTime
      _ <- runFixture (garbageCollectSent 0 gcAt) >>= either (fail . show) pure
      replayed <- enqueue
      afterReplay <- readCase source
      finalBacklog <- runFixture countOutboxBacklog >>= either (fail . show) pure
      pure
        ( case (inserted, replayed, beforeReplay, afterReplay) of
            (ProducerInserted first, ProducerDuplicateIdentical second, [before], [after]) -> first == second && before == after && after.status == OutboxRejected && after.rejectedAt /= Nothing && finalBacklog == baselineBacklog
            _ -> False
        )
    let byId rows = Map.fromList [(row.event.messageId, row) | row <- rows]
        throwMap = byId throwRows
        missingMap = byId missingRows
        unknownMap = byId unknownRows
        rejectMap = byId rejectRows
        afterGcMap = byId afterGc
        failedWithError expected row = row.status == OutboxFailed && row.attemptCount == 1 && maybe False (Text.isInfixOf expected) row.lastError
        cells =
          [ ("throw-fails-all-claimed", throwSummary.retried == 2 && all (failedWithError "synthetic callback threw") throwRows),
            ("missing-outcome-fails-all-claimed", missingSummary.retried == 2 && all (failedWithError "publisher returned no outcome") missingRows),
            ("unknown-outcome-ignored", unknownSummary.published == 2 && all ((== OutboxSent) . (.status)) unknownRows),
            ("all-cases-claimed-own-rows", all ((== 2) . Map.size) [throwMap, missingMap, unknownMap, rejectMap]),
            ("rejection-terminal", rejectSummary.rejected == 1 && rejectSummary.published == 1 && case Map.lookup "reject1" rejectMap of Just row -> row.status == OutboxRejected && maybe False ((== "synthetic_rejection") . publishRejectionCode) row.rejection && row.rejectedAt /= Nothing; _ -> False),
            ("rejection-does-not-block-successor", maybe False ((== OutboxSent) . (.status)) (Map.lookup "reject2" rejectMap) && length brokerRows == 1),
            ("rejection-survives-maintenance-and-gc", Map.member "reject1" afterGcMap && not (Map.member "reject2" afterGcMap)),
            ("per-source-rejection-unblocks", perSourceRejection),
            ("stop-line-rejection-does-not-halt", stopLineRejection),
            ("producer-replay-keeps-rejection", producerReplay)
          ]
    recordCells context cells

perKeyOrderSerialized :: Scenario
perKeyOrderSerialized =
  terminalStateMatrix
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/per-key-order-serialized"),
      summary = "Checks serialized inline enqueues publish in key order despite transient failures.",
      knobs = map serializedKnob OutboxKnobs.outboxKnobs,
      run = runPerKeyOrderSerialized
    }

serializedKnob :: KnobSpec -> KnobSpec
serializedKnob spec = case renderKnobName spec.name of
  "outbox.ordering-policy" -> KnobSpec spec.name spec.summary spec.knobType spec.def (OneOf (VText "per-key-head-of-line" :| [VText "per-source-stream", VText "stop-the-line"])) [VText "per-source-stream", VText "stop-the-line"]
  "outbox.rows" -> withDefaultAndAllowed (VInt 5000) (IntRange 1 20000)
  "outbox.key-cardinality" -> withDefaultAndAllowed (VInt 20) (IntRange 1 200)
  "outbox.max-attempts" -> withDefault (VInt 4)
  "outbox.backoff-seconds" -> withDefault (VDouble 0.01)
  "outbox.backoff-max-seconds" -> withDefault (VDouble 0.08)
  "outbox.enqueue-path" -> withDefaultAndAllowed (VText "inline") (OneOf (VText "inline" :| []))
  "broker.fail-ratio" -> withDefault (VDouble 0.05)
  "broker.reject-ratio" -> withDefaultAndAllowed (VDouble 0) (DoubleRange 0 0)
  "broker.poison-ratio" -> withDefaultAndAllowed (VDouble 0) (DoubleRange 0 0)
  "broker.throw-ratio" -> withDefaultAndAllowed (VDouble 0) (DoubleRange 0 0)
  "broker.drop-outcome-ratio" -> withDefaultAndAllowed (VDouble 0) (DoubleRange 0 0)
  _ -> spec
  where
    withDefault value = KnobSpec spec.name spec.summary spec.knobType value spec.allowed spec.variants
    withDefaultAndAllowed value allowed = KnobSpec spec.name spec.summary spec.knobType value allowed spec.variants

runPerKeyOrderSerialized :: RunContext -> IO ScenarioReport
runPerKeyOrderSerialized context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    options <- either (fail . show) pure (OutboxKnobs.decodePublishOptions context.knobs Nothing)
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "serialized"
        rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
        keyCount = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
        entries = [(Text.pack (show i), Just ("key-" <> Text.pack (show (i `mod` keyCount))), i) | i <- [1 .. rowCount]]
        policy = options.orderingPolicy
        plan = Broker.FaultPlan (unSeed context.seed) (knobDouble context.knobs (knobName "broker.fail-ratio")) 0 0 0 0
        model = Broker.BrokerModel (fromIntegral (knobInt context.knobs (knobName "broker.invocation-micros"))) (fromIntegral (knobInt context.knobs (knobName "broker.per-record-micros"))) (fromIntegral (knobInt context.knobs (knobName "broker.partitions")))
        hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
        expected = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, sequenceNo)) | (messageId, Just key, sequenceNo) <- entries]
    enqueueInline fixture source entries
    broker <- Broker.newBroker
    let publishSource [] = pure []
        publishSource (row : rest) = do
          outcomes <- Broker.publishScripted broker model (Broker.decide plan) hooks "publisher" [row]
          case outcomes of
            [(_, PublishFailed _)] -> pure outcomes
            _ -> (outcomes <>) <$> publishSource rest
        callback = if policy == PerSourceStream then publishSource else Broker.publishCallback broker model plan hooks "publisher"
        drain = do
          backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
          if backlog == 0
            then pure ()
            else do
              _ <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
              threadDelay 10000
              drain
    drained <- timeout (300 * 1000000) drain
    rows <- runFixture (listOutbox source) >>= either (fail . show) pure
    records <- Broker.readBroker broker
    let observedIds = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
        observed = [pair | messageId <- observedIds, Just pair <- [Map.lookup messageId expected]]
        keyOrder = Oracle.perKeyOrder observed
        sourceOrder = Oracle.perKeyOrder [(source, sequenceNo) | (_, sequenceNo) <- observed]
        cells =
          [ ("drained-before-deadline", maybe False (const True) drained),
            ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && length observed == rowCount),
            ("no-duplicates", Oracle.boundedDuplicates Map.empty observedIds),
            ("per-key-order", keyOrder),
            ("per-source-order", policy /= PerSourceStream || sourceOrder)
          ]
    recordCells context cells

terminalStateMatrix :: Scenario
terminalStateMatrix =
  failureSkipsSuccessors
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/terminal-state-matrix"),
      summary = "Drains failed, rejected and poison integration events to their terminal states.",
      tier = TierStandard,
      knobs = map terminalKnob OutboxKnobs.outboxKnobs,
      run = runTerminalStateMatrix
    }

terminalKnob :: KnobSpec -> KnobSpec
terminalKnob spec = case renderKnobName spec.name of
  "outbox.max-attempts" -> withDefault (VInt 4)
  "outbox.backoff-seconds" -> withDefault (VDouble 0.01)
  "outbox.backoff-max-seconds" -> withDefault (VDouble 0.08)
  "outbox.publishing-timeout-seconds" -> withDefault (VDouble 2)
  "outbox.enqueue-path" -> withDefault (VText "inline")
  "outbox.rows" -> withAllowed (IntRange 1 20000)
  "broker.fail-ratio" -> withDefault (VDouble 0.1)
  "broker.reject-ratio" -> withDefault (VDouble 0.02)
  "broker.poison-ratio" -> withDefault (VDouble 0.01)
  "broker.throw-ratio" -> withAllowed (DoubleRange 0 0)
  "broker.drop-outcome-ratio" -> withAllowed (DoubleRange 0 0)
  _ -> spec
  where
    withDefault value = KnobSpec spec.name spec.summary spec.knobType value spec.allowed spec.variants
    withAllowed allowed = KnobSpec spec.name spec.summary spec.knobType spec.def allowed spec.variants

runTerminalStateMatrix :: RunContext -> IO ScenarioReport
runTerminalStateMatrix context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    options <- either (fail . show) pure (OutboxKnobs.decodePublishOptions context.knobs Nothing)
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "terminal"
        rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
        keyCount = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
        entries = [(Text.pack (show i), if keyCount == 0 then Nothing else Just ("key-" <> Text.pack (show (i `mod` keyCount))), i `div` max 1 keyCount) | i <- [1 .. rowCount]]
        plan = Broker.FaultPlan (unSeed context.seed) (knobDouble context.knobs (knobName "broker.fail-ratio")) (knobDouble context.knobs (knobName "broker.reject-ratio")) (knobDouble context.knobs (knobName "broker.poison-ratio")) (knobDouble context.knobs (knobName "broker.throw-ratio")) (knobDouble context.knobs (knobName "broker.drop-outcome-ratio"))
        model = Broker.BrokerModel (fromIntegral (knobInt context.knobs (knobName "broker.invocation-micros"))) (fromIntegral (knobInt context.knobs (knobName "broker.per-record-micros"))) (fromIntegral (knobInt context.knobs (knobName "broker.partitions")))
        hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
    enqueueInline fixture source entries
    broker <- Broker.newBroker
    let callback = Broker.publishCallback broker model plan hooks "publisher"
        drain totals = do
          backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
          if backlog == 0
            then pure totals
            else do
              summary <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
              threadDelay 10000
              drain (totals <> [summary])
    drained <- timeout (300 * 1000000) (drain [])
    rows <- runFixture (listOutbox source) >>= either (fail . show) pure
    records <- Broker.readBroker broker
    let brokerIds = Set.fromList [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
        brokerCounts = Map.fromListWith (+) [(value, 1 :: Int) | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
        statusMatches row =
          case Broker.decide plan (row {attemptCount = 1}) of
            Broker.AlwaysFail -> row.status == OutboxDead && row.attemptCount == options.maxAttempts
            Broker.RejectWith _ -> row.status == OutboxRejected
            _ -> row.status == OutboxSent
        wireMatches row =
          let published = Set.member (TextEncoding.encodeUtf8 row.event.messageId) brokerIds
           in case row.status of
                OutboxSent -> published
                OutboxRejected -> not published
                OutboxDead -> not published
                _ -> False
        rejectionMatches row =
          case row.status of
            OutboxRejected -> row.rejectedAt /= Nothing && maybe False ((== "synthetic_rejection") . publishRejectionCode) row.rejection
            _ -> row.rejectedAt == Nothing && row.rejection == Nothing
        deadMatches row =
          case row.status of
            OutboxDead -> row.attemptCount == options.maxAttempts && row.lastError == Just "synthetic permanent failure"
            _ -> True
        cells =
          [ ("drained-before-deadline", maybe False (const True) drained),
            ("every-row-terminal", length rows == rowCount && all statusMatches rows),
            ("broker-matches-terminal-status", all wireMatches rows),
            ("one-broker-record-per-sent-row", length records == length [() | row <- rows, row.status == OutboxSent] && all (== 1) (Map.elems brokerCounts)),
            ("rejection-metadata", all rejectionMatches rows),
            ("poison-attempt-ceiling", all deadMatches rows),
            ("published-count-matches-summaries", maybe False (\summaries -> sum (map (.published) summaries) == length [() | row <- rows, row.status == OutboxSent]) drained),
            ("rejected-count-matches-summaries", maybe False (\summaries -> sum (map (.rejected) summaries) == length [() | row <- rows, row.status == OutboxRejected]) drained),
            ("dead-count-matches-summaries", maybe False (\summaries -> sum (map (.dead) summaries) == length [() | row <- rows, row.status == OutboxDead]) drained)
          ]
    recordCells context cells

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

failureSkipsSuccessors :: Scenario
failureSkipsSuccessors =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/failure-skips-successors"),
      revision = 1,
      summary = "Checks that a failed row skips later rows of its key without consuming their attempts.",
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
      run = runFailureSkipsSuccessors
    }

runFailureSkipsSuccessors :: RunContext -> IO ScenarioReport
runFailureSkipsSuccessors context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "failure-skips"
        entries = [("a" <> suffix, Just "a", index) | (suffix, index) <- zip ["1", "2", "3", "4", "5"] [1 :: Int ..]] <> [("b" <> suffix, Just "b", index) | (suffix, index) <- zip ["1", "2", "3", "4", "5"] [1 :: Int ..]]
    enqueueInline fixture source entries
    Broker.withTableBroker (requirePostgres context).connectionString \broker -> do
      let model = Broker.BrokerModel 0 0 4
          hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
          choose row = if row.event.messageId == "a2" then Broker.FailOnce else Broker.Succeed
          callback = Broker.publishScripted broker model choose hooks "publisher"
          options = defaultPublishOptions {batchSize = 16, backoff = ConstantBackoff 60}
      summary <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
      rows <- runFixture (listOutbox source) >>= either (fail . show) pure
      records <- Broker.readBroker broker
      let byId = Map.fromList [(row.event.messageId, row) | row <- rows]
          isState messageId status attempts = case Map.lookup messageId byId of
            Just row -> row.status == status && row.attemptCount == attempts
            Nothing -> False
          cells =
            [ ("ten-rows", length rows == 10),
              ("first-sent", isState "a1" OutboxSent 1),
              ("pivot-failed", isState "a2" OutboxFailed 1),
              ("successors-skipped", all (\messageId -> isState messageId OutboxFailed 0) ["a3", "a4", "a5"]),
              ("independent-key-sent", all (\messageId -> isState messageId OutboxSent 1) ["b1", "b2", "b3", "b4", "b5"]),
              ("broker-six-records", length records == 6),
              ("pass-summary", summary.published == 6 && summary.retried == 4)
            ]
      let sourceA = sourceName context "per-source-a"
          sourceB = sourceName context "per-source-b"
          sourceStop = sourceName context "stop-line"
          policyEntries prefix key = [(prefix <> suffix, Just key, index) | (suffix, index) <- zip ["1", "2", "3", "4", "5"] [1 :: Int ..]]
          pivotCallback pivot = Broker.publishScripted broker model (\row -> if row.event.messageId == pivot then Broker.FailOnce else Broker.Succeed) hooks "publisher"
          lookupState mapping messageId status attempts = case Map.lookup messageId mapping of
            Just row -> row.status == status && row.attemptCount == attempts
            Nothing -> False
      enqueueInline fixture sourceA (policyEntries "ps-a" "a")
      enqueueInline fixture sourceB (policyEntries "ps-b" "b")
      perSourceSummary <- runFixture (publishClaimedOutbox (pivotCallback "ps-a2") options {orderingPolicy = PerSourceStream} Nothing) >>= either (fail . show) pure
      perSourceA <- runFixture (listOutbox sourceA) >>= either (fail . show) pure
      perSourceB <- runFixture (listOutbox sourceB) >>= either (fail . show) pure
      let perSourceRows = Map.fromList [(row.event.messageId, row) | row <- perSourceA <> perSourceB]
          perSourceHeld =
            lookupState perSourceRows "ps-a1" OutboxSent 1
              && lookupState perSourceRows "ps-a2" OutboxFailed 1
              && all (\messageId -> lookupState perSourceRows messageId OutboxFailed 0) ["ps-a3", "ps-a4", "ps-a5"]
              && all (\messageId -> lookupState perSourceRows messageId OutboxSent 1) ["ps-b1", "ps-b2", "ps-b3", "ps-b4", "ps-b5"]
              && perSourceSummary.published == 6
              && perSourceSummary.retried == 4
      enqueueInline fixture sourceStop (policyEntries "sl-a" "a" <> policyEntries "sl-b" "b")
      stopSummary <- runFixture (publishClaimedOutbox (pivotCallback "sl-a2") options {orderingPolicy = StopTheLine} Nothing) >>= either (fail . show) pure
      stopRows <- runFixture (listOutbox sourceStop) >>= either (fail . show) pure
      let stopById = Map.fromList [(row.event.messageId, row) | row <- stopRows]
          pivotId = (.outboxId) <$> Map.lookup "sl-a2" stopById
          stopHeld =
            lookupState stopById "sl-a1" OutboxSent 1
              && lookupState stopById "sl-a2" OutboxFailed 1
              && all (\messageId -> lookupState stopById messageId OutboxFailed 0) ["sl-a3", "sl-a4", "sl-a5", "sl-b1", "sl-b2", "sl-b3", "sl-b4", "sl-b5"]
              && stopSummary.published == 1
              && stopSummary.retried == 9
              && stopSummary.haltedOn == pivotId
      recordCells context (cells <> [("per-source-isolation", perSourceHeld), ("stop-the-line-halts-on-pivot", stopHeld)])
