module Kenshou.Suite.Kafka.Producer.BatchFailure (scenarios) where

import Control.Exception (SomeException, finally, try)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Text qualified as Text
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (consumeValues, firstBrokers, intKnob)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/producer/concurrency/batch-loop-reports-enqueue-not-delivery"),
        revision = 1,
        summary = "Checks whether batch enqueue results prove delivery through a broker outage.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [intKnob "kafka.prop.message.timeout.ms" "Producer delivery timeout" 3000 1000 30000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge",
                summary = "produceMessageBatch reports enqueue failures, not broker delivery failures.",
                expectedFailures = ["batch-enqueue-is-delivery"],
                appliesTo = AllCohorts
              },
        run = runBatchFailure
      }
  ]

data Enqueue = Enqueue {failures :: Int, submitted :: Int}

instance FromJSON Enqueue where
  parseJSON = withObject "batch enqueue" \value -> Enqueue <$> value .: "failures" <*> value .: "submitted"

runBatchFailure :: RunContext -> IO ScenarioReport
runBatchFailure context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> case env.control of
    Nothing -> pure (failedWith ["broker-control-unavailable"] "this Kafka environment has no broker control")
    Just control -> do
      [topic] <- createTopics env [TopicSpec "batch-outage" 1 mempty]
      control.kill
      down <- not <$> control.isRunning
      let timeoutMillis = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.prop.message.timeout.ms")))
      workerResult <- (runWorker context env topic timeoutMillis) `finally` control.start
      up <- control.isRunning
      received <- consumeValues env 0 topic "batch-outage" 100
      _ <- deleteRunGroups env
      _ <- deleteRunTopics env
      let failures =
            ["broker-down-during-batch" | not down]
              <> ["broker-restarted-after-batch" | not up]
              <> case workerResult of
                Left _ -> ["batch-worker-enqueued"]
                Right (enqueue, _) ->
                  ["batch-enqueue-complete" | enqueue.submitted /= 100 || enqueue.failures /= 0]
                    <> ["batch-enqueue-is-delivery" | enqueue.submitted == 100 && enqueue.failures == 0 && sort received /= [0 .. 99]]
      pure $
        if null failures
          then passed
          else failedWith failures ("worker=" <> Text.pack (show (either Left (Right . (\(e, flushed) -> (e.failures, e.submitted, flushed))) workerResult)) <> " received=" <> Text.pack (show received) <> " down=" <> Text.pack (show down) <> " up=" <> Text.pack (show up))

runWorker :: RunContext -> KafkaEnv -> TopicName -> Int -> IO (Either String (Enqueue, Bool))
runWorker context env (TopicName topic) timeoutMillis = withCheck context \check -> withSupervisor check \supervisor -> do
  let arguments =
        object
          [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
            "topic" .= topic,
            "messages" .= (100 :: Int),
            "messageTimeoutMillis" .= timeoutMillis
          ]
  spec <- roleProcess check "kafka/batch-producer" 0 arguments
  child <- spawn supervisor spec
  awaitReady child 10000
  sendCommand child CtlStart
  awaitMark child "enqueue" 10000
  messages <- readChildMessages child
  let enqueue = case [result | WrkCustom "enqueue" value <- messages, Aeson.Success result <- [Aeson.fromJSON value :: Aeson.Result Enqueue]] of
        item : _ -> Right item
        [] -> Left "batch worker sent no parseable enqueue mark"
  flushed <- try @SomeException (awaitMark child "flushed" (timeoutMillis + 5000))
  case flushed of
    Right () -> do
      _ <- stopGracefully supervisor child 2000
      pure ()
    Left _ -> killChild supervisor child
  pure (fmap (,either (const False) (const True) flushed) enqueue)
