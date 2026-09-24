module Kenshou.Suite.Keiro.Outbox.Broker
  ( BrokerRecord (..),
    Broker,
    BrokerModel (..),
    FaultPlan (..),
    FaultDecision (..),
    PublishHook (..),
    newBroker,
    readBroker,
    decide,
    publishCallback,
    publishScripted,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
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

newtype Broker = Broker (TVar (Seq BrokerRecord))

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
newBroker = Broker <$> newTVarIO Seq.empty

readBroker :: Broker -> IO [BrokerRecord]
readBroker (Broker rows) = toList <$> readTVarIO rows

-- The decision depends on stable message identity and the attempt, never on
-- callback interleaving or a process-local random generator.
decide :: FaultPlan -> OutboxRow -> FaultDecision
decide plan row
  | draw 0 < plan.throwRatio = ThrowInCall
  | draw 1 < plan.poisonRatio = AlwaysFail
  | draw 4 < plan.rejectRatio = RejectWith syntheticRejection
  | draw 2 < plan.failRatio && row.attemptCount <= 1 = FailOnce
  | draw 3 < plan.dropOutcomeRatio = DropOutcome
  | otherwise = Succeed
  where
    identity = Text.unpack row.event.messageId
    mix value char = (value `xor` fromIntegral (fromEnum char)) * 1099511628211
    base = foldl mix (plan.seed `xor` fromIntegral row.attemptCount) identity
    draw salt = fromIntegral (foldl mix base (show (salt :: Int)) `mod` 1000000) / 1000000
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
append (Broker logRows) model publisherName row = do
  threadDelay (max 0 model.perRecordMicros)
  now <- getCurrentTime
  let wire = outboxRowToKafkaRecord row
      partitionNumber = fromIntegral (foldl hashByte (14695981039346656037 :: Word64) (maybe [] (map fromIntegral . ByteString.unpack) wire.key) `mod` fromIntegral (max 1 model.partitions))
      hashByte :: Word64 -> Word64 -> Word64
      hashByte value byte = (value `xor` byte) * 1099511628211
  atomically $ modifyTVar' logRows \records ->
    let offsetNumber = fromIntegral (length [() | record <- toList records, record.topic == wire.topic, record.partition == partitionNumber])
     in records
          |> BrokerRecord
            { topic = wire.topic,
              partition = partitionNumber,
              offset = offsetNumber,
              key = wire.key,
              payload = wire.payload,
              headers = wire.headers,
              appendedAt = now,
              publisher = publisherName,
              attempt = row.attemptCount
            }

foldlM :: (Monad m) => (a -> b -> m a) -> a -> [b] -> m a
foldlM step initial = go initial
  where
    go state [] = pure state
    go state (item : rest) = step state item >>= \next -> go next rest
