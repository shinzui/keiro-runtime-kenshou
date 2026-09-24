module Kenshou.Suite.Keiro.Outbox.ProducerIdentity (scenarios) where

import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time (UTCTime (..), addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (messageId), TraceContext (..))
import Keiro.Outbox (ConflictField (..), IntegrationEventDraft (..), IntegrationProducer (..), OutboxId (..), OutboxRow (..), ProducerEnqueueOutcome (..), ProducerEventKey (..), ProducerIdentity (..), deriveProducerIdentity, enqueueProducerEventTx, listOutbox, mkIntegrationProducer)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [producerIdentity]

producerIdentity :: Scenario
producerIdentity =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/producer-identity"),
      revision = 1,
      summary = "Checks replay-safe producer identity and one-field conflict classification.",
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
      run = runProducerIdentity
    }

runProducerIdentity :: RunContext -> IO ScenarioReport
runProducerIdentity context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "producer-id"
        producer :: IntegrationProducer ()
        producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "probe" source "kenshou" (\_ _ -> Nothing)))
        recorded =
          RecordedEvent
            { eventId = EventId UUID.nil,
              eventType = EventType "Probe",
              streamVersion = StreamVersion 1,
              globalPosition = GlobalPosition 1,
              originalStreamId = StreamId 1,
              originalVersion = StreamVersion 1,
              payload = object [],
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing,
              createdAt = now
            }
        draft =
          IntegrationEventDraft
            { destination = "kenshou.outbox.v1",
              key = Just "account-1",
              eventType = "Probe",
              schemaVersion = 1,
              contentType = ApplicationJson,
              schemaReference = Nothing,
              sourceEventId = Nothing,
              sourceGlobalPosition = Nothing,
              payloadBytes = ByteString.pack [1, 2, 3],
              occurredAt = now,
              causationId = Nothing,
              correlationId = Nothing,
              traceContext = Nothing,
              attributes = Just (object ["a" .= (1 :: Int), "b" .= (2 :: Int)])
            }
        enqueue producerToUse draftToUse = runFixture (runTransaction (enqueueProducerEventTx producerToUse recorded 0 draftToUse)) >>= either (fail . show) pure
        expectedIdentity = deriveProducerIdentity producer (ProducerEventKey recorded.eventId 0)
        changedProducer = producer {messageIdPrefix = "other"}
        changedIdentity = deriveProducerIdentity changedProducer (ProducerEventKey recorded.eventId 0)
        frozenProducer = IntegrationProducer "ordering-integration-producer" "ordering" "msg" (\_ _ -> Nothing)
        frozenIdentity = deriveProducerIdentity frozenProducer (ProducerEventKey (EventId (read "00000000-0000-0000-0000-000000000001")) 0)
    first <- enqueue producer draft
    before <- runFixture (listOutbox source) >>= either (fail . show) pure
    identical <- enqueue producer draft
    afterDuplicate <- runFixture (listOutbox source) >>= either (fail . show) pure
    conflictOutcomes <- traverse (\(field, changed) -> fmap (\result -> (field, result)) (enqueue producer changed)) (mutations now draft)
    identityConflict <- enqueue changedProducer draft
    afterConflicts <- runFixture (listOutbox source) >>= either (fail . show) pure
    let UTCTime day daytime = now
        micros = floor (toRational daytime * 1000000) :: Integer
        rounded = UTCTime day (fromRational (fromInteger micros / 1000000))
    submicrosecond <- enqueue producer (draft {occurredAt = addUTCTime 0.0000001 rounded})
    reordered <- enqueue producer (draft {attributes = Just (object ["b" .= (2 :: Int), "a" .= (1 :: Int)])})
    finalRows <- runFixture (listOutbox source) >>= either (fail . show) pure
    let identicalOutcome = \case ProducerDuplicateIdentical identity -> identity == expectedIdentity; _ -> False
        conflict field = \case ProducerIdentityConflict identity (actual :| []) -> identity == expectedIdentity && actual == field; _ -> False
        sameRow left right = case (left, right) of
          ([a], [b]) -> a.outboxId == b.outboxId && a.event == b.event && a.createdAt == b.createdAt && a.updatedAt == b.updatedAt && a.status == b.status && a.attemptCount == b.attemptCount
          _ -> False
        cells =
          [ ("deterministic-identity", case (first, before) of (ProducerInserted identity, [row]) -> identity == expectedIdentity && row.outboxId == identity.outboxId && row.event.messageId == identity.messageId; _ -> False),
            ("adr-42-frozen-vector", frozenIdentity.outboxId == OutboxId (read "61dd62b4-bbfe-81ce-9634-6ce6afd48517") && frozenIdentity.messageId == "msg_v1_61dd62b4bbfef1ce56346ce6afd485172774bc060102e5cf455e39bd0edfa84b"),
            ("identical-replay-no-mutation", identicalOutcome identical && sameRow before afterDuplicate),
            ("one-field-conflicts", all (\(field, result) -> conflict field result) conflictOutcomes),
            ("namespace-change-is-identity-conflict", case identityConflict of ProducerIdentityConflict identity (IdentityField :| []) -> identity == changedIdentity && identity.outboxId == expectedIdentity.outboxId; _ -> False),
            ("conflicts-do-not-mutate", sameRow before afterConflicts),
            ("microsecond-equivalence", identicalOutcome submicrosecond),
            ("attribute-key-order-equivalence", identicalOutcome reordered),
            ("equivalent-replays-do-not-mutate", sameRow before finalRows)
          ]
    recordCells context cells

mutations :: UTCTime -> IntegrationEventDraft -> [(ConflictField, IntegrationEventDraft)]
mutations now draft =
  [ (RoutingField, draft {destination = "kenshou.other.v1"}),
    (SchemaField, draft {schemaVersion = 2}),
    (PayloadField, draft {payloadBytes = ByteString.pack [3, 2, 1]}),
    (OccurredAtField, draft {occurredAt = addUTCTime 1 now}),
    (CausalField, draft {causationId = Just (EventId (read "00000000-0000-0000-0000-000000000001"))}),
    (TraceField, draft {traceContext = Just (TraceContext "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" Nothing)}),
    (AttributesField, draft {attributes = Just (object ["changed" .= True])}),
    (ProvenanceField, draft {sourceEventId = Just (EventId (read "00000000-0000-0000-0000-000000000002"))})
  ]
