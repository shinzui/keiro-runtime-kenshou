module Kenshou.Suite.Kafka.Model.Simulator
  ( Decision (..),
    Schedule (..),
    Trace (..),
    Event (..),
    runSchedule,
    propNoCommitPastUnacked,
    propFirstSuccessInOrder,
    propTerminates,
  )
where

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), PartitionOffset (..), Timestamp (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer (..))
import Kafka.Types (BatchSize (..), KafkaError, PartitionId (..), TopicName (..))
import Shibuya.Adapter.Kafka (defaultConfig)
import Shibuya.Adapter.Kafka.Config qualified as Config
import Shibuya.Adapter.Kafka.Internal (dropStaleRecords, ingestedStream, kafkaSource, mkIngested, newKafkaAdapterState)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

data Decision = DecideOk | DecideRetry deriving stock (Eq, Ord, Show)

data Schedule = Schedule
  { inboxDepth :: Int,
    batchSize :: Int,
    maxOffsets :: Int,
    script :: Map Int [Decision]
  }
  deriving stock (Eq, Show)

data Event = Decided Int Decision | Stored Int | Sought Int deriving stock (Eq, Show)

data Trace = Trace
  { events :: [Event],
    firstSuccesses :: [Int],
    finalStored :: Int,
    logEnd :: Int,
    terminated :: Bool,
    steps :: Int
  }
  deriving stock (Eq, Show)

data SimState = SimState
  { position :: Int,
    stored :: Int,
    records :: [ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)],
    attempts :: Map Int Int,
    events :: [Event],
    firstSuccesses :: [Int]
  }

runSchedule :: Schedule -> IO (Either KafkaError Trace)
runSchedule schedule = do
  state <- newIORef (SimState 0 0 (fmap recordAt [0 .. fromIntegral schedule.maxOffsets - 1]) Map.empty [] [])
  adapterState <- newKafkaAdapterState
  let topic = TopicName "model"
      config = (defaultConfig [topic]) {Config.batchSize = BatchSize (max 1 (min schedule.inboxDepth schedule.batchSize))}
      maxSteps = max 1 (4 * schedule.maxOffsets + 10)
      drive steps = do
        current <- liftIO (readIORef state)
        if current.position >= schedule.maxOffsets || steps >= maxSteps
          then pure (steps < maxSteps)
          else do
            let count = min (schedule.maxOffsets - current.position) (max 1 (min schedule.inboxDepth schedule.batchSize))
                source =
                  ingestedStream (mkIngested adapterState config) $
                    dropStaleRecords adapterState $
                      Stream.take count (kafkaSource adapterState config)
            ingested <- Stream.fold Fold.toList source
            forM_ ingested (decideAndAck state schedule)
            drive (steps + 1)
  runEff . runErrorNoCallStack @KafkaError . runSimConsumer state $ do
    completed <- drive (0 :: Int)
    final <- liftIO (readIORef state)
    pure (Trace final.events final.firstSuccesses final.stored schedule.maxOffsets completed (length final.events))

decideAndAck :: (IOE :> es) => IORef SimState -> Schedule -> Ingested es (Maybe ByteString.ByteString) -> Eff es ()
decideAndAck state schedule ingested = case ingested.envelope.cursor of
  Just (CursorInt offsetValue) -> do
    let offset = offsetValue
    decision <- liftIO $
      atomicModifyIORef' state \current ->
        let attempted = Map.findWithDefault 0 offset current.attempts
            scripted = Map.findWithDefault [] offset schedule.script
            chosen = case drop attempted scripted of next : _ -> next; [] -> DecideOk
            firstSuccess = chosen == DecideOk && offset `notElem` current.firstSuccesses
            updated =
              current
                { attempts = Map.insert offset (attempted + 1) current.attempts,
                  events = current.events <> [Decided offset chosen],
                  firstSuccesses = if firstSuccess then current.firstSuccesses <> [offset] else current.firstSuccesses
                }
         in (updated, chosen)
    let AckHandle finalize = ingested.ack
    finalize $ case decision of
      DecideOk -> AckOk
      DecideRetry -> AckRetry (RetryDelay 0)
  _ -> error "model record lacks an integer cursor"

runSimConsumer :: (IOE :> es) => IORef SimState -> Eff (KafkaConsumer : es) a -> Eff es a
runSimConsumer state =
  interpret $ \_environment -> \case
    PollMessageBatch _ (BatchSize size) -> liftIO $
      atomicModifyIORef' state \current ->
        let batch = take size (drop current.position current.records)
         in (current {position = current.position + length batch}, fmap Right batch)
    SeekPartitions partitions _ -> liftIO $
      atomicModifyIORef' state \current ->
        case partitions of
          TopicPartition _ _ partitionOffset : _ -> case partitionOffset of
            PartitionOffset offset ->
              (current {position = fromIntegral offset, events = current.events <> [Sought (fromIntegral offset)]}, ())
            _ -> error "model expects an absolute seek offset"
          [] -> (current, ())
    StoreOffsetMessage record -> liftIO $
      atomicModifyIORef' state \current ->
        let Offset offset = record.crOffset
            next = fromIntegral offset + 1
         in (current {stored = next, events = current.events <> [Stored next]}, ())
    PollMessage _ -> error "model does not use PollMessage"
    PollMessageEither _ -> error "model does not use PollMessageEither"
    CommitOffsetMessage _ _ -> error "model does not use CommitOffsetMessage"
    CommitAllOffsets _ -> error "model does not use CommitAllOffsets"
    CommitPartitionsOffsets _ _ -> error "model does not use CommitPartitionsOffsets"
    StoreOffsets _ -> error "model does not use StoreOffsets"
    Assign _ -> error "model does not use Assign"
    ResumePartitions _ -> error "model does not use ResumePartitions"
    PausePartitions _ -> error "model does not use PausePartitions"
    Committed _ _ -> error "model does not use Committed"
    Position _ -> error "model does not use Position"
    Assignment -> error "model does not use Assignment"
    Subscription -> error "model does not use Subscription"
    AskConsumerHandle -> error "model does not use AskConsumerHandle"

recordAt :: Int64 -> ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)
recordAt offset =
  ConsumerRecord
    { crTopic = TopicName "model",
      crPartition = PartitionId 0,
      crOffset = Offset offset,
      crTimestamp = NoTimestamp,
      crHeaders = mempty,
      crKey = Nothing,
      crValue = Just (ByteString.pack (show offset))
    }

propNoCommitPastUnacked :: Trace -> Bool
propNoCommitPastUnacked trace = go Set.empty trace.events
  where
    go _ [] = True
    go successes (Decided offset DecideOk : rest) = go (Set.insert offset successes) rest
    go successes (Stored storedOffset : rest) =
      let firstUnacked = maybe trace.logEnd id (find (`Set.notMember` successes) [0 .. trace.logEnd])
       in storedOffset <= firstUnacked && go successes rest
    go successes (_ : rest) = go successes rest

propFirstSuccessInOrder :: Trace -> Bool
propFirstSuccessInOrder trace = strictlyIncreasing trace.firstSuccesses

propTerminates :: Trace -> Bool
propTerminates trace = trace.terminated && trace.finalStored == trace.logEnd

strictlyIncreasing :: [Int] -> Bool
strictlyIncreasing values = and (zipWith (<) values (drop 1 values))
