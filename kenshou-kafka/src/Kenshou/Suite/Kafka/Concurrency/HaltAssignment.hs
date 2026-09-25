module Kenshou.Suite.Kafka.Concurrency.HaltAssignment (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Check.Process (Child, awaitMark, awaitReady, killChild, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobName, knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/halt-holds-assignment-past-max-poll-interval"),
        revision = 1,
        summary = "Checks whether an open halted consumer releases its partition by max.poll.interval.ms.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "kafka.prop.max.poll.interval.ms" "Maximum poll interval in milliseconds" 10000 6000 60000,
            intKnob "kafka.prop.session.timeout.ms" "Session timeout in milliseconds" 6000 6000 30000
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2",
                summary = "A halted adapter keeps polling and holds its assignment while the consumer remains open.",
                expectedFailures = ["halt-assignment-not-evicted"],
                appliesTo = AllCohorts
              },
        run = runHaltAssignment
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "halt assignment ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset"

runHaltAssignment :: RunContext -> IO ScenarioReport
runHaltAssignment context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "halt-assignment" 1 mempty]
    _ <- produceValues env topic [0 .. 99]
    let maxPollMillis = fromIntegral (knobInt context.knobs (key "kafka.prop.max.poll.interval.ms"))
        sessionMillis = fromIntegral (knobInt context.knobs (key "kafka.prop.session.timeout.ms"))
        group = groupName env "halt-assignment"
        aArgs = workerArgs env topic group (Just 10) True maxPollMillis sessionMillis
        bArgs = workerArgs env topic group Nothing False maxPollMillis sessionMillis
    (before, atDeadline, handledWhileAlive, handledAfterKill, aliveMillis, aErrors, zeroLag) <- withCheck context \check -> withSupervisor check \supervisor -> do
      aSpec <- roleProcess check "kafka/crash-consumer" 0 aArgs
      bSpec <- roleProcess check "kafka/crash-consumer" 1 bArgs
      a <- spawn supervisor aSpec
      awaitReady a 10000
      sendCommand a CtlStart
      awaitMark a "halted" 20000
      threadDelay 1000000
      haltSnapshot <- describeGroup env group
      b <- spawn supervisor bSpec
      awaitReady b 10000
      sendCommand b CtlStart
      joinedAt <- getCurrentTime
      let deadlineMillis = maxPollMillis + sessionMillis + 10000
      threadDelay (deadlineMillis * 1000)
      deadlineAt <- getCurrentTime
      deadlineSnapshot <- describeGroup env group
      whileAlive <- okFacts <$> readChildMessages b
      aMessages <- readChildMessages a
      killChild supervisor a
      replay <- awaitValue b 10 (sessionMillis + 10000)
      lag <- awaitGroup env group 20 (\snapshot -> length snapshot.offsets == 1 && all ((== Just 0) . (.lag)) snapshot.offsets)
      _ <- stopGracefully supervisor b 5000
      pure (haltSnapshot, deadlineSnapshot, any ((== 10) . (.value)) whileAlive, replay, round (realToFrac (diffUTCTime deadlineAt joinedAt) * (1000 :: Double)) :: Int, [message | WrkError message <- aMessages], either (const False) (const True) lag)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let beforeBoundary = case before.offsets of [item] -> item.committed; _ -> Nothing
        lagAtDeadline = case atDeadline.offsets of [item] -> item.lag; _ -> Nothing
        safe = beforeBoundary == Just 10 && handledAfterKill && zeroLag && null aErrors
        failures =
          ["halt-redelivery-after-kill" | not safe]
            <> ["halt-assignment-not-evicted" | safe && not handledWhileAlive]
    putSummary context Verdicts "haltAssignment" (object ["heldMillis" .= aliveMillis, "lagAtDeadline" .= lagAtDeadline, "committedBeforeJoin" .= beforeBoundary, "handledWhileHaltedConsumerAlive" .= handledWhileAlive, "handledAfterKill" .= handledAfterKill, "zeroLag" .= zeroLag, "pollingAdr" .= ("mori://shinzui/keiro/okf/adrs/concepts/ADR-11" :: Text)])
    pure $
      if null failures
        then passed
        else failedWith failures ("before=" <> Text.pack (show before) <> " atDeadline=" <> Text.pack (show atDeadline) <> " whileAlive=" <> Text.pack (show handledWhileAlive) <> " afterKill=" <> Text.pack (show handledAfterKill) <> " aErrors=" <> Text.pack (show aErrors))

workerArgs :: KafkaEnv -> TopicName -> ConsumerGroupId -> Maybe Int -> Bool -> Int -> Int -> Value
workerArgs env (TopicName topic) (ConsumerGroupId group) haltOffset holdAfterHalt maxPollMillis sessionMillis =
  object
    [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
      "topic" .= topic,
      "group" .= group,
      "autoCommitMillis" .= (1000 :: Int),
      "haltOffset" .= haltOffset,
      "holdAfterHalt" .= holdAfterHalt,
      "maxPollMillis" .= maxPollMillis,
      "sessionMillis" .= sessionMillis
    ]

awaitValue :: Child -> Int -> Int -> IO Bool
awaitValue child target timeoutMillis = do
  result <- timeout (timeoutMillis * 1000) loop
  pure (maybe False id result)
  where
    loop = do
      facts <- okFacts <$> readChildMessages child
      if any ((== target) . (.value)) facts then pure True else threadDelay 100000 >> loop

okFacts :: [WorkerMessage] -> [OkFact]
okFacts = mapMaybe \case
  WrkCustom "ok" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName
