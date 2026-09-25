module Kenshou.Suite.Kafka.Roles (roles, adapterConsumerRole, batchProducerRole, transactionWorkerRole) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race, waitCatch)
import Control.Concurrent.STM (atomically, writeTVar)
import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Bits (bit, (.|.))
import Data.ByteString qualified as RawByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector.Unboxed qualified as Vector
import Data.Vector.Unboxed.Mutable qualified as MutableVector
import Data.Word (Word8)
import Effectful (Eff, liftIO, runEff, (:>))
import Effectful.Error.Static (runError)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (listThreads)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Kafka.Consumer.Types (ConsumerGroupId (..), Offset (..), RebalanceEvent (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, PartitionId (..), Timeout (..), TopicName (..))
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Measure.Sampler.Process (ProcessSample (..), readProcessSample)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter, kafkaAdapterWith, kafkaRebalanceHandler, newKafkaAdapterState)
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState (..))
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..), toMessage)
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.Mem (performMajorGC)
import System.Timeout (timeout)

roles :: [WorkerRole]
roles =
  [ WorkerRole adapterConsumerRole "Consumes Kafka records through the adapter under a declared handler policy." runAdapterConsumer,
    WorkerRole crashConsumerRole "Records adapter handler decisions across controlled SIGKILL cycles." runCrashConsumer,
    WorkerRole soakConsumerRole "Samples consumer process resources and writes a compact handled-ID ledger." runSoakConsumer,
    WorkerRole rawConsumerRole "Reports raw Kafka assignment callbacks and consumed records." runRawConsumer,
    WorkerRole batchProducerRole "Enqueues a batch and attempts a bounded flush during a broker outage." runBatchProducer,
    WorkerRole transactionWorkerRole "Stages a consume-transform-produce transaction until told to commit." runTransactionWorker
  ]

adapterConsumerRole :: RoleName
adapterConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/adapter-consumer")

crashConsumerRole :: RoleName
crashConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/crash-consumer")

soakConsumerRole :: RoleName
soakConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/soak-consumer")

rawConsumerRole :: RoleName
rawConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/raw-consumer")

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
    autoCommitMillis :: Int,
    autoOffsetStore :: Bool,
    blockOffset :: Maybe Int,
    blockMillis :: Int,
    instanceId :: Maybe Text,
    haltOffset :: Maybe Int,
    holdAfterHalt :: Bool,
    maxPollMillis :: Maybe Int,
    sessionMillis :: Maybe Int,
    serviceMillis :: Int,
    installRebalanceHandler :: Bool,
    retryOffset :: Maybe Int,
    retryDelayMillis :: Int,
    emitOkFacts :: Bool,
    progressEvery :: Int,
    ledgerPath :: Maybe FilePath,
    ledgerRecords :: Maybe Int,
    streamMode :: Bool
  }

instance FromJSON CrashConsumerArgs where
  parseJSON = withObject "Kafka crash consumer args" \value ->
    CrashConsumerArgs
      <$> value .: "brokers"
      <*> value .: "topic"
      <*> value .: "group"
      <*> value .: "autoCommitMillis"
      <*> (fromMaybe False <$> value .:? "autoOffsetStore")
      <*> value .:? "blockOffset"
      <*> (fromMaybe 0 <$> value .:? "blockMillis")
      <*> value .:? "instanceId"
      <*> value .:? "haltOffset"
      <*> (fromMaybe False <$> value .:? "holdAfterHalt")
      <*> value .:? "maxPollMillis"
      <*> value .:? "sessionMillis"
      <*> (fromMaybe 0 <$> value .:? "serviceMillis")
      <*> (fromMaybe True <$> value .:? "installRebalanceHandler")
      <*> value .:? "retryOffset"
      <*> (fromMaybe 0 <$> value .:? "retryDelayMillis")
      <*> (fromMaybe True <$> value .:? "emitOkFacts")
      <*> (fromMaybe 10 <$> value .:? "progressEvery")
      <*> value .:? "ledgerPath"
      <*> value .:? "ledgerRecords"
      <*> (fromMaybe False <$> value .:? "streamMode")

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

data SoakConsumerArgs = SoakConsumerArgs {consumer :: CrashConsumerArgs, sampleEverySeconds :: Int}

instance FromJSON SoakConsumerArgs where
  parseJSON value = withObject "Kafka soak consumer args" (\fields -> SoakConsumerArgs <$> parseJSON value <*> (fromMaybe 10 <$> fields .:? "sampleEverySeconds")) value

runSoakConsumer :: RoleContext -> IO ()
runSoakConsumer context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String SoakConsumerArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      state <- newKafkaAdapterState
      consumer <- async (consumeCrashWithState context args.consumer state)
      sampler <- async (sampleSoak context (max 1 args.sampleEverySeconds))
      next <- race (waitCatch consumer) context.receive
      case next of
        Right (Just (CtlStop _)) -> do
          atomically (writeTVar state.shutdownVar True)
          stopped <- timeout 15000000 (waitCatch consumer)
          case stopped of
            Just result -> context.send (WrkCustom "soak-stopped" (object ["result" .= show result]))
            Nothing -> context.send (WrkError "soak consumer did not stop within 15 seconds") >> cancel consumer
        Right _ -> atomically (writeTVar state.shutdownVar True) >> cancel consumer
        Left result -> context.send (WrkError ("soak consumer exited before stop: " <> Text.pack (show result)))
      cancel sampler
    _ -> ioError (userError "soak-consumer expected start")

sampleSoak :: RoleContext -> Int -> IO ()
sampleSoak context seconds = do
  performMajorGC
  now <- getMonotonicTimeNSec
  enabled <- getRTSStatsEnabled
  stats <- if enabled then Just <$> getRTSStats else pure Nothing
  process <- readProcessSample
  threads <- length <$> listThreads
  context.send $
    WrkCustom "soak-sample" $
      object
        [ "monoNs" .= now,
          "rssBytes" .= process.rssBytes,
          "osThreads" .= process.osThreads,
          "fds" .= process.openFds,
          "majorGcs" .= fmap (.major_gcs) stats,
          "liveBytes" .= fmap (.gcdetails_live_bytes) (fmap (.gc) stats),
          "memInUseBytes" .= fmap (.gcdetails_mem_in_use_bytes) (fmap (.gc) stats),
          "haskellThreads" .= threads
        ]
  threadDelay (seconds * 1000000)
  sampleSoak context seconds

consumeCrash :: RoleContext -> CrashConsumerArgs -> IO ()
consumeCrash context args = do
  state <- newKafkaAdapterState
  consumeCrashWithState context args state

consumeCrashWithState :: RoleContext -> CrashConsumerArgs -> KafkaAdapterState -> IO ()
consumeCrashWithState context args state = do
  count <- newIORef (0 :: Int)
  ledger <- case (args.ledgerPath, args.ledgerRecords) of
    (Just path, Just records) | records > 0 -> Just . (path,) <$> MutableVector.replicate ((records + 7) `div` 8) (0 :: Word8)
    _ -> pure Nothing
  let topic = TopicName args.topic
      rebalance consumer event = do
        kafkaRebalanceHandler state consumer event
        at <- getCurrentTime
        let (kind, partitions) = case event of
              RebalanceBeforeAssign values -> ("before-assign" :: Text, values)
              RebalanceAssign values -> ("assign", values)
              RebalanceBeforeRevoke values -> ("before-revoke", values)
              RebalanceRevoke values -> ("revoke", values)
            coordinates = [number | (_, PartitionId number) <- partitions]
        context.send (WrkCustom "rebalance" (object ["kind" .= kind, "partitions" .= coordinates, "at" .= at]))
      props =
        C.brokersList (fmap BrokerAddress args.brokers)
          <> C.groupId (ConsumerGroupId args.group)
          <> (if args.autoOffsetStore then mempty else C.noAutoOffsetStore)
          <> C.extraProp "auto.commit.interval.ms" (Text.pack (show args.autoCommitMillis))
          <> C.extraProp "session.timeout.ms" (Text.pack (show (fromMaybe 6000 args.sessionMillis)))
          <> C.extraProp "heartbeat.interval.ms" "2000"
          <> maybe mempty (C.extraProp "group.instance.id") args.instanceId
          <> maybe mempty (C.extraProp "max.poll.interval.ms" . Text.pack . show) args.maxPollMillis
          <> (if args.installRebalanceHandler then C.setCallback (C.rebalanceCallback rebalance) else mempty)
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapterWith state (defaultConfig [topic])
      let handler Message {envelope = Envelope {payload, partition, cursor}} = do
            case (payload >>= readInt, partition >>= readTextInt, cursor) of
              (Just value, Just partitionNumber, Just (CursorInt offset)) -> do
                if Just offset == args.retryOffset
                  then do
                    liftIO $ do
                      at <- getCurrentTime
                      context.send (WrkCustom "retry" (object ["value" .= value, "partition" .= partitionNumber, "offset" .= offset, "at" .= at]))
                    pure (AckRetry (RetryDelay (fromIntegral args.retryDelayMillis / 1000)))
                  else
                    if Just offset == args.haltOffset
                      then do
                        liftIO $ context.send (WrkCustom "halted" (object ["value" .= value, "partition" .= partitionNumber, "offset" .= offset]))
                        pure (AckHalt (HaltFatal "kenshou assignment hold"))
                      else do
                        liftIO $ do
                          if args.serviceMillis > 0 then threadDelay (args.serviceMillis * 1000) else pure ()
                          if Just offset == args.blockOffset
                            then do
                              context.send (WrkCustom "entered-block" (object ["offset" .= offset]))
                              threadDelay (args.blockMillis * 1000)
                            else pure ()
                          at <- getCurrentTime
                          if args.emitOkFacts then context.send (WrkCustom "ok" (object ["value" .= value, "partition" .= partitionNumber, "offset" .= offset, "at" .= at])) else pure ()
                          forM_ ledger \(_, bits) ->
                            if value >= 0 && value < MutableVector.length bits * 8
                              then do
                                old <- MutableVector.read bits (value `div` 8)
                                MutableVector.write bits (value `div` 8) (old .|. bit (value `mod` 8))
                              else context.send (WrkError ("soak ledger ID outside fixed range: " <> Text.pack (show value)))
                          handled <- atomicModifyIORef' count (\old -> let next = old + 1 in (next, next))
                          if handled `mod` max 1 args.progressEvery == 0 then getCurrentTime >>= context.send . WrkProgress (fromIntegral handled) else pure ()
                        pure AckOk
              _ -> pure (AckHalt (HaltFatal "invalid crash-consumer coordinate"))
      if args.streamMode
        then Stream.fold Fold.drain $ Stream.mapM (\ingested@Ingested {ack = AckHandle finalize} -> handler (toMessage ingested) >>= finalize) adapter.source
        else do
          appResult <- runApp defaultAppConfig [(ProcessorId "crash-consumer", mkProcessor adapter handler)]
          case appResult of
            Left problem -> liftIO $ ioError (userError (show problem))
            Right handle -> do
              waitApp handle
              if args.holdAfterHalt then liftIO (threadDelay 120000000) else pure ()
              stopApp handle
  case outcome of
    Left problem -> context.send (WrkError (Text.pack (show problem)))
    Right () -> pure ()
  forM_ ledger \(path, bits) -> do
    createDirectoryIfMissing True (takeDirectory path)
    bytes <- Vector.freeze bits
    let occupied = Vector.ifoldl' (\items index value -> if value == 0 then items else (index, value) : items) [] bytes
    if 5 * length occupied < Vector.length bytes
      then LazyByteString.writeFile path (Builder.toLazyByteString (Builder.byteString "KSL1" <> foldMap (\(index, value) -> Builder.word32LE (fromIntegral index) <> Builder.word8 value) occupied))
      else RawByteString.writeFile path ("KDL1" <> RawByteString.pack (Vector.toList bytes))
    handled <- readIORef count
    context.send (WrkCustom "soak-ledger" (object ["path" .= path, "handled" .= handled]))

