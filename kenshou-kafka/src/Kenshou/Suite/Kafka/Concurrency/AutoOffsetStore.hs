module Kenshou.Suite.Kafka.Concurrency.AutoOffsetStore (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..), Offset (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/auto-offset-store-loses-on-crash"),
        revision = 1,
        summary = "Checks an interrupted handler against automatic and manual offset-store modes.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [intKnob "kafka.prop.auto.commit.interval.ms" "Auto-commit interval in milliseconds" 1000 100 10000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs",
                summary = "Automatic offset storage can commit an unacknowledged batch after a worker crash.",
                expectedFailures = ["auto-offset-store-loses-on-crash"],
                appliesTo = AllCohorts
              },
        run = runAutoOffsetStore
      }
  ]

runAutoOffsetStore :: RunContext -> IO ScenarioReport
runAutoOffsetStore context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "auto-offset-store" 1 mempty]
    _ <- produceValues env topic [0 .. 99]
    let interval = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.prop.auto.commit.interval.ms")))
    (automaticCommitted, automaticLogEnd, automaticResume) <- crashBlocked context env topic "automatic" True interval 0
    (manualCommitted, manualLogEnd, manualResume) <- crashBlocked context env topic "manual" False interval 1
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    putSummary context Verdicts "autoOffsetStore" (object ["automaticCommitted" .= automaticCommitted, "automaticLogEnd" .= automaticLogEnd, "automaticResume" .= automaticResume, "manualCommitted" .= manualCommitted, "manualLogEnd" .= manualLogEnd, "manualResume" .= manualResume, "blockedOffset" .= (10 :: Int)])
    let note = "automatic=" <> Text.pack (show (automaticCommitted, automaticLogEnd, automaticResume)) <> " manual=" <> Text.pack (show (manualCommitted, manualLogEnd, manualResume))
    pure $
      if manualResume /= Just 10 || maybe False (> 10) manualCommitted
        then failedWith ["manual-offset-store-control"] note
        else
          if maybe False (> 10) automaticCommitted && (maybe False (> 10) automaticResume || (automaticResume == Nothing && automaticCommitted == Just automaticLogEnd))
            then failedWith ["auto-offset-store-loses-on-crash"] note
            else
              if automaticResume == Just 10
                then passed
                else failedWith ["auto-offset-store-inconsistent"] note

crashBlocked :: RunContext -> KafkaEnv -> TopicName -> Text.Text -> Bool -> Int -> Int -> IO (Maybe Int, Int, Maybe Int)
crashBlocked context env (TopicName topic) suffix autoStore interval index = do
  let group = groupName env ("offset-store-" <> suffix)
      args =
        object
          [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
            "topic" .= topic,
            "group" .= unConsumerGroupId group,
            "autoCommitMillis" .= interval,
            "autoOffsetStore" .= autoStore,
            "blockOffset" .= (10 :: Int),
            "blockMillis" .= (5 * interval + 5000)
          ]
  withCheck context \check -> withSupervisor check \supervisor -> do
    workerSpec <- roleProcess check "kafka/crash-consumer" index args
    worker <- spawn supervisor workerSpec
    awaitReady worker 10000
    sendCommand worker CtlStart
    awaitMark worker "entered-block" 30000
    threadDelay (3 * interval * 1000)
    killChild supervisor worker
    snapshot <- describeGroup env group
    resumed <- firstOnResume env (TopicName topic) group
    case snapshot.offsets of
      [item] -> pure (fromIntegral <$> item.committed, fromIntegral item.logEnd, resumed)
      _ -> ioError (userError "offset-store probe did not find exactly one partition")

firstOnResume :: KafkaEnv -> TopicName -> ConsumerGroupId -> IO (Maybe Int)
firstOnResume env topic group = do
  let props = C.brokersList (firstBrokers env) <> C.groupId group <> C.noAutoCommit <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (poll 0)
  either (ioError . userError . show) pure result
  where
    poll (attempts :: Int)
      | attempts >= 10 = pure Nothing
      | otherwise = do
          candidate <- C.pollMessage (Timeout 1000)
          case candidate of
            Nothing -> poll (attempts + 1)
            Just record -> pure (Just (fromIntegral (unOffset (C.crOffset record))))
