module Kenshou.Suite.Keiro.Shard.Variants (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (sort)
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
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardKnobs)
import Kenshou.Suite.Keiro.Shard.Oracle (recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (ensureDurableTables, runDurable, withDurableStore)
import Kiroku.Store (appendToStream, defaultConnectionSettings, runTransaction)
import Kiroku.Store.Types (EventData (..), EventId (..), EventType (..), ExpectedVersion (..), StreamName (..))

scenarios :: [Scenario]
scenarios = [ackCoupledHandlerVariants]

ackCoupledHandlerVariants :: Scenario
ackCoupledHandlerVariants =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/correctness/ack-coupled-handler-variants"),
      revision = 1,
      summary = "Exercises acknowledgement, bounded retry and dead-letter dispositions in one sharded subscription.",
      tier = TierStandard,
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
      run = runVariants
    }

runVariants :: RunContext -> IO ScenarioReport
runVariants context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    ensureDurableTables fixture
    let kinds = ["probe", "retry", "dead", "exhaust", "probe"] :: [Text]
        eventId :: Int -> EventId
        eventId index = EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou:shard:variants:" <> Text.pack (show index)))))
        event :: Int -> Text -> EventData
        event index kind = EventData (Just (eventId index)) (EventType ("kenshou.shard." <> kind)) (object ["kind" .= kind]) Nothing Nothing Nothing
        sinkRows = runDurable fixture (runTransaction (Tx.statement () sinkRowsStatement))
        deadRows = runDurable fixture (runTransaction (Tx.statement () deadRowsStatement))
        ready = do
          sink <- sinkRows
          dead <- deadRows
          pure (case (sink, dead) of (Right delivered, Right abandoned) -> length delivered == 3 && length abandoned == 2; _ -> False)
        plainReady = do
          sink <- sinkRows
          pure (case sink of Right delivered -> length delivered == 5; Left _ -> False)
        retryMax = fromIntegral (knobInt context.knobs (shardKnobName "shard.retry-max-attempts")) :: Int
        key :: Int -> Text
        key index = let EventId value = eventId index in UUID.toText value
    seeded <- runDurable fixture (appendToStream (StreamName "account-variants") AnyVersion (zipWith event [0 ..] kinds))
    sealLedger check.ledger
    completed <- withSupervisor check \supervisor -> do
      spec <- roleProcess check "keiro/shard-worker" 0 (object ["subscription" .= ("kenshouShardVariants" :: Text), "shardCount" .= (4 :: Int), "delivery" .= True])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      done <- waitUntil ready 160
      _ <- stopGracefully supervisor worker 5000
      pure done
    ackSink <- sinkRows
    plainSeeded <- runDurable fixture (appendToStream (StreamName "account-plain") AnyVersion [event 5 "throw", event 6 "probe"])
    plainCompleted <- withSupervisor check \supervisor -> do
      spec <- roleProcess check "keiro/shard-worker" 1 (object ["subscription" .= ("kenshouShardPlain" :: Text), "shardCount" .= (4 :: Int), "delivery" .= True, "handlerMode" .= ("plain" :: Text)])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      done <- waitUntil plainReady 160
      _ <- stopGracefully supervisor worker 5000
      pure done
    sink <- sinkRows
    dead <- deadRows
    ledgers <- discoverLedgers check.ledgerDirectory
    attempts <- foldFacts ledgers Map.empty \observed fact ->
      pure if fact.kind == Effect then maybe observed (\attempt -> Map.insertWith (<>) fact.key [attempt] observed) (factAttempt fact) else observed
    let ackDeliveredIds = case ackSink of Right rows -> Set.fromList [identifier | (identifier, _) <- rows]; Left _ -> Set.empty
        deliveredIds = case sink of Right rows -> Set.fromList [identifier | (identifier, _) <- rows]; Left _ -> Set.empty
        deadIds = case dead of Right rows -> Set.fromList [identifier | (identifier, _) <- rows]; Left _ -> Set.empty
        observed index = sort (Map.findWithDefault [] (key index) attempts)
        deadCounts = case dead of Right rows -> Map.fromList rows; Left _ -> Map.empty
    recordShardCells
      check
      [ ("seeded-ordered-workload", either (const False) (const True) seeded),
        ("ack-and-later-events-delivered", completed && ackDeliveredIds == Set.fromList [key 0, key 1, key 4]),
        ("retry-attempt-sequence", observed 1 == [0, 1, 2]),
        ("explicit-dead-letter-once", deadIds == Set.fromList [key 2, key 3] && Map.lookup (key 2) deadCounts == Just 1 && observed 2 == [0]),
        ("retry-exhaustion-dead-letters", Map.lookup (key 3) deadCounts == Just retryMax && observed 3 == [0 .. retryMax - 1]),
        ("later-event-not-lost", observed 4 == [0] && Set.member (key 4) deliveredIds),
        ("plain-throw-retried", either (const False) (const True) plainSeeded && plainCompleted && observed 5 == [0, 1]),
        ("plain-later-event-not-lost", deliveredIds == Set.fromList [key 0, key 1, key 4, key 5, key 6] && observed 6 == [0])
      ]

factAttempt :: Fact -> Maybe Int
factAttempt fact = do
  Object attributes <- KeyMap.lookup "attributes" fact.attrs
  value <- KeyMap.lookup "attempt" attributes
  case fromJSON value of Success number -> Just number; Error _ -> Nothing

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)

sinkRowsStatement :: Statement.Statement () [(Text, Int)]
sinkRowsStatement =
  Statement.preparable
    "SELECT event_id::text, deliveries FROM kenshou_durable.shard_sink"
    Encoders.noParams
    (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4))))

deadRowsStatement :: Statement.Statement () [(Text, Int)]
deadRowsStatement =
  Statement.preparable
    "SELECT event_id::text, attempt_count FROM kiroku.dead_letters WHERE subscription_name = 'kenshouShardVariants'"
    Encoders.noParams
    (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4))))
