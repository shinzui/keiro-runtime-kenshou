module Kenshou.Suite.Kafka.Producer (scenarios) where

import Control.Monad (forM)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (Offset (..))
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (KafkaError, TopicName)
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (consumeValues, firstBrokers, produceValues)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/producer/correctness/acked-offsets-and-batch-loop"),
        revision = 1,
        summary = "Checks acknowledged offsets, batch enqueue, and delivery callbacks against a broker.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runModes
      }
  ]

runModes :: RunContext -> IO ScenarioReport
runModes context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "producer-modes" 1 mempty]
    synchronous <- produceValues env topic [0 .. 9]
    reports <- newIORef []
    let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
    result <- runEff . runError @KafkaError $ P.runKafkaProducer props $ do
      failedEnqueues <- P.produceMessageBatch (fmap (record topic) [10 .. 1009])
      P.flushProducer
      _ <- forM [1010 .. 1019] \number ->
        P.produceMessage' (record topic number) (\report -> atomicModifyIORef' reports (\old -> (report : old, ())))
      P.flushProducer
      pure failedEnqueues
    failedEnqueues <- either (ioError . userError . show) pure result
    delivered <- readIORef reports
    received <- consumeValues env 0 topic "producer-modes" 1020
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let syncOffsets = fmap unOffset synchronous
        successes = [value | P.DeliverySuccess sent _ <- delivered, Just value <- [P.prValue sent >>= readInt]]
        passedChecks = syncOffsets == [0 .. 9] && null failedEnqueues && sort successes == [1010 .. 1019] && sort received == [0 .. 1019]
    pure $
      if passedChecks
        then passed
        else failedWith ["acked-offsets-and-batch-loop"] ("syncOffsets=" <> Text.pack (show syncOffsets) <> " failedEnqueues=" <> Text.pack (show (length failedEnqueues)) <> " callbackSuccesses=" <> Text.pack (show (length successes)) <> " received=" <> Text.pack (show (length received)))

record :: TopicName -> Int -> P.ProducerRecord
record topic value =
  P.ProducerRecord
    { P.prTopic = topic,
      P.prPartition = P.SpecifiedPartition 0,
      P.prKey = Just (ByteString.pack (show value)),
      P.prValue = Just (ByteString.pack (show value)),
      P.prHeaders = mempty
    }

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of
  [(value, "")] -> Just value
  _ -> Nothing
