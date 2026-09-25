module Kenshou.Suite.Kafka.Concurrency.GroupRebalance (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Monad (forM, forM_)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, TopicName (..))
import Kenshou.Check.Process (Child, Supervisor, awaitReady, killChild, readChildMessages, restartChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
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
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/group-rebalance-with-inflight"),
        revision = 1,
        summary = "Checks delivery, ordering, and exclusive ownership while a consumer group changes membership.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "kafka.consumers" "Initial group members" 3 2 4,
            intKnob "kafka.partitions" "Topic partitions" 12 2 24,
            intKnob "kafka.service-ms" "Per-record handler time" 50 0 500,
            intKnob "kafka.messages" "Open-loop produced records" 20000 1000 100000,
            intKnob "kafka.membership-interval-seconds" "Time between membership changes" 10 1 30
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4",
                summary = "Released adapter workers can end normally during consumer-group rebalances.",
                expectedFailures = ["rebalance-survivor-exit", "rebalance-no-loss", "rebalance-zero-lag"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runGroupRebalance
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int, at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "rebalance ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset" <*> v .: "at"

data RebalanceFact = RebalanceFact {kind :: Text, partitions :: [Int], at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON RebalanceFact where
  parseJSON = withObject "rebalance callback fact" \v -> RebalanceFact <$> v .: "kind" <*> v .: "partitions" <*> v .: "at"

runGroupRebalance :: RunContext -> IO ScenarioReport
runGroupRebalance context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let consumers = fromIntegral (knobInt context.knobs (key "kafka.consumers"))
        partitions = fromIntegral (knobInt context.knobs (key "kafka.partitions"))
        serviceMillis = fromIntegral (knobInt context.knobs (key "kafka.service-ms")) :: Int
        messages = fromIntegral (knobInt context.knobs (key "kafka.messages"))
        interval = fromIntegral (knobInt context.knobs (key "kafka.membership-interval-seconds")) :: Int
        drainSeconds = max 90 (2 * messages * serviceMillis `div` (max 1 consumers * 1000))
        group = groupName env "group-rebalance"
    [topic] <- createTopics env [TopicSpec "group-rebalance" partitions mempty]
    (acked, reports, timeline, snapshots) <- withCheck context \check -> withSupervisor check \supervisor -> do
      let args = object ["brokers" .= fmap unBrokerAddress (firstBrokers env), "topic" .= unTopicName topic, "group" .= unConsumerGroupId group, "autoCommitMillis" .= (1000 :: Int), "serviceMillis" .= serviceMillis]
          startMember index = do
            memberSpec <- roleProcess check "kafka/crash-consumer" index args
            member <- spawn supervisor memberSpec
            awaitReady member 10000
            sendCommand member CtlStart
            pure member
      initial <- forM [0 .. consumers - 1] startMember
      deliveryReports <- newIORef []
      producer <- async (produceOpenLoop env topic messages deliveryReports)
      threadDelay (interval * 1000000)
      joinedAt <- getCurrentTime
      fourth <- startMember consumers
      threadDelay (interval * 1000000)
      leftAt <- getCurrentTime
      first <- case initial of member : _ -> pure member; [] -> ioError (userError "rebalance requires initial members")
      _ <- stopGracefully supervisor first 10000
      threadDelay (interval * 1000000)
      killedAt <- getCurrentTime
      killChild supervisor (initial !! 1)
      threadDelay (interval * 1000000)
      restartedAt <- getCurrentTime
      replacement <- restartChild supervisor (initial !! 1)
      sendCommand replacement CtlStart
      wait producer
      result <- awaitGroup env group drainSeconds (\snapshot -> length snapshot.offsets == partitions && all ((== Just 0) . (.lag)) snapshot.offsets)
      forM_ (drop 2 initial <> [fourth, replacement]) (stopIfAlive supervisor)
      workerMessages <- forM (zip [0 :: Int ..] (initial <> [fourth, replacement])) \(index, member) -> do
        rows <- readChildMessages member
        pure (index, rows)
      delivered <- reverse <$> readIORef deliveryReports
      pure (delivered, workerMessages, [joinedAt, leftAt, killedAt, restartedAt], result)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let ackedIds = Set.fromList [value | P.DeliverySuccess sent _ <- acked, Just value <- [P.prValue sent >>= readInt]]
        deliveryFailures = length [() | P.DeliveryFailure _ _ <- acked]
        facts = [(member, fact) | (member, rows) <- reports, fact <- okFacts rows]
        seenIds = Set.fromList [fact.value | (_, fact) <- facts]
        missing = Set.toAscList (Set.difference ackedIds seenIds)
        windows = [(addUTCTime (-16) instant, addUTCTime 16 instant) | instant <- timeline]
        withinWindow instant = any (\(start, end) -> instant >= start && instant <= end) windows
        byId = Map.fromListWith (<>) [(fact.value, [fact]) | (_, fact) <- facts]
        duplicatesOutside = [value | (value, occurrences) <- Map.toList byId, length occurrences > 1, fact <- drop 1 (sortOn (.at) occurrences), not (withinWindow fact.at)]
        assignments = Map.fromList [(member, rebalanceFacts rows) | (member, rows) <- reports]
        orderedViolations =
          [ (member, partition, period)
          | (member, rows) <- reports,
            let memberFacts = okFacts rows,
            partition <- [0 .. partitions - 1],
            let assignmentTimes = [event.at | event <- Map.findWithDefault [] member assignments, event.kind == "assign", partition `elem` event.partitions],
            (period, start) <- zip [0 :: Int ..] assignmentTimes,
            let end = case drop (period + 1) assignmentTimes of next : _ -> Just next; _ -> Nothing,
            let offsets = [fact.offset | fact <- sortOn (.at) memberFacts, fact.partition == partition, fact.at >= start, maybe True (fact.at <) end],
            not (strictlyIncreasing offsets)
          ]
        ownership = Map.fromListWith Set.union [((fact.partition, floor (utcTimeToPOSIXSeconds fact.at) :: Integer), Set.singleton member) | (member, fact) <- facts, not (withinWindow fact.at)]
        overlappingOwners = [(partition, second, Set.toAscList owners) | ((partition, second), owners) <- Map.toList ownership, Set.size owners > 1]
        survivorErrors = [problem | (member, rows) <- reports, member /= 1, WrkError problem <- rows]
        (zeroLag, snapshot) = case snapshots of Left item -> (False, item); Right item -> (True, item)
        failures =
          ["rebalance-ack-count" | Set.size ackedIds /= messages || deliveryFailures > 0]
            <> ["rebalance-no-loss" | not (null missing)]
            <> ["rebalance-zero-lag" | not zeroLag]
            <> ["rebalance-duplicate-window" | not (null duplicatesOutside)]
            <> ["rebalance-assignment-order" | not (null orderedViolations)]
            <> ["rebalance-exclusive-owner" | not (null overlappingOwners)]
            <> ["rebalance-survivor-exit" | not (null survivorErrors)]
    putSummary context Verdicts "groupRebalance" (object ["acknowledged" .= Set.size ackedIds, "deliveryFailures" .= deliveryFailures, "handled" .= length facts, "missing" .= take 20 missing, "duplicateOutsideWindows" .= take 20 duplicatesOutside, "assignmentOrderViolations" .= take 20 orderedViolations, "overlappingOwners" .= take 20 overlappingOwners, "survivorErrors" .= survivorErrors, "membershipEvents" .= timeline, "zeroLag" .= zeroLag])
    pure $ if null failures then passed else failedWith failures ("missing=" <> Text.pack (show (take 20 missing)) <> " order=" <> Text.pack (show (take 20 orderedViolations)) <> " overlap=" <> Text.pack (show (take 20 overlappingOwners)) <> " group=" <> Text.pack (show snapshot))

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

okFacts :: [WorkerMessage] -> [OkFact]
okFacts = mapMaybe \case
  WrkCustom "ok" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

rebalanceFacts :: [WorkerMessage] -> [RebalanceFact]
rebalanceFacts = mapMaybe \case
  WrkCustom "rebalance" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

strictlyIncreasing :: [Int] -> Bool
strictlyIncreasing values = and (zipWith (<) values (drop 1 values))

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName

stopIfAlive :: Supervisor -> Child -> IO ()
stopIfAlive supervisor member = do
  rows <- readChildMessages member
  if any ended rows
    then pure ()
    else do
      _ <- stopGracefully supervisor member 10000
      pure ()

ended :: WorkerMessage -> Bool
ended (WrkDone _) = True
ended (WrkError _) = True
ended _ = False
