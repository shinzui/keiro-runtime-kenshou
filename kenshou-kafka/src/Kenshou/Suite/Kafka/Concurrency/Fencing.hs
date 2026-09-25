module Kenshou.Suite.Kafka.Concurrency.Fencing (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Check.Process (Child, awaitMark, awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/consumer/concurrency/static-membership-fencing-is-observable"),
        revision = 1,
        summary = "Checks whether the original static member reports a fatal error and exits when fenced.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [intKnob "kafka.prop.session.timeout.ms" "Static member session timeout in milliseconds" 6000 6000 30000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically",
                summary = "The Hackage binding leaves a fenced adapter consumer alive on an empty poll queue.",
                expectedFailures = ["fenced-member-still-alive-and-idle"],
                appliesTo = OnlyWhen (ResolvedFromHackage "hw-kafka-client" :| [])
              },
        run = runFencing
      }
  ]

runFencing :: RunContext -> IO ScenarioReport
runFencing context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "fencing" 1 mempty]
    _ <- produceValues env topic [0 .. 9]
    let group = groupName env "fencing"
        instanceId = unConsumerGroupId (groupName env "fenced-member")
        sessionMillis = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.prop.session.timeout.ms")))
        args =
          object
            [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
              "topic" .= unTopicName topic,
              "group" .= unConsumerGroupId group,
              "autoCommitMillis" .= (1000 :: Int),
              "instanceId" .= instanceId
            ]
    (messages, replacementHandled) <- withCheck context \check -> withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "kafka/crash-consumer" 0 args
      secondSpec <- roleProcess check "kafka/crash-consumer" 1 args
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      awaitMark first "ok" 20000
      _ <- awaitGroup env group 15 (\snapshot -> length snapshot.offsets == 1 && all ((== Just 0) . (.lag)) snapshot.offsets)
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      _ <- produceValues env topic [10 .. 19]
      replacement <- timeout 20000000 (awaitMark second "ok" 19000)
      finalMessages <- awaitWorkerEnd first (sessionMillis + 15000)
      _ <- stopGracefully supervisor second 5000
      if any isDone finalMessages
        then pure ()
        else do
          _ <- stopGracefully supervisor first 5000
          pure ()
      pure (finalMessages, replacement == Just ())
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let errors = [message | WrkError message <- messages]
        fatal = any (Text.isInfixOf "RdKafkaRespErrFatal") errors
        exited = any isDone messages
        failures =
          ["fencing-replacement-did-not-handle" | not replacementHandled]
            <> ["fencing-unexpected-error" | not (null errors) && not fatal]
            <> ["fenced-member-still-alive-and-idle" | replacementHandled && null errors && not exited]
            <> ["fencing-fatal-not-observable" | replacementHandled && not (fatal && exited) && (not (null errors) || exited)]
    putSummary context Verdicts "fencing" (object ["replacementHandled" .= replacementHandled, "fatalObserved" .= fatal, "originalExited" .= exited, "errors" .= errors])
    pure $
      if null failures
        then passed
        else failedWith failures ("replacementHandled=" <> Text.pack (show replacementHandled) <> " fatal=" <> Text.pack (show fatal) <> " exited=" <> Text.pack (show exited) <> " errors=" <> Text.pack (show errors))

awaitWorkerEnd :: Child -> Int -> IO [WorkerMessage]
awaitWorkerEnd child timeoutMillis = do
  result <- timeout (timeoutMillis * 1000) loop
  maybe (readChildMessages child) pure result
  where
    loop = do
      messages <- readChildMessages child
      if any isDone messages then pure messages else threadDelay 100000 >> loop

isDone :: WorkerMessage -> Bool
isDone (WrkDone _) = True
isDone _ = False
