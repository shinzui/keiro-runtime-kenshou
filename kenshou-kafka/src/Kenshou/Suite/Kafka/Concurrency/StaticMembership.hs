module Kenshou.Suite.Kafka.Concurrency.StaticMembership (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Check.Process (Child, awaitReady, killChild, readChildMessages, restartChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/consumer/concurrency/static-membership-restart-without-revoke"),
        revision = 1,
        summary = "Checks that a static member's quick restart keeps the surviving member's assignment.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [intKnob "kafka.prop.session.timeout.ms" "Static member session timeout in milliseconds" 10000 6000 30000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runStaticMembership
      }
  ]

data RebalanceFact = RebalanceFact {kind :: Text, partitions :: [Int], at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON RebalanceFact where
  parseJSON = withObject "rebalance fact" \v -> RebalanceFact <$> v .: "kind" <*> v .: "partitions" <*> v .: "at"

data RecordFact = RecordFact {partition :: Int, offset :: Int, at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON RecordFact where
  parseJSON = withObject "record fact" \v -> RecordFact <$> v .: "partition" <*> v .: "offset" <*> v .: "at"

runStaticMembership :: RunContext -> IO ScenarioReport
runStaticMembership context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "static-membership" 4 mempty]
    _ <- produceValues env topic [0 .. 39]
    let sessionMillis = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.prop.session.timeout.ms")))
        group = groupName env "static-membership"
    (oldAssignment, newAssignment, bRevokes, firstRecord, lagZero) <- withCheck context \check -> withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "kafka/raw-consumer" 0 (workerArgs env topic group "member-a" sessionMillis)
      secondSpec <- roleProcess check "kafka/raw-consumer" 1 (workerArgs env topic group "member-b" sessionMillis)
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      _ <- awaitAssignment first 4 20000
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      old <- awaitAssignment first 2 20000
      _ <- awaitAssignment second 2 20000
      killedAt <- getCurrentTime
      killChild supervisor first
      threadDelay 3000000
      replacement <- restartChild supervisor first
      sendCommand replacement CtlStart
      new <- awaitAssignment replacement 2 20000
      _ <- produceValues env topic [40 .. 79]
      received <- awaitRecord replacement 20000
      secondEvents <- rebalanceFacts <$> readChildMessages second
      lagResult <- awaitGroup env group 20 (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
      _ <- stopGracefully supervisor replacement 5000
      _ <- stopGracefully supervisor second 5000
      let revokes = [event | event <- secondEvents, event.at >= killedAt, event.at <= received.at, event.kind `elem` ["before-revoke", "revoke"]]
      pure (old.partitions, new.partitions, revokes, received, either (const False) (const True) lagResult)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let sameAssignment = sort oldAssignment == sort newAssignment && length oldAssignment == 2
        recordOnAssignment = firstRecord.partition `elem` newAssignment
        failures =
          ["static-member-assignment-changed" | not sameAssignment]
            <> ["static-member-survivor-revoked" | not (null bRevokes)]
            <> ["static-member-did-not-resume" | not recordOnAssignment]
            <> ["static-member-lag" | not lagZero]
    putSummary context Verdicts "staticMembership" (object ["before" .= oldAssignment, "after" .= newAssignment, "survivorRevokes" .= length bRevokes, "firstRecordPartition" .= firstRecord.partition, "firstRecordOffset" .= firstRecord.offset, "lagZero" .= lagZero])
    pure $
      if null failures
        then passed
        else failedWith failures ("before=" <> Text.pack (show oldAssignment) <> " after=" <> Text.pack (show newAssignment) <> " survivorRevokes=" <> Text.pack (show bRevokes) <> " first=" <> Text.pack (show firstRecord) <> " lagZero=" <> Text.pack (show lagZero))

workerArgs :: KafkaEnv -> TopicName -> ConsumerGroupId -> Text -> Int -> Value
workerArgs env (TopicName topic) (ConsumerGroupId group) suffix sessionMillis =
  object
    [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
      "topic" .= topic,
      "group" .= group,
      "instanceId" .= unConsumerGroupId (groupName env suffix),
      "sessionMillis" .= sessionMillis
    ]

awaitAssignment :: Child -> Int -> Int -> IO RebalanceFact
awaitAssignment child count timeoutMillis = do
  result <- timeout (timeoutMillis * 1000) loop
  maybe (ioError (userError ("static member did not receive " <> show count <> " partitions"))) pure result
  where
    loop = do
      messages <- readChildMessages child
      case [fact | fact <- rebalanceFacts messages, fact.kind == "assign", length fact.partitions == count] of
        [] -> threadDelay 100000 >> loop
        values -> pure (last values)

awaitRecord :: Child -> Int -> IO RecordFact
awaitRecord child timeoutMillis = do
  result <- timeout (timeoutMillis * 1000) loop
  maybe (ioError (userError "restarted static member did not receive a record")) pure result
  where
    loop = do
      messages <- readChildMessages child
      case mapMaybe recordFact messages of
        [] -> threadDelay 100000 >> loop
        value : _ -> pure value

rebalanceFacts :: [WorkerMessage] -> [RebalanceFact]
rebalanceFacts messages = mapMaybe rebalanceFact messages

rebalanceFact :: WorkerMessage -> Maybe RebalanceFact
rebalanceFact (WrkCustom name value)
  | name `elem` ["assigned", "rebalance"] = case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
rebalanceFact _ = Nothing

recordFact :: WorkerMessage -> Maybe RecordFact
recordFact (WrkCustom "record" value) = case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
recordFact _ = Nothing
