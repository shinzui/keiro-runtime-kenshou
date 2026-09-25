module Kenshou.Suite.Kafka.Correctness.DeadLetter (scenarios) where

import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import Kenshou.Suite.Kafka.Roles (adapterConsumerRole)
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/dead-letter-drops-record"),
        revision = 1,
        summary = "Checks that AckDeadLetter drops poison records with exactly one warning each.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [intKnob "kafka.poison-count" "Dead-lettered messages" 5 1 50],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runDeadLetter
      }
  ]

data DeadSummary = DeadSummary {ok :: [Int], dropped :: [Int]}

instance FromJSON DeadSummary where
  parseJSON = withObject "dead-letter summary" \value -> DeadSummary <$> value .: "ok" <*> value .: "dropped"

runDeadLetter :: RunContext -> IO ScenarioReport
runDeadLetter context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let poisonCount = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.poison-count")))
    [topic] <- createTopics env [TopicSpec "dead-letter" 1 mempty]
    sent <- produceValues env topic [0 .. 199]
    summary <- withWorker context adapterConsumerRole "dead-letter" (workerArgs env topic poisonCount) \worker -> do
      ready <- worker.receive 10000
      case ready of
        Just WrkReady -> do
          worker.send CtlStart
          reply <- worker.receive 30000
          pure $ case reply of
            Just (WrkCustom "summary" value) -> case Aeson.fromJSON value :: Aeson.Result DeadSummary of
              Aeson.Success result -> Right result
              Aeson.Error problem -> Left problem
            Just (WrkError problem) -> Left (Text.unpack problem)
            other -> Left ("adapter worker returned " <> show other)
        other -> pure (Left ("adapter worker did not become ready: " <> show other))
    logText <- readFile (context.outDir </> "logs" </> "worker-dead-letter.stderr.log")
    snapshot <- describeGroup env (groupName env "dead-letter")
    resumed <- countOnResume env topic
    _ <- deleteRunGroups env
    deletedTopics <- deleteRunTopics env
    let warnings = filter (Text.isInfixOf "dead-lettered message DROPPED") (Text.lines (Text.pack logText))
        okIds = either (const []) (.ok) summary
        droppedIds = either (const []) (.dropped) summary
        summaryText = either Text.pack (\s -> Text.pack (show (length s.ok, length s.dropped))) summary
        lagZero = length snapshot.offsets == 1 && all ((== Just 0) . (.lag)) snapshot.offsets
        good = length sent == 200 && sort okIds == [poisonCount .. 199] && sort droppedIds == [0 .. poisonCount - 1] && length warnings == poisonCount && lagZero && resumed == 0 && deletedTopics == 1
    putSummary context Verdicts "dead-letter" (object ["documentedLoss" .= length droppedIds, "warningCount" .= length warnings])
    pure $
      if good
        then passed
        else failedWith ["dead-letter-drops-record"] ("worker=" <> summaryText <> " warnings=" <> Text.pack (show warnings) <> " snapshot=" <> Text.pack (show snapshot) <> " resumed=" <> Text.pack (show resumed) <> " deletedTopics=" <> Text.pack (show deletedTopics))

workerArgs :: KafkaEnv -> TopicName -> Int -> Aeson.Value
workerArgs env (TopicName topic) poisonCount =
  object
    [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
      "topic" .= topic,
      "group" .= unConsumerGroupId (groupName env "dead-letter"),
      "messages" .= (200 :: Int),
      "poisonCount" .= poisonCount
    ]

countOnResume :: KafkaEnv -> TopicName -> IO Int
countOnResume env topic = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "dead-letter") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription $ do
    value <- C.pollMessage (Timeout 5000)
    pure (maybe 0 (const 1) value)
  either (ioError . userError . show) pure result
