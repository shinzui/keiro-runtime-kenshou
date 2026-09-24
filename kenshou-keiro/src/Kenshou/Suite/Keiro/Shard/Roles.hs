module Kenshou.Suite.Keiro.Shard.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race, wait, withAsync)
import Control.Exception (try)
import Control.Monad (forM_, void, when)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Subscription.Shard (ShardCountMismatch, ShardLease (..), WorkerId (..), ensureShards)
import Keiro.Subscription.Shard.Worker (ShardAck (..), ShardDelivery (..), ShardedWorkerOptions (..), defaultShardedWorkerOptions, mkShardedWorkerOptions, runShardedSubscriptionGroupAck)
import Kenshou.Core.Knob (resolvedKnobsMap)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardOptionsFrom)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..), withEffectSink)
import Kenshou.Suite.Keiro.Workflow.Fixture (DurableStore, durableKirokuStore, ensureDurableTables, fixtureCategory, runDurable, withDurableStore)
import Kiroku.Store (appendToStream, defaultConnectionSettings, runStoreIO, runTransaction)
import Kiroku.Store.Subscription.Types (SubscriptionName (..), SubscriptionTarget (..))
import Kiroku.Store.Types (CategoryName (..), EventData (..), EventId (..), EventType (..), ExpectedVersion (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..))

roles :: [WorkerRole]
roles =
  [ WorkerRole roleName "Validates shard count or runs the acknowledgement-aware sharded delivery loop." shardWorker,
    WorkerRole appenderName "Appends deterministic account-category events from a separate process." shardAppender
  ]
  where
    roleName = either (error . Text.unpack) id (mkRoleName "keiro/shard-worker")
    appenderName = either (error . Text.unpack) id (mkRoleName "keiro/shard-appender")

shardAppender :: RoleContext -> IO ()
shardAppender context = case context.init.postgres of
  Nothing -> context.send (WrkError "shard appender requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "shard appender args" (\value -> (,,,,) <$> value .: "eventCount" <*> value .: "streamCount" <*> value .: "idPrefix" <*> value .: "streamPrefix" <*> value .:? "pauseMicros")) context.init.args of
    Nothing -> context.send (WrkError "invalid shard appender arguments")
    Just (eventCount, streamCount, idPrefix, streamPrefix, pauseMicros)
      | eventCount < 0 || streamCount <= (0 :: Int) -> context.send (WrkError "invalid shard appender counts")
      | otherwise -> do
          context.send WrkReady
          context.receive >>= \case
            Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture -> do
              forM_ [0 .. eventCount - 1] \index -> do
                let identity = UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 (idPrefix <> Text.pack (show index))))
                    event = EventData (Just (EventId identity)) (EventType "kenshou.shard.probe") (object []) Nothing Nothing Nothing
                    stream = StreamName (streamPrefix <> Text.pack (show (index `mod` streamCount)))
                outcome <- runDurable fixture (appendToStream stream AnyVersion [event])
                _ <- either (fail . show) pure outcome
                maybe (pure ()) threadDelay pauseMicros
                when (index `mod` 1000 == 999) do
                  now <- getCurrentTime
                  context.send (WrkProgress (fromIntegral (index + 1)) now)
              context.send (WrkDone Nothing)
            _ -> context.send (WrkDone (Just "not started"))

shardWorker :: RoleContext -> IO ()
shardWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "shard worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "shard worker args" (\value -> (,,,) <$> value .: "subscription" <*> value .: "shardCount" <*> value .:? "delivery" <*> value .:? "handlerDelayMicros")) context.init.args of
    Nothing -> context.send (WrkError "invalid shard worker arguments")
    Just (subscription, count, delivery, handlerDelayMicros) -> case optionsResult count of
      Left err -> context.send (WrkError (Text.pack (show err)))
      Right options -> do
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture ->
            if delivery == Just True
              then do
                ensureDurableTables fixture
                withEffectSink context [] \sink ->
                  withAsync (runShardedSubscriptionGroupAck (durableKirokuStore fixture) (SubscriptionName subscription) options (recordDelivery fixture sink context.init.instanceName context.send handlerDelayMicros)) \worker -> do
                    outcome <- race context.receive (wait worker)
                    case outcome of
                      Left (Just (CtlStop _)) -> context.send (WrkDone Nothing)
                      Left _ -> context.send (WrkDone (Just "control channel closed"))
                      Right () -> context.send (WrkError "shard delivery loop exited")
              else do
                let lease = ShardLease (SubscriptionName subscription) (WorkerId UUID.nil) options.shardCount options.leaseTtl
                outcome <- try @ShardCountMismatch (runStoreIO (durableKirokuStore fixture) (ensureShards lease))
                case outcome of
                  Left err -> fail (show err)
                  Right (Left err) -> fail (show err)
                  Right (Right ()) -> context.send (WrkDone Nothing)
          _ -> void (context.send (WrkDone (Just "not started")))
  where
    target = Category (CategoryName fixtureCategory)
    optionsResult count =
      if Map.member (shardKnobName "shard.shard-count") (resolvedKnobsMap context.init.knobs)
        then shardOptionsFrom target context.init.knobs
        else mkShardedWorkerOptions (defaultShardedWorkerOptions target count) {leaseTtl = 10, renewInterval = 2}

recordDelivery :: DurableStore -> EffectSink -> Text -> (WorkerMessage -> IO ()) -> Maybe Int -> ShardDelivery -> IO ShardAck
recordDelivery fixture sink workerName send delay delivery = do
  let event = delivery.event
      EventId identifier = event.eventId
      StreamId stream = event.originalStreamId
      GlobalPosition position = event.globalPosition
      key = UUID.toText identifier
      payload = object ["eventId" .= key, "streamId" .= stream, "globalPosition" .= position, "bucket" .= delivery.bucket, "worker" .= workerName]
  sink.recordEffect (EffectFact "shard-delivery" key workerName (object ["bucket" .= delivery.bucket, "attempt" .= delivery.attempt]))
  send (WrkCustom ("delivery-start-" <> Text.pack (show delivery.bucket)) (object ["eventId" .= key]))
  maybe (pure ()) threadDelay delay
  result <- runDurable fixture (runTransaction (Tx.statement payload insertSinkStatement))
  either (fail . show) (const (pure ShardAckOk)) result

insertSinkStatement :: Statement.Statement Value ()
insertSinkStatement =
  Statement.preparable
    "INSERT INTO kenshou_durable.shard_sink (event_id, stream_id, global_position, bucket, first_worker) SELECT (x->>'eventId')::uuid, (x->>'streamId')::bigint, (x->>'globalPosition')::bigint, (x->>'bucket')::integer, x->>'worker' FROM (SELECT $1::jsonb AS x) input ON CONFLICT (event_id) DO UPDATE SET deliveries = kenshou_durable.shard_sink.deliveries + 1"
    (Encoders.param (Encoders.nonNullable Encoders.jsonb))
    Decoders.noResult
