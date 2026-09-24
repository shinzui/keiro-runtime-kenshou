module Kenshou.Suite.Keiro.Outbox.Broker
  ( BrokerRecord (..),
    Broker,
    BrokerModel (..),
    FaultPlan (..),
    FaultDecision (..),
    PublishHook (..),
    newBroker,
    newTableBroker,
    withTableBroker,
    readBroker,
    toInboundRecord,
    decide,
    publishCallback,
    publishScripted,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (bracket)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Inbox.Kafka qualified as InboxKafka
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxId, OutboxRow (..), PublishOutcome (..), PublishRejection, mkPublishRejection)
import Keiro.Outbox.Kafka (KafkaProducerRecord (..), outboxRowToKafkaRecord)

data BrokerRecord = BrokerRecord
  { topic :: !Text,
    partition :: !Int64,
    offset :: !Int64,
    key :: !(Maybe ByteString),
    payload :: !ByteString,
    headers :: ![(ByteString, ByteString)],
    appendedAt :: !UTCTime,
    publisher :: !Text,
    attempt :: !Int
  }
  deriving stock (Eq, Show)

data Broker = InProcessBroker !(TVar (Seq BrokerRecord)) | TableBroker !Pool

data BrokerModel = BrokerModel
  { invocationMicros :: !Int,
    perRecordMicros :: !Int,
    partitions :: !Int
  }
  deriving stock (Eq, Show)

data FaultPlan = FaultPlan
  { seed :: !Word64,
    failRatio :: !Double,
    rejectRatio :: !Double,
    poisonRatio :: !Double,
    throwRatio :: !Double,
    dropOutcomeRatio :: !Double
  }
  deriving stock (Eq, Show)

data FaultDecision = Succeed | FailOnce | RejectWith !PublishRejection | AlwaysFail | ThrowInCall | DropOutcome
  deriving stock (Eq, Show)

data PublishHook = PublishHook
  { beforeBrokerAppend :: !([OutboxRow] -> IO ()),
    afterBrokerAppend :: !([OutboxRow] -> IO ())
  }

newBroker :: IO Broker
newBroker = InProcessBroker <$> newTVarIO Seq.empty

newTableBroker :: Pool -> IO Broker
newTableBroker pool = do
  let schema =
        "CREATE SCHEMA IF NOT EXISTS kenshou_fx; "
          <> "CREATE TABLE IF NOT EXISTS kenshou_fx.broker_log ("
          <> "record_offset bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
          <> "topic text NOT NULL, partition bigint NOT NULL, record_key bytea, "
          <> "payload bytea NOT NULL, headers jsonb NOT NULL, "
          <> "appended_at timestamptz NOT NULL DEFAULT clock_timestamp(), "
          <> "publisher text NOT NULL, attempt integer NOT NULL)"
  Pool.use pool (Session.script schema) >>= either (fail . show) pure
  pure (TableBroker pool)

withTableBroker :: Text -> (Broker -> IO value) -> IO value
withTableBroker connectionString action =
  bracket
    (Pool.acquire (PoolConfig.settings [PoolConfig.size 2, PoolConfig.staticConnectionSettings (ConnectionSettings.connectionString connectionString)]))
    Pool.release
    (\pool -> newTableBroker pool >>= action)

readBroker :: Broker -> IO [BrokerRecord]
readBroker (InProcessBroker rows) = toList <$> readTVarIO rows
readBroker (TableBroker pool) = do
  rows <- Pool.use pool (Session.statement () readBrokerStatement) >>= either (fail . show) pure
  traverse decodeRow rows
  where
    decodeRow (topic, partition, offset, key, payload, headersValue, appendedAt, publisher, attempt) = do
      headers <- case Aeson.fromJSON headersValue of
        Aeson.Error message -> fail ("invalid synthetic broker headers: " <> message)
        Aeson.Success pairs -> pure [(TextEncoding.encodeUtf8 name, TextEncoding.encodeUtf8 value) | (name, value) <- (pairs :: [(Text, Text)])]
      pure BrokerRecord {topic, partition, offset, key, payload, headers, appendedAt, publisher, attempt = fromIntegral (attempt :: Int32)}

toInboundRecord :: UTCTime -> BrokerRecord -> InboxKafka.KafkaInboundRecord
toInboundRecord receivedAt record =
  InboxKafka.KafkaInboundRecord
    { InboxKafka.topic = record.topic,
      InboxKafka.partition = record.partition,
      InboxKafka.offset = record.offset,
      InboxKafka.key = TextEncoding.decodeUtf8 <$> record.key,
      InboxKafka.payload = record.payload,
      InboxKafka.headers = [(TextEncoding.decodeUtf8 name, TextEncoding.decodeUtf8 value) | (name, value) <- record.headers],
      InboxKafka.receivedAt = receivedAt
    }

-- The decision depends on stable message identity and the attempt, never on
-- callback interleaving or a process-local random generator.
decide :: FaultPlan -> OutboxRow -> FaultDecision
decide plan row
  | drawAttempt 0 < plan.throwRatio = ThrowInCall
  | drawStable 1 < plan.poisonRatio = AlwaysFail
  | drawStable 4 < plan.rejectRatio = RejectWith syntheticRejection
  | drawAttempt 2 < plan.failRatio && row.attemptCount <= 1 = FailOnce
  | drawAttempt 3 < plan.dropOutcomeRatio = DropOutcome
  | otherwise = Succeed
  where
    identity = Text.unpack row.event.messageId
    mix value char = (value `xor` fromIntegral (fromEnum char)) * 1099511628211
    stableBase = foldl mix plan.seed identity
    drawStable salt = fromIntegral (foldl mix stableBase (show (salt :: Int)) `mod` 1000000) / 1000000
    drawAttempt salt = fromIntegral (foldl mix stableBase (show (row.attemptCount, salt :: Int)) `mod` 1000000) / 1000000
    syntheticRejection = either (error . show) id (mkPublishRejection "synthetic_rejection" (Just "rejected by the synthetic broker"))