readTextInt :: Text -> Maybe Int
readTextInt = readInt . ByteString.pack . Text.unpack

data RawConsumerArgs = RawConsumerArgs
  { brokers :: [Text],
    topic :: Text,
    group :: Text,
    instanceId :: Text,
    sessionMillis :: Int
  }

instance FromJSON RawConsumerArgs where
  parseJSON = withObject "Kafka raw consumer args" \value ->
    RawConsumerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "group" <*> value .: "instanceId" <*> value .: "sessionMillis"

runRawConsumer :: RoleContext -> IO ()
runRawConsumer context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String RawConsumerArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      consumer <- async (consumeRaw context args)
      next <- race (waitCatch consumer) context.receive
      case next of
        Right (Just (CtlStop _)) -> cancel consumer
        Right _ -> cancel consumer
        Left result -> context.send (WrkError ("raw-consumer exited before stop: " <> Text.pack (show result)))
    _ -> ioError (userError "raw-consumer expected start")

consumeRaw :: RoleContext -> RawConsumerArgs -> IO ()
consumeRaw context args = do
  let topic = TopicName args.topic
      rebalance _ event = do
        at <- getCurrentTime
        let (kind, partitions) = case event of
              RebalanceBeforeAssign values -> ("before-assign" :: Text, values)
              RebalanceAssign values -> ("assign", values)
              RebalanceBeforeRevoke values -> ("before-revoke", values)
              RebalanceRevoke values -> ("revoke", values)
            coordinates = [number | (_, PartitionId number) <- partitions]
        context.send (WrkCustom (if kind == "assign" then "assigned" else "rebalance") (object ["kind" .= kind, "partitions" .= coordinates, "at" .= at]))
      props =
        C.brokersList (fmap BrokerAddress args.brokers)
          <> C.groupId (ConsumerGroupId args.group)
          <> C.noAutoCommit
          <> C.noAutoOffsetStore
          <> C.extraProp "group.instance.id" args.instanceId
          <> C.extraProp "session.timeout.ms" (Text.pack (show args.sessionMillis))
          <> C.extraProp "heartbeat.interval.ms" (Text.pack (show (args.sessionMillis `div` 3)))
          <> C.setCallback (C.rebalanceCallback rebalance)
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <-
    runEff . runError @KafkaError $
      C.runKafkaConsumer props subscription (pollForever (0 :: Int))
  case outcome of
    Left problem -> context.send (WrkError (Text.pack (show problem)))
    Right () -> pure ()
  where
    pollForever count = do
      candidate <- C.pollMessage (Timeout 500)
      case candidate of
        Nothing -> pollForever count
        Just record -> do
          liftIO $ do
            at <- getCurrentTime
            context.send (WrkCustom "record" (object ["partition" .= unPartitionId (C.crPartition record), "offset" .= unOffset (C.crOffset record), "at" .= at]))
            if count `mod` 10 == 0 then context.send (WrkProgress (fromIntegral count) at) else pure ()
          C.commitOffsetMessage C.OffsetCommit record
          pollForever (count + 1)

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
