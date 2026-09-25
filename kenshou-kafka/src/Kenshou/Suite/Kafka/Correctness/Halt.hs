module Kenshou.Suite.Kafka.Correctness.Halt (scenarios) where

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (Offset (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (KafkaError, PartitionId (..), Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers)
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/halt-leaves-offset-uncommitted"),
        revision = 1,
        summary = "Halts at partition-zero offset 30, checks the committed boundary and resumed delivery.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runHalt
      }
  ]

runHalt :: RunContext -> IO ScenarioReport
runHalt context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "halt" 2 mempty]
    producePartitions env topic
    facts <- newIORef ([] :: [(Int, Int)])
    result <- timeout 30000000 (consumeUntilHalt env topic facts)
    seen <- reverse <$> readIORef facts
    snapshot <- describeGroup env (groupName env "halt")
    resumed <- firstPartitionZeroOnResume env topic
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let stopped = result == Just ()
        partitionZero = [offset | (partition, offset) <- seen, partition == 0]
        p0Boundary = [offset | item <- snapshot.offsets, item.partition == PartitionId 0, Just offset <- [item.committed]]
        good = stopped && sort partitionZero == [0 .. 30] && lastMaybe seen == Just (0, 30) && p0Boundary == [30] && resumed == Just 30
    pure $
      if good
        then passed
        else failedWith ["halt-leaves-offset-uncommitted"] ("stopped=" <> Text.pack (show stopped) <> " seen=" <> Text.pack (show seen) <> " snapshot=" <> Text.pack (show snapshot) <> " resumed=" <> Text.pack (show resumed))

producePartitions :: KafkaEnv -> TopicName -> IO ()
producePartitions env topic = do
  let props = P.brokersList (firstBrokers env) <> P.sendTimeout (Timeout 10000) <> P.extraProp "acks" "all"
  outcome <- runEff . runError @KafkaError $
    P.runKafkaProducer props $
      forM_ [0 :: Int, 1] \partition ->
        forM_ [0 :: Int .. 99] \offset -> do
          let payload = ByteString.pack (show partition <> ":" <> show offset)
          _ <-
            P.produceMessageSync
              P.ProducerRecord
                { P.prTopic = topic,
                  P.prPartition = P.SpecifiedPartition partition,
                  P.prKey = Nothing,
                  P.prValue = Just payload,
                  P.prHeaders = mempty
                }
          pure ()
  either (ioError . userError . show) pure outcome

consumeUntilHalt :: KafkaEnv -> TopicName -> IORef [(Int, Int)] -> IO ()
consumeUntilHalt env topic facts = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "halt") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let handler Message {envelope = Envelope {partition, cursor}} = do
            let coordinate = do
                  p <- partition >>= readInt
                  CursorInt o <- cursor
                  pure (p, o)
            case coordinate of
              Nothing -> pure AckOk
              Just position -> do
                liftIO $ modifyIORef' facts (position :)
                pure $ if position == (0, 30) then AckHalt (HaltFatal "kenshou") else AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "halt", mkProcessor adapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure outcome

firstPartitionZeroOnResume :: KafkaEnv -> TopicName -> IO (Maybe Int)
firstPartitionZeroOnResume env topic = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "halt") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (loop 0)
  either (ioError . userError . show) pure outcome
  where
    loop (attempts :: Int)
      | attempts >= 220 = pure Nothing
      | otherwise = do
          candidate <- C.pollMessage (Timeout 1000)
          case candidate of
            Nothing -> loop (attempts + 1)
            Just record
              | C.crPartition record == PartitionId 0 -> pure (Just (fromIntegral (unOffset (C.crOffset record))))
              | otherwise -> loop (attempts + 1)

readInt :: Text -> Maybe Int
readInt value = case reads (Text.unpack value) of [(number, "")] -> Just number; _ -> Nothing

lastMaybe :: [a] -> Maybe a
lastMaybe [] = Nothing
lastMaybe values = Just (last values)
