module Kenshou.Suite.Keiro.Shard.Correctness (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Subscription.Shard (ownershipSnapshotFor)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardKnobs)
import Kenshou.Suite.Keiro.Shard.Oracle (recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (ensureDurableTables, runDurable, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (EventId (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [singleWorkerDrainsAllBuckets]

singleWorkerDrainsAllBuckets :: Scenario
singleWorkerDrainsAllBuckets =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/correctness/single-worker-drains-all-buckets"),
      revision = 1,
      summary = "Runs one real sharded subscription worker and verifies complete bucket ownership and exact delivery to the durable sink.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = shardKnobs,
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
      run = runSingleWorker
    }

runSingleWorker :: RunContext -> IO ScenarioReport
runSingleWorker context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    ensureDurableTables fixture
    let eventCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.events")) :: Int
        streams = fromIntegral (knobInt context.knobs (shardKnobName "shard.streams")) :: Int
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        name = SubscriptionName "kenshouShardSingleWorker"
        eventId n = EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou:shard:single:" <> Text.pack (show n)))))
        sinkRows = runDurable fixture (runTransaction (Tx.statement () sinkRowsStatement))
        ownership = runDurable fixture (ownershipSnapshotFor name)
        done = do
          rows <- sinkRows
          owners <- ownership
          pure
            ( case (rows, owners) of
                (Right delivered, Right buckets) -> length delivered == eventCount && length buckets == bucketCount && all (\(_, owner, _) -> owner /= Nothing) buckets
                _ -> False
            )
    sealLedger check.ledger
    (appended, completed, ownedBeforeStop) <- withSupervisor check \supervisor -> do
      appenderSpec <- roleProcess check "keiro/shard-appender" 0 (object ["eventCount" .= eventCount, "streamCount" .= streams, "idPrefix" .= ("kenshou:shard:single:" :: Text), "streamPrefix" .= ("account-shard-" :: Text)])
      appender <- spawn supervisor appenderSpec
      awaitReady appender 10000
      sendCommand appender CtlStart
      appended <- timeout 120000000 $ atomically do
        state <- progress appender
        case state.lastMessage of
          Just (WrkDone Nothing) -> pure True
          Just (WrkError _) -> pure False
          _ -> retry
      spec <- roleProcess check "keiro/shard-worker" 0 (object ["subscription" .= ("kenshouShardSingleWorker" :: Text), "shardCount" .= bucketCount, "delivery" .= True])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      result <- waitUntil done 240
      snapshot <- ownership
      _ <- stopGracefully supervisor worker 5000
      pure (appended == Just True, result, snapshot)
    delivered <- sinkRows
    ownedAfterStop <- ownership
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    let expectedIds = Set.fromList [UUID.toText identifier | n <- [0 .. eventCount - 1], let EventId identifier = eventId n]
        actualIds = case delivered of Right rows -> Set.fromList [identifier | (identifier, _, _, _, _) <- rows]; Left _ -> Set.empty
        ordered = case delivered of
          Left _ -> False
          Right rows -> snd (foldl checkOrder (Map.empty, True) (sortOn (\(_, _, _, _, sequenceNumber) -> sequenceNumber) rows))
        checkOrder (positions, valid) (_, _, stream, position, _) =
          (Map.insert stream position positions, valid && maybe True (< position) (Map.lookup stream positions))
        cells =
          [ ("all-buckets-owned", completed && case ownedBeforeStop of Right buckets -> length buckets == bucketCount && all (\(_, owner, _) -> owner /= Nothing) buckets; Left _ -> False),
            ("graceful-release", case ownedAfterStop of Right buckets -> length buckets == bucketCount && all (\(_, owner, _) -> owner == Nothing) buckets; Left _ -> False),
            ("all-events-in-sink", appended && Set.size expectedIds == eventCount && actualIds == expectedIds),
            ("first-delivery-once", case delivered of Right rows -> all (\(_, count, _, _, _) -> count == 1) rows && length rows == eventCount; Left _ -> False),
            ("first-deliveries-in-stream-order", ordered),
            ("one-effect-per-event", Map.keysSet effects == expectedIds && all (== 1) (Map.elems effects))
          ]
    recordShardCells check cells

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)

sinkRowsStatement :: Statement.Statement () [(Text, Int, Int64, Int64, Int64)]
sinkRowsStatement =
  Statement.preparable
    "SELECT event_id::text, deliveries, stream_id, global_position, first_delivery_seq FROM kenshou_durable.shard_sink ORDER BY event_id"
    Encoders.noParams
    (Decoders.rowList ((,,,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
