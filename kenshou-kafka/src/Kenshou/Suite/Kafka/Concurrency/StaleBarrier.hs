module Kenshou.Suite.Kafka.Concurrency.StaleBarrier (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, join)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..), Offset (..))
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, PartitionId (..), TopicName (..))
import Kenshou.Check.Process (Child, Supervisor, awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/stale-barrier-after-partition-roundtrip"),
        revision = 1,
        summary = "Checks that a retry barrier is cleared when a partition leaves and returns to a consumer.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [KnobSpec (key "kafka.rebalance-handler") "Install the adapter's rebalance callback" KnobText (VText "installed") (OneOf (VText "installed" :| [VText "absent"])) []],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runStaleBarrier
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "barrier ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset"

data RebalanceFact = RebalanceFact {kind :: Text, partitions :: [Int]} deriving stock (Eq, Show)

instance FromJSON RebalanceFact where
  parseJSON = withObject "barrier rebalance fact" \v -> RebalanceFact <$> v .: "kind" <*> v .: "partitions"

data RetryFact = RetryFact {partition :: Int, offset :: Int} deriving stock (Eq, Show)

instance FromJSON RetryFact where
  parseJSON = withObject "barrier retry fact" \v -> RetryFact <$> v .: "partition" <*> v .: "offset"

runStaleBarrier :: RunContext -> IO ScenarioReport
runStaleBarrier context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let group = groupName env "stale-barrier"
        installed = knobText context.knobs (key "kafka.rebalance-handler") == "installed"
    [topic] <- createTopics env [TopicSpec "stale-barrier" 2 mempty]
    firstOffsets <- forM [0, 1] \partition -> produceAt env topic partition [partition * 1000 .. partition * 1000 + 299]
    (retriedBoth, moved, drained, returningAssignment, newOffsets, handled, errors) <- withCheck context \check -> withSupervisor check \supervisor -> do
      let shared = ["brokers" .= fmap unBrokerAddress (firstBrokers env), "topic" .= unTopicName topic, "group" .= unConsumerGroupId group, "autoCommitMillis" .= (1000 :: Int)]
          aArgs = object (shared <> ["retryOffset" .= (50 :: Int), "retryDelayMillis" .= (200 :: Int), "installRebalanceHandler" .= installed])
          bArgs = object shared
      aSpec <- roleProcess check "kafka/crash-consumer" 0 aArgs
      bSpec <- roleProcess check "kafka/crash-consumer" 1 bArgs
      a <- spawn supervisor aSpec
      awaitReady a 10000
      sendCommand a CtlStart
      retried <- waitUntil 30 do
        rows <- readChildMessages a
        let retries = retryFacts rows
        pure (all (\partition -> any (\fact -> fact.partition == partition && fact.offset == 50) retries) [0, 1])
      b <- spawn supervisor bSpec
      awaitReady b 10000
      sendCommand b CtlStart
      movedPartition <- awaitAssigned b 30
      reached <- case movedPartition of
        Nothing -> pure False
        Just partition -> waitUntil 30 do
          snapshot <- describeGroup env group
          pure (any (\item -> item.partition == PartitionId partition && item.lag == Just 0) snapshot.offsets)
      previousAssignments <- case movedPartition of
        Nothing -> pure 0
        Just partition -> assignmentCount a partition
      stopIfAlive supervisor b
      returned <- case movedPartition of
        Nothing -> pure False
        Just partition -> if installed then waitUntil 30 ((> previousAssignments) <$> assignmentCount a partition) else pure False
      later <- case movedPartition of
        Nothing -> pure []
        Just partition -> produceAt env topic partition [2000 .. 2099]
      complete <- case movedPartition of
        Nothing -> pure False
        Just partition -> waitUntil 30 do
          rows <- readChildMessages a
          let accepted = Set.fromList [fact.value | fact <- okFacts rows, fact.partition == partition]
          pure (all (`Set.member` accepted) [2000 .. 2099])
      stopIfAlive supervisor a
      aRows <- readChildMessages a
      bRows <- readChildMessages b
      pure (retried, movedPartition, reached, returned, later, complete, [problem | WrkError problem <- aRows <> bRows])
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let firstProduced = all (\offsets -> fmap unOffset offsets == [0 .. 299]) firstOffsets
        laterProduced = fmap unOffset newOffsets == [300 .. 399]
        failures =
          ["roundtrip-initial-produce" | not firstProduced]
            <> ["roundtrip-retry-barriers" | not retriedBoth]
            <> ["roundtrip-partition-move" | moved == Nothing || not drained]
            <> ["roundtrip-return-assignment" | installed && not returningAssignment]
            <> ["roundtrip-later-produce" | moved /= Nothing && not laterProduced]
            <> ["roundtrip-new-records" | not handled]
            <> ["roundtrip-consumer-exit" | not (null errors)]
    putSummary context Verdicts "staleBarrier" (object ["handlerInstalled" .= installed, "retriedBothPartitions" .= retriedBoth, "movedPartition" .= moved, "movedPartitionDrained" .= drained, "returnedAssignment" .= returningAssignment, "laterOffsets" .= fmap unOffset newOffsets, "newRecordsHandled" .= handled, "workerErrors" .= errors])
    pure $ if null failures then passed else failedWith failures ("moved=" <> Text.pack (show moved) <> " drained=" <> Text.pack (show drained) <> " handled=" <> Text.pack (show handled) <> " errors=" <> Text.pack (show errors))

produceAt :: KafkaEnv -> TopicName -> Int -> [Int] -> IO [Offset]
produceAt env topic partition values = do
  let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
  result <- runEff . runError @KafkaError $
    P.runKafkaProducer props $
      forM values \value ->
        P.produceMessageSync
          P.ProducerRecord
            { P.prTopic = topic,
              P.prPartition = P.SpecifiedPartition partition,
              P.prKey = Just (ByteString.pack (show value)),
              P.prValue = Just (ByteString.pack (show value)),
              P.prHeaders = mempty
            }
  either (ioError . userError . show) pure result

awaitAssigned :: Child -> Int -> IO (Maybe Int)
awaitAssigned child seconds = do
  result <- timeout (seconds * 1000000) loop
  pure (join result)
  where
    loop = do
      rows <- readChildMessages child
      case [partition | fact <- rebalanceFacts rows, fact.kind == "assign", partition <- fact.partitions] of
        partition : _ -> pure (Just partition)
        [] -> threadDelay 200000 >> loop

assignmentCount :: Child -> Int -> IO Int
assignmentCount child partition = do
  rows <- readChildMessages child
  pure (length [() | fact <- rebalanceFacts rows, fact.kind == "assign", partition `elem` fact.partitions])

waitUntil :: Int -> IO Bool -> IO Bool
waitUntil seconds action = maybe False id <$> timeout (seconds * 1000000) loop
  where
    loop = do
      done <- action
      if done then pure True else threadDelay 200000 >> loop

okFacts :: [WorkerMessage] -> [OkFact]
okFacts = mapMaybe \case
  WrkCustom "ok" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

rebalanceFacts :: [WorkerMessage] -> [RebalanceFact]
rebalanceFacts = mapMaybe \case
  WrkCustom "rebalance" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

retryFacts :: [WorkerMessage] -> [RetryFact]
retryFacts = mapMaybe \case
  WrkCustom "retry" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

stopIfAlive :: Supervisor -> Child -> IO ()
stopIfAlive supervisor child = do
  rows <- readChildMessages child
  if any ended rows
    then pure ()
    else do
      _ <- stopGracefully supervisor child 5000
      pure ()

ended :: WorkerMessage -> Bool
ended (WrkDone _) = True
ended (WrkError _) = True
ended _ = False

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName
