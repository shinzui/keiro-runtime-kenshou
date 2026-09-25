module Kenshou.Suite.Kafka.Roles (roles, adapterConsumerRole, batchProducerRole, transactionWorkerRole) where

import Control.Concurrent.Async (async, cancel, race, waitCatch)
import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff, liftIO, runEff, (:>))
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream

roles :: [WorkerRole]
roles =
  [ WorkerRole adapterConsumerRole "Consumes Kafka records through the adapter under a declared handler policy." runAdapterConsumer,
    WorkerRole crashConsumerRole "Records adapter handler decisions across controlled SIGKILL cycles." runCrashConsumer,
    WorkerRole batchProducerRole "Enqueues a batch and attempts a bounded flush during a broker outage." runBatchProducer,
    WorkerRole transactionWorkerRole "Stages a consume-transform-produce transaction until told to commit." runTransactionWorker
  ]

adapterConsumerRole :: RoleName
adapterConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/adapter-consumer")

crashConsumerRole :: RoleName
crashConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/crash-consumer")

batchProducerRole :: RoleName
batchProducerRole = either (error . Text.unpack) id (mkRoleName "kafka/batch-producer")

transactionWorkerRole :: RoleName
transactionWorkerRole = either (error . Text.unpack) id (mkRoleName "kafka/transaction-worker")

data ConsumerArgs = ConsumerArgs
  { brokers :: [Text],
    topic :: Text,
    group :: Text,
    messages :: Int,
    poisonCount :: Int
  }

instance FromJSON ConsumerArgs where
  parseJSON = withObject "Kafka consumer args" \value ->
    ConsumerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "group" <*> value .: "messages" <*> value .: "poisonCount"

runAdapterConsumer :: RoleContext -> IO ()
runAdapterConsumer context = do
  args <- case fromJson context.init.args of
    Left problem -> ioError (userError problem)
    Right value -> pure value
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      (oks, drops) <- consumeDeadLetters args
      context.send (WrkCustom "summary" (object ["ok" .= oks, "dropped" .= drops]))
      _ <- context.receive
      pure ()
    _ -> ioError (userError "adapter-consumer expected start")

fromJson :: (FromJSON a) => Value -> Either String a
fromJson value = case Aeson.fromJSON value of Aeson.Error problem -> Left problem; Aeson.Success parsed -> Right parsed

consumeDeadLetters :: ConsumerArgs -> IO ([Int], [Int])
consumeDeadLetters args = do
  oks <- newIORef []
  drops <- newIORef []
  let topic = TopicName args.topic
      props = C.brokersList (fmap BrokerAddress args.brokers) <> C.groupId (ConsumerGroupId args.group) <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let finiteAdapter = adapter {source = Stream.take args.messages adapter.source}
          handler Message {envelope = Envelope {payload}} = case payload >>= readInt of
            Nothing -> pure (AckHalt (HaltFatal "invalid payload"))
            Just value
              | value < args.poisonCount -> do
                  liftIO $ modifyIORef' drops (value :)
                  pure (AckDeadLetter (PoisonPill "kenshou"))
              | otherwise -> do
                  liftIO $ modifyIORef' oks (value :)
                  pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "adapter-consumer", mkProcessor finiteAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure outcome
  (,) <$> (reverse <$> readIORef oks) <*> (reverse <$> readIORef drops)

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

data CrashConsumerArgs = CrashConsumerArgs
  { brokers :: [Text],
    topic :: Text,
    group :: Text,
    autoCommitMillis :: Int
  }

instance FromJSON CrashConsumerArgs where
  parseJSON = withObject "Kafka crash consumer args" \value ->
    CrashConsumerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "group" <*> value .: "autoCommitMillis"

runCrashConsumer :: RoleContext -> IO ()
runCrashConsumer context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String CrashConsumerArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      consumer <- async (consumeCrash context args)
      next <- race (waitCatch consumer) context.receive
      case next of
        Right (Just (CtlStop _)) -> do
          cancel consumer
          result <- waitCatch consumer
          context.send (WrkCustom "stopped" (object ["result" .= show result]))
        Right _ -> cancel consumer
        Left result -> context.send (WrkError ("crash-consumer exited before stop: " <> Text.pack (show result)))
    _ -> ioError (userError "crash-consumer expected start")

