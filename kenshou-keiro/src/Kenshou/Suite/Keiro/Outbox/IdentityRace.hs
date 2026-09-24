module Kenshou.Suite.Keiro.Outbox.IdentityRace (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, wait, withAsync)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), IntegrationEventDraft (..), IntegrationProducer (..), OutboxPublishOptions (..), OutboxRow (..), ProducerEnqueueOutcome (..), ProducerEventKey (..), ProducerIdentity (..), countOutboxBacklog, defaultPublishOptions, deriveProducerIdentity, enqueueProducerEventTx, garbageCollectSent, listOutbox, mkIntegrationProducer, publishClaimedOutbox)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [producerIdentityRaceWithGc]

producerIdentityRaceWithGc :: Scenario
producerIdentityRaceWithGc =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/producer-identity-race-with-gc"),
      revision = 1,
      summary = "Races replay-safe producer enqueues with publication and zero-retention GC.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "outbox.enqueuers") "Concurrent producer enqueuers" KnobInt (VInt 4) (IntRange 2 16) [],
          KnobSpec (knobName "outbox.source-events") "Distinct source events" KnobInt (VInt 128) (IntRange 32 2000) []
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
      run = runProducerIdentityRaceWithGc
    }

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName

runProducerIdentityRaceWithGc :: RunContext -> IO ScenarioReport
runProducerIdentityRaceWithGc context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker -> do
      now <- getCurrentTime
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "identity-gc"
          enqueuers = fromIntegral (knobInt context.knobs (knobName "outbox.enqueuers"))
          eventCount = fromIntegral (knobInt context.knobs (knobName "outbox.source-events"))
          producer :: IntegrationProducer ()
          producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "gc-race" source "kenshou" (\_ _ -> Nothing)))
          eventIds = [EventId (UUID.fromWords 0 0 0 (fromIntegral index)) | index <- [1 .. eventCount :: Int]]
          recorded index eventId =
            RecordedEvent
              { eventId,
                eventType = EventType "GcRace",
                streamVersion = StreamVersion (fromIntegral index),
                globalPosition = GlobalPosition (fromIntegral index),
                originalStreamId = StreamId 1,
                originalVersion = StreamVersion (fromIntegral index),
                payload = object [],
                metadata = Nothing,
                causationId = Nothing,
                correlationId = Nothing,
                createdAt = now
              }
          draft index =
            IntegrationEventDraft
              { destination = "kenshou.outbox.v1",
                key = Just ("key-" <> Text.pack (show index)),
                eventType = "GcRace",
                schemaVersion = 1,
                contentType = ApplicationJson,
                schemaReference = Nothing,
                sourceEventId = Nothing,
                sourceGlobalPosition = Nothing,
                payloadBytes = TextEncoding.encodeUtf8 (Text.pack (show index)),
                occurredAt = now,
                causationId = Nothing,
                correlationId = Nothing,
                traceContext = Nothing,
                attributes = Nothing
              }
          enqueue index eventId = runFixture (runTransaction (enqueueProducerEventTx producer (recorded index eventId) 0 (draft index))) >>= either (fail . show) pure
          callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) (Broker.PublishHook (const (pure ())) (const (pure ()))) "identity-gc-publisher"
          publish = runFixture (publishClaimedOutbox callback (defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}) Nothing) >>= either (fail . show) pure
          collect = getCurrentTime >>= \at -> runFixture (garbageCollectSent 0 at) >>= either (fail . show) pure
          readRows = runFixture (listOutbox source) >>= either (fail . show) pure
      -- Seed retained rows so the first replayers encounter both a live row
      -- and a row that publication and GC may remove before conflict lookup.
      seeded <- traverse (uncurry enqueue) (zip [1 :: Int ..] eventIds)
      done <- newIORef False
      gcDeleted <- newIORef (0 :: Int)
      uniqueSnapshots <- newIORef True
      let background = do
            _ <- publish
            deleted <- collect
            atomicModifyIORef' gcDeleted (\count -> (count + deleted, ()))
            rows <- readRows
            let outboxIds = map (.outboxId) rows
                messageIds = map ((.messageId) . (.event)) rows
                unique = length rows == Set.size (Set.fromList outboxIds) && length rows == Set.size (Set.fromList messageIds)
            unless unique (writeIORef uniqueSnapshots False)
            finished <- readIORef done
            unless finished (threadDelay 1000 >> background)
          replay _ = traverse (uncurry enqueue) (zip [1 :: Int ..] eventIds)
      replayed <- withAsync background \worker -> do
        result <- timeout 60000000 (mapConcurrently replay [1 .. enqueuers :: Int])
        writeIORef done True
        wait worker
        pure result
      let drain = do
            backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
            if backlog == 0 then pure () else publish >> threadDelay 1000 >> drain
      drained <- timeout 30000000 drain
      rows <- readRows
      records <- Broker.readBroker broker
      deleted <- readIORef gcDeleted
      snapshotsUnique <- readIORef uniqueSnapshots
      let outcomes = seeded <> maybe [] concat replayed
          validOutcome = \case ProducerInserted {} -> True; ProducerDuplicateIdentical {} -> True; _ -> False
          expectedIds = Set.fromList [identity.messageId | eventId <- eventIds, let identity = deriveProducerIdentity producer (ProducerEventKey eventId 0)]
          recordIds = [TextEncoding.decodeUtf8 value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
          actualIds = Set.fromList recordIds
          rowIds = [row.event.messageId | row <- rows]
          republications = length records - Set.size actualIds
          insertedCount = length [() | ProducerInserted {} <- outcomes]
          cells =
            [ ("bounded-termination", maybe False (const True) replayed && maybe False (const True) drained),
              ("valid-enqueue-outcomes", length outcomes == eventCount * (enqueuers + 1) && all validOutcome outcomes),
              ("gc-race-realised", deleted > 0 && republications > 0 && insertedCount > eventCount),
              ("one-retained-row-per-identity", snapshotsUnique && length rowIds == Set.size (Set.fromList rowIds)),
              ("stable-wire-identity", not (null records) && actualIds == expectedIds && all (`Set.member` expectedIds) rowIds)
            ]
          evidence = Map.fromList [("sourceEvents", fromIntegral eventCount), ("enqueuers", fromIntegral enqueuers), ("gcDeleted", fromIntegral deleted), ("brokerRecords", fromIntegral (length records)), ("republications", fromIntegral republications), ("inserted", fromIntegral insertedCount)]
      recordMessagingCells context evidence (object ["retainedRows" .= length rows]) cells