publishCallback :: (IOE :> es) => Broker -> BrokerModel -> FaultPlan -> PublishHook -> Text -> [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]
publishCallback broker model plan = publishScripted broker model (decide plan)

publishScripted :: (IOE :> es) => Broker -> BrokerModel -> (OutboxRow -> FaultDecision) -> PublishHook -> Text -> [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]
publishScripted broker model choose hooks publisherName rows = liftIO do
  hooks.beforeBrokerAppend rows
  threadDelay (max 0 model.invocationMicros)
  (_, outcomes) <- foldlM step (Map.empty, []) rows
  hooks.afterBrokerAppend rows
  pure outcomes
  where
    step (failedGroups, outcomes) row = do
      let group = maybe (Left row.outboxId) (\key -> Right (row.event.source, key)) row.event.key
          decision = choose row
      if Map.member group failedGroups
        then pure (failedGroups, outcomes <> [(row.outboxId, PublishFailed "earlier record of this group failed")])
        else case decision of
          ThrowInCall -> fail "synthetic broker callback failure"
          AlwaysFail -> pure (Map.insert group () failedGroups, outcomes <> [(row.outboxId, PublishFailed "synthetic permanent failure")])
          FailOnce -> pure (Map.insert group () failedGroups, outcomes <> [(row.outboxId, PublishFailed "synthetic transient failure")])
          DropOutcome -> pure (Map.insert group () failedGroups, outcomes)
          RejectWith rejection -> pure (failedGroups, outcomes <> [(row.outboxId, PublishRejected rejection)])
          Succeed -> do
            append broker model publisherName row
            pure (failedGroups, outcomes <> [(row.outboxId, PublishSucceeded)])

append :: Broker -> BrokerModel -> Text -> OutboxRow -> IO ()
append broker model publisherName row = do
  threadDelay (max 0 model.perRecordMicros)
  now <- getCurrentTime
  let wire = outboxRowToKafkaRecord row
      partitionNumber = fromIntegral (foldl hashByte (14695981039346656037 :: Word64) (maybe [] (map fromIntegral . ByteString.unpack) wire.key) `mod` fromIntegral (max 1 model.partitions))
      hashByte :: Word64 -> Word64 -> Word64
      hashByte value byte = (value `xor` byte) * 1099511628211
  let record =
        BrokerRecord
          { topic = wire.topic,
            partition = partitionNumber,
            offset = 0,
            key = wire.key,
            payload = wire.payload,
            headers = wire.headers,
            appendedAt = now,
            publisher = publisherName,
            attempt = row.attemptCount
          }
  case broker of
    InProcessBroker logRows ->
      atomically $ modifyTVar' logRows \records ->
        let offsetNumber = fromIntegral (length [() | previous <- toList records, previous.topic == wire.topic, previous.partition == partitionNumber])
         in records |> (record {offset = offsetNumber})
    TableBroker pool ->
      Pool.use pool (Session.statement record appendStatement) >>= either (fail . show) pure

appendStatement :: Statement.Statement BrokerRecord ()
appendStatement =
  Statement.preparable
    "INSERT INTO kenshou_fx.broker_log (topic, partition, record_key, payload, headers, publisher, attempt) VALUES ($1, $2, $3, $4, $5, $6, $7)"
    ( contramap (.topic) (Encoders.param (Encoders.nonNullable Encoders.text))
        <> contramap (.partition) (Encoders.param (Encoders.nonNullable Encoders.int8))
        <> contramap (.key) (Encoders.param (Encoders.nullable Encoders.bytea))
        <> contramap (.payload) (Encoders.param (Encoders.nonNullable Encoders.bytea))
        <> contramap (Aeson.toJSON . fmap (\(name, value) -> (TextEncoding.decodeUtf8 name, TextEncoding.decodeUtf8 value)) . (.headers)) (Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> contramap (.publisher) (Encoders.param (Encoders.nonNullable Encoders.text))
        <> contramap (fromIntegral @Int @Int32 . (.attempt)) (Encoders.param (Encoders.nonNullable Encoders.int4))
    )
    Decoders.noResult

readBrokerStatement :: Statement.Statement () [(Text, Int64, Int64, Maybe ByteString, ByteString, Value, UTCTime, Text, Int32)]
readBrokerStatement =
  Statement.preparable
    "SELECT topic, partition, record_offset, record_key, payload, headers, appended_at, publisher, attempt FROM kenshou_fx.broker_log ORDER BY record_offset"
    Encoders.noParams
    (Decoders.rowList ((,,,,,,,,) <$> text <*> int8 <*> int8 <*> key <*> bytes <*> jsonb <*> timestamp <*> text <*> int4))
  where
    text = Decoders.column (Decoders.nonNullable Decoders.text)
    int8 = Decoders.column (Decoders.nonNullable Decoders.int8)
    int4 = Decoders.column (Decoders.nonNullable Decoders.int4)
    key = Decoders.column (Decoders.nullable Decoders.bytea)
    bytes = Decoders.column (Decoders.nonNullable Decoders.bytea)
    jsonb = Decoders.column (Decoders.nonNullable Decoders.jsonb)
    timestamp = Decoders.column (Decoders.nonNullable Decoders.timestamptz)

foldlM :: (Monad m) => (a -> b -> m a) -> a -> [b] -> m a
foldlM step initial = go initial
  where
    go state [] = pure state
    go state (item : rest) = step state item >>= \next -> go next rest