consumeCrash :: RoleContext -> CrashConsumerArgs -> IO ()
consumeCrash context args = do
  count <- newIORef (0 :: Int)
  let topic = TopicName args.topic
      props =
        C.brokersList (fmap BrokerAddress args.brokers)
          <> C.groupId (ConsumerGroupId args.group)
          <> C.noAutoOffsetStore
          <> C.extraProp "auto.commit.interval.ms" (Text.pack (show args.autoCommitMillis))
          <> C.extraProp "session.timeout.ms" "6000"
          <> C.extraProp "heartbeat.interval.ms" "2000"
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let handler Message {envelope = Envelope {payload, partition, cursor}} = do
            case (payload >>= readInt, partition >>= readTextInt, cursor) of
              (Just value, Just partitionNumber, Just (CursorInt offset)) -> do
                liftIO $ do
                  at <- getCurrentTime
                  context.send (WrkCustom "ok" (object ["value" .= value, "partition" .= partitionNumber, "offset" .= offset, "at" .= at]))
                  handled <- atomicModifyIORef' count (\old -> let next = old + 1 in (next, next))
                  if handled `mod` 10 == 0 then getCurrentTime >>= context.send . WrkProgress (fromIntegral handled) else pure ()
                pure AckOk
              _ -> pure (AckHalt (HaltFatal "invalid crash-consumer coordinate"))
      appResult <- runApp defaultAppConfig [(ProcessorId "crash-consumer", mkProcessor adapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  case outcome of
    Left problem -> context.send (WrkError (Text.pack (show problem)))
    Right () -> pure ()

readTextInt :: Text -> Maybe Int
readTextInt = readInt . ByteString.pack . Text.unpack

data ProducerArgs = ProducerArgs {brokers :: [Text], topic :: Text, messages :: Int, messageTimeoutMillis :: Int}

instance FromJSON ProducerArgs where
  parseJSON = withObject "Kafka producer args" \value ->
    ProducerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "messages" <*> value .: "messageTimeoutMillis"

runBatchProducer :: RoleContext -> IO ()
runBatchProducer context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String ProducerArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      let props = P.brokersList (fmap BrokerAddress args.brokers) <> P.extraProp "message.timeout.ms" (Text.pack (show args.messageTimeoutMillis))
          topic = TopicName args.topic
          records =
            [ P.ProducerRecord
                { P.prTopic = topic,
                  P.prPartition = P.UnassignedPartition,
                  P.prKey = Just (ByteString.pack (show number)),
                  P.prValue = Just (ByteString.pack (show number)),
                  P.prHeaders = mempty
                }
            | number <- [0 .. args.messages - 1]
            ]
      outcome <- runEff . runError @KafkaError $
        P.runKafkaProducer props $ do
          failures <- P.produceMessageBatch records
          liftIO $ context.send (WrkCustom "enqueue" (object ["failures" .= length failures, "submitted" .= args.messages]))
          P.flushProducer
          liftIO $ context.send (WrkCustom "flushed" (object []))
      case outcome of
        Left problem -> context.send (WrkError (Text.pack (show problem)))
        Right () -> pure ()
      _ <- context.receive
      pure ()
    _ -> ioError (userError "batch-producer expected start")

data TransactionArgs = TransactionArgs
  { brokers :: [Text],
    inputTopic :: Text,
    outputTopic :: Text,
    group :: Text,
    transactionId :: Text,
    messages :: Int
  }

instance FromJSON TransactionArgs where
  parseJSON = withObject "Kafka transaction args" \value ->
    TransactionArgs <$> value .: "brokers" <*> value .: "inputTopic" <*> value .: "outputTopic" <*> value .: "group" <*> value .: "transactionId" <*> value .: "messages"

runTransactionWorker :: RoleContext -> IO ()
runTransactionWorker context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String TransactionArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      let producerProps =
            P.brokersList (fmap BrokerAddress args.brokers)
              <> P.extraProp "transactional.id" args.transactionId
              <> P.extraProp "enable.idempotence" "true"
              <> P.extraProp "acks" "all"
          consumerProps =
            C.brokersList (fmap BrokerAddress args.brokers)
              <> C.groupId (ConsumerGroupId args.group)
              <> C.noAutoCommit
              <> C.noAutoOffsetStore
              <> C.extraProp "session.timeout.ms" "6000"
              <> C.extraProp "heartbeat.interval.ms" "2000"
              <> C.extraProp "isolation.level" "read_committed"
          subscription = C.topics [TopicName args.inputTopic] <> C.offsetReset C.Earliest
      outcome <- runEff . runError @KafkaError $
        P.runKafkaProducer producerProps $
          C.runKafkaConsumer consumerProps subscription $ do
            P.initTransactions (Timeout 10000)
            records <- collectRecords args.messages 0 []
            if length records /= args.messages
              then liftIO $ ioError (userError ("transaction worker read " <> show (length records) <> " records"))
              else pure ()
            P.beginTransaction
            forM_ records \record ->
              P.produceMessage
                P.ProducerRecord
                  { P.prTopic = TopicName args.outputTopic,
                    P.prPartition = P.UnassignedPartition,
                    P.prKey = C.crKey record,
                    P.prValue = C.crValue record,
                    P.prHeaders = mempty
                  }
            case reverse records of
              lastRecord : _ -> do
                offsetResult <- P.commitOffsetMessageTransaction lastRecord (Timeout 10000)
                case offsetResult of
                  Nothing -> pure ()
                  Just problem -> liftIO $ ioError (userError ("send offsets to transaction: " <> show (P.getKafkaError problem)))
              [] -> pure ()
            liftIO $ context.send (WrkCustom "prepared" (object ["records" .= length records]))
            release <- liftIO context.receive
            case release of
              Just (CtlCustom "commit" _) -> do
                result <- P.commitTransaction (Timeout 10000)
                case result of
                  Nothing -> liftIO $ context.send (WrkCustom "committed" (object ["records" .= length records]))
                  Just problem -> liftIO $ ioError (userError ("commit transaction: " <> show (P.getKafkaError problem)))
              _ -> liftIO $ ioError (userError "transaction worker expected commit")
      case outcome of
        Left problem -> context.send (WrkError (Text.pack (show problem)))
        Right () -> pure ()
      _ <- context.receive
      pure ()
    _ -> ioError (userError "transaction worker expected start")

collectRecords :: (C.KafkaConsumer :> es) => Int -> Int -> [C.ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)] -> Eff es [C.ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)]
collectRecords count emptyPolls collected
  | length collected >= count = pure (reverse collected)
  | emptyPolls >= 8 = pure (reverse collected)
  | otherwise = do
      candidate <- C.pollMessage (Timeout 2500)
      case candidate of
        Nothing -> collectRecords count (emptyPolls + 1) collected
        Just record -> collectRecords count 0 (record : collected)
