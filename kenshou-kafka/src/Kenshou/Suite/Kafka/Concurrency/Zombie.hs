module Kenshou.Suite.Kafka.Concurrency.Zombie (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, when)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, PartitionId (..), TopicName (..))
import Kenshou.Check.Fault.Network (ProxyMode (..), resetConnections, setProxyMode)
import Kenshou.Check.Process (Child, Supervisor, awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobName, knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Env.Kafka.Spec qualified as KafkaSpec
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/partitioned-consumer-becomes-zombie"),
        revision = 1,
        summary = "Blackholes one consumer lane and checks takeover, offset monotonicity, and redelivery bounds.",
        tier = TierStandard,
        placement = PlaceLocal,
        knobs =
          [ intKnob "kafka.messages" "Acknowledged records" 5000 1000 30000,
            intKnob "kafka.prop.session.timeout.ms" "Consumer session timeout" 6000 6000 30000,
            intKnob "kafka.service-ms" "Per-record handler time" 5 0 100
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4",
                summary = "Released adapter consumers can end normally after group eviction and reassignment.",
                expectedFailures = ["zombie-consumer-exit", "zombie-zero-lag"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runZombie
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int, at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "zombie ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset" <*> v .: "at"

data RebalanceFact = RebalanceFact {kind :: Text, partitions :: [Int], at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON RebalanceFact where
  parseJSON = withObject "zombie rebalance fact" \v -> RebalanceFact <$> v .: "kind" <*> v .: "partitions" <*> v .: "at"

runZombie :: RunContext -> IO ScenarioReport
runZombie context = do
  rawSpec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context (rawSpec {KafkaSpec.lanes = 2}) \env -> do
    let messages = fromIntegral (knobInt context.knobs (key "kafka.messages"))
        sessionMillis = fromIntegral (knobInt context.knobs (key "kafka.prop.session.timeout.ms")) :: Int
        serviceMillis = fromIntegral (knobInt context.knobs (key "kafka.service-ms")) :: Int
        group = groupName env "zombie"
        lane0 = case env.lanes of lane :| _ -> lane
        lane1 = case env.lanes of _ :| lane : _ -> lane; _ -> error "zombie scenario requires two lanes"
    proxy <- maybe (ioError (userError "zombie scenario requires a fault proxy on lane 1")) pure lane1.laneFaults
    [topic] <- createTopics env [TopicSpec "zombie" 4 mempty]
    (acked, aRows, bRows, initialA, blackholedAt, healedAt, snapshots, reachedEnd, committedAtBlackhole) <- withCheck context \check -> withSupervisor check \supervisor -> do
      let args lane = object ["brokers" .= fmap unBrokerAddress lane.laneBrokers, "topic" .= unTopicName topic, "group" .= unConsumerGroupId group, "autoCommitMillis" .= (1000 :: Int), "sessionMillis" .= sessionMillis, "serviceMillis" .= serviceMillis]
      aSpec <- roleProcess check "kafka/crash-consumer" 0 (args lane1)
      bSpec <- roleProcess check "kafka/crash-consumer" 1 (args lane0)
      a <- spawn supervisor aSpec
      b <- spawn supervisor bSpec
      awaitReady a 10000
      awaitReady b 10000
      sendCommand a CtlStart
      sendCommand b CtlStart
      initial <- awaitAssigned a 20
      when (null initial) (ioError (userError "lane-1 consumer did not receive an initial assignment"))
      reports <- newIORef []
      producer <- async (produceOpenLoop env topic messages reports)
      threadDelay 1000000
      before <- describeGroup env group
      blackholedAt <- getCurrentTime
      setProxyMode proxy Blackhole
      _ <- resetConnections proxy
      samples <- forM [1 .. 2 * sessionMillis `div` 1000] \_ -> do
        threadDelay 1000000
        try @SomeException (describeGroup env group)
      setProxyMode proxy Forward
      _ <- resetConnections proxy
      healedAt <- getCurrentTime
      wait producer
      delivered <- reverse <$> readIORef reports
      finished <- awaitGroup env group 90 (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
      stopIfAlive supervisor a
      stopIfAlive supervisor b
      first <- readChildMessages a
      second <- readChildMessages b
      pure (delivered, first, second, initial, blackholedAt, healedAt, before : [snapshot | Right snapshot <- samples], finished, before)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let ackedIds = Set.fromList [value | P.DeliverySuccess sent _ <- acked, Just value <- [P.prValue sent >>= readInt]]
        deliveryFailures = length [() | P.DeliveryFailure _ _ <- acked]
        aFacts = okFacts aRows
        bFacts = okFacts bRows
        allFacts = aFacts <> bFacts
        handledIds = Set.fromList (fmap (.value) allFacts)
        missing = Set.toAscList (Set.difference ackedIds handledIds)
        bAssignments = [fact | fact <- rebalanceFacts bRows, fact.kind == "assign", fact.at >= blackholedAt]
        takenOver = not (null initialA) && any (\fact -> not (null (fact.partitions `intersect` initialA))) bAssignments
        committedSeries = Map.fromListWith (<>) [(partition, [committed]) | snapshot <- reverse snapshots, item <- snapshot.offsets, let PartitionId partition = item.partition, Just committed <- [item.committed]]
        regressions = [partition | (partition, values) <- Map.toList committedSeries, not (nondecreasing values)]
        beforeCommit = Map.fromList [(partition, committed) | item <- committedAtBlackhole.offsets, let PartitionId partition = item.partition, Just committed <- [item.committed]]
        uncommittedA = length [() | fact <- aFacts, fact.at <= blackholedAt, fromIntegral fact.offset >= Map.findWithDefault 0 fact.partition beforeCommit]
        duplicated = sum [count - 1 | count <- Map.elems (Map.fromListWith (+) [((fact.partition, fact.offset), 1 :: Int) | fact <- allFacts]), count > 1]
        duplicateBound = uncommittedA + 100 * length initialA
        errors = [problem | WrkError problem <- aRows <> bRows]
        (zeroLag, lastSnapshot) = case reachedEnd of Left item -> (False, item); Right item -> (True, item)
        failures =
          ["zombie-ack-count" | Set.size ackedIds /= messages || deliveryFailures > 0]
            <> ["zombie-no-loss" | not (null missing)]
            <> ["zombie-takeover" | not takenOver]
            <> ["zombie-commits-monotone" | not (null regressions)]
            <> ["zombie-duplicate-proxy-bound" | duplicated > duplicateBound]
            <> ["zombie-zero-lag" | not zeroLag]
            <> ["zombie-consumer-exit" | not (null errors)]
    putSummary context Verdicts "zombie" (object ["acknowledged" .= Set.size ackedIds, "handled" .= length allFacts, "missing" .= take 20 missing, "initialAPartitions" .= initialA, "bTookOver" .= takenOver, "commitRegressions" .= regressions, "duplicateCount" .= duplicated, "duplicateBoundEstimate" .= duplicateBound, "duplicateBoundBasis" .= ("A handler facts above the sampled commit boundary plus 100 polled records per initial A partition; exact adapter buffer occupancy is not exposed" :: Text), "consumerErrors" .= errors, "blackholedAt" .= blackholedAt, "healedAt" .= healedAt, "zeroLag" .= zeroLag])
    pure $ if null failures then passed else failedWith failures ("missing=" <> Text.pack (show (take 20 missing)) <> " takeover=" <> Text.pack (show takenOver) <> " regressions=" <> Text.pack (show regressions) <> " duplicate=" <> Text.pack (show duplicated) <> "/" <> Text.pack (show duplicateBound) <> " group=" <> Text.pack (show lastSnapshot))

produceOpenLoop :: KafkaEnv -> TopicName -> Int -> IORef [P.DeliveryReport] -> IO ()
produceOpenLoop env topic count reports = do
  let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
  result <- runEff . runError @KafkaError $
    P.runKafkaProducer props $ do
      forM_ [0 .. count - 1] \value -> do
        let record = P.ProducerRecord {P.prTopic = topic, P.prPartition = P.UnassignedPartition, P.prKey = Just (ByteString.pack (show value)), P.prValue = Just (ByteString.pack (show value)), P.prHeaders = mempty}
        _ <- P.produceMessage' record (\report -> atomicModifyIORef' reports (\old -> (report : old, ())))
        liftIO $ threadDelay 2000
      P.flushProducer
  either (ioError . userError . show) pure result

awaitAssigned :: Child -> Int -> IO [Int]
awaitAssigned child seconds = do
  result <- timeout (seconds * 1000000) loop
  pure (maybe [] id result)
  where
    loop = do
      rows <- readChildMessages child
      case [fact.partitions | fact <- rebalanceFacts rows, fact.kind == "assign"] of
        partitions : _ -> pure partitions
        [] -> threadDelay 200000 >> loop

okFacts :: [WorkerMessage] -> [OkFact]
okFacts = mapMaybe \case
  WrkCustom "ok" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

rebalanceFacts :: [WorkerMessage] -> [RebalanceFact]
rebalanceFacts = mapMaybe \case
  WrkCustom "rebalance" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
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

nondecreasing :: (Ord a) => [a] -> Bool
nondecreasing values = and (zipWith (<=) values (drop 1 values))

intersect :: (Eq a) => [a] -> [a] -> [a]
intersect left right = filter (`elem` right) left

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName
