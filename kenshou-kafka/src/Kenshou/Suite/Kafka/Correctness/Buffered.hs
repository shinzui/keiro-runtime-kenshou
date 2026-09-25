module Kenshou.Suite.Kafka.Correctness.Buffered (scenarios) where

import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (BatchSize (..), KafkaError, TopicName)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, produceValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/buffered-successors-run-before-retry"),
        revision = 1,
        summary = "Retries offset 3 and checks that buffered successors wait before their handlers succeed.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [KnobSpec (either (error . Text.unpack) id (mkKnobName "kafka.batch-size")) "Adapter poll batch size" KnobInt (VInt 100) (OneOf (VInt 1 :| [VInt 10, VInt 100, VInt 1000])) []],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-2",
                summary = "Buffered successor handlers run before the failed offset is redelivered.",
                expectedFailures = ["buffered-successor-order"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runBuffered
      }
  ]

runBuffered :: RunContext -> IO ScenarioReport
runBuffered context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "buffered" 1 mempty]
    _ <- produceValues env topic [0 .. 9]
    deliveries <- newIORef []
    successes <- newIORef []
    let batchSize = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.batch-size")))
    result <- timeout 20000000 (consumeBuffered env topic batchSize deliveries successes)
    seen <- reverse <$> readIORef deliveries
    oks <- reverse <$> readIORef successes
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let failures =
          ["buffered-run-completed" | result /= Just ()]
            <> ["buffered-retry-redelivered" | length (filter (== 3) seen) < 2]
            <> ["buffered-success-coverage" | sort oks /= [0 .. 9]]
            <> ["buffered-successor-order" | oks /= [0 .. 9]]
    pure $
      if null failures
        then passed
        else failedWith failures ("deliveries=" <> Text.pack (show seen) <> " successes=" <> Text.pack (show oks))

consumeBuffered :: KafkaEnv -> TopicName -> Int -> IORef [Int] -> IORef [Int] -> IO ()
consumeBuffered env topic batchSize deliveries successes = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "buffered") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter ((defaultConfig [topic]) {batchSize = BatchSize batchSize})
      let finiteAdapter = adapter {source = Stream.take 11 adapter.source}
          handler Message {envelope = Envelope {payload}} = case payload >>= readInt of
            Nothing -> pure AckOk
            Just value -> do
              previous <- liftIO $ atomicModifyIORef' deliveries (\old -> (value : old, length (filter (== value) old)))
              if value == 3 && previous == 0
                then pure (AckRetry (RetryDelay 0))
                else do
                  liftIO $ modifyIORef' successes (value :)
                  pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "buffered", mkProcessor finiteAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure outcome

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing
