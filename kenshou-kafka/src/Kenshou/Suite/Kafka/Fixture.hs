module Kenshou.Suite.Kafka.Fixture (scenarios, produceValues, consumeValues, firstBrokers, intKnob) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.ByteString.Char8 qualified as ByteString
import Data.Foldable (toList)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ fixtureScenario "kafka/broker/correctness/fixture-roundtrip" "Round-trips 100 acknowledged records through a private broker." TierSmoke partitionKnobs runRoundtrip,
    fixtureScenario "kafka/broker/concurrency/kill-and-restart" "Kills and restarts the broker on its existing data." TierStandard outageKnobs runKillRestart
  ]

fixtureScenario :: Text -> Text -> Tier -> [KnobSpec] -> (RunContext -> IO ScenarioReport) -> Scenario
fixtureScenario identifier summary tier knobs run =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId identifier),
      revision = 1,
      summary,
      tier,
      placement = PlaceEither,
      knobs,
      dimensions = allTelemetryArms noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run
    }

partitionKnobs :: [KnobSpec]
partitionKnobs = [intKnob "kafka.partitions" "Number of topic partitions" 3 1 64]

outageKnobs :: [KnobSpec]
outageKnobs = [intKnob "kafka.outage-seconds" "Duration of broker outage" 5 1 60]

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob name summary def low high =
  KnobSpec (either (error . Text.unpack) id (mkKnobName name)) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

runRoundtrip :: RunContext -> IO ScenarioReport
runRoundtrip context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let partitions = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.partitions")))
    [topic] <- createTopics env [TopicSpec "roundtrip" partitions mempty]
    sent <- produceValues env topic [0 .. 99]
    received <- consumeValues env (if length env.lanes > 1 then 1 else 0) topic "roundtrip" 100
    let values = sort received
        expected = [0 .. 99]
        safe = all ((/= "127.0.0.1:9092") . unBrokerAddress) [broker | lane <- toList env.lanes, broker <- lane.laneBrokers]
    snapshot <- describeGroup env (groupName env "roundtrip")
    _ <- deleteRunGroups env
    removed <- deleteRunTopics env
    remaining <- deleteRunTopics env
    pure $
      if length sent == 100 && values == expected && safe && length snapshot.offsets == partitions && all ((== Just 0) . (.lag)) snapshot.offsets && removed == 1 && remaining == 0
        then passed
        else failedWith ["roundtrip"] ("sent=" <> Text.pack (show (length sent)) <> " received=" <> Text.pack (show (length received)) <> " group=" <> Text.pack (show snapshot) <> " removed=" <> Text.pack (show removed) <> " remaining=" <> Text.pack (show remaining))

runKillRestart :: RunContext -> IO ScenarioReport
runKillRestart context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> case env.control of
    Nothing -> pure (failedWith ["broker-control-unavailable"] "this Kafka environment has no broker control")
    Just control -> do
      [topic] <- createTopics env [TopicSpec "restart" 1 mempty]
      first <- produceValues env topic [0 .. 499]
      before <- control.generation
      control.kill
      down <- not <$> control.isRunning
      downWriteFailed <- attemptProduceDuringOutage env topic
      threadDelay (fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.outage-seconds"))) * 1000000)
      control.start
      after <- control.generation
      second <- produceValues env topic [500 .. 999]
      received <- consumeValues env 0 topic "restart" 1000
      let expected = [0 .. 999]
      _ <- deleteRunGroups env
      _ <- deleteRunTopics env
      pure $
        if down && downWriteFailed && before /= after && length first == 500 && length second == 500 && sort received == expected
          then passed
          else failedWith ["broker-restart"] ("down=" <> Text.pack (show down) <> " downWriteFailed=" <> Text.pack (show downWriteFailed) <> " generationChanged=" <> Text.pack (show (before /= after)) <> " received=" <> Text.pack (show (length received)))

attemptProduceDuringOutage :: KafkaEnv -> TopicName -> IO Bool
attemptProduceDuringOutage env (TopicName topic) = do
  let broker = case firstBrokers env of BrokerAddress value : _ -> Text.unpack value; [] -> error "Kafka lane has no broker"
  outcome <-
    timeout 5000000 $
      readProcessWithExitCode
        "rpk"
        ["--config", env.workDir </> "rpk.yaml", "-X", "brokers=" <> broker, "topic", "produce", Text.unpack topic, "--delivery-timeout", "1s"]
        "outage-probe\n"
  pure (maybe True (\(code, _, _) -> code /= ExitSuccess) outcome)

produceValues :: KafkaEnv -> TopicName -> [Int] -> IO [C.Offset]
produceValues env topic values = do
  let brokers = firstBrokers env
      props = P.brokersList brokers <> P.sendTimeout (Timeout 10000) <> P.extraProp "acks" "all"
  result <- runEff . runError @KafkaError $
    P.runKafkaProducer props $
      forM values \value ->
        P.produceMessageSync
          P.ProducerRecord
            { P.prTopic = topic,
              P.prPartition = P.UnassignedPartition,
              P.prKey = Just (ByteString.pack (show value)),
              P.prValue = Just (ByteString.pack (show value)),
              P.prHeaders = mempty
            }
  either (ioError . userError . show) pure result

consumeValues :: KafkaEnv -> Int -> TopicName -> Text -> Int -> IO [Int]
consumeValues env laneIndex topic suffix count = do
  let props = C.brokersList (brokersAt env laneIndex) <> C.groupId (groupName env suffix) <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (loop 0 [])
  either (ioError . userError . show) pure result
  where
    loop (emptyPolls :: Int) collected
      | length collected >= count = pure (reverse collected)
      | emptyPolls >= 60 = pure (reverse collected)
      | otherwise = do
          message <- C.pollMessage (Timeout 500)
          case message of
            Nothing -> loop (emptyPolls + 1) collected
            Just record -> do
              C.commitOffsetMessage C.OffsetCommit record
              case C.crValue record >>= readInt of
                Nothing -> loop emptyPolls collected
                Just value -> loop 0 (value : collected)
    readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

firstBrokers :: KafkaEnv -> [BrokerAddress]
firstBrokers env = case env.lanes of lane :| _ -> lane.laneBrokers

brokersAt :: KafkaEnv -> Int -> [BrokerAddress]
brokersAt env index = case drop index (toList env.lanes) of
  lane : _ -> lane.laneBrokers
  [] -> firstBrokers env
