module Kenshou.Suite.Kafka.Benchmark.PollCap (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_, when)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import GHC.Clock (getMonotonicTimeNSec)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BatchSize (..), KafkaError, Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load.Series (closeLoadSeries, openLoadSeries, sampleLoadSeries)
import Kenshou.Measure.Phase (Phase (..), enterPhase)
import Kenshou.Measure.Recorder (OpName (..), OpResult (..), newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (measureConfigFromKnobs, measurementPhaseClock, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kafka.Fixture (firstBrokers)
import Shibuya.Adapter.Kafka.Config (defaultConfig)
import Shibuya.Adapter.Kafka.Config qualified as AdapterConfig
import Shibuya.Adapter.Kafka.Internal (kafkaSource, newKafkaAdapterState)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/benchmark/poll-cap-latency"),
        revision = 1,
        summary = "Measures the released adapter source poll cap with intended-time arrivals and broker acknowledgements.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "kafka.rate-per-second" 1000 1 5000,
            intKnob "kafka.poll-timeout-ms" 1000 50 5000,
            intKnob "kafka.batch-size" 100 1 1000,
            intKnob "kafka.messages" 1000 10 100000
          ]
            <> measureKnobs Benchmark,
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runPollCap
      }
  ]

runPollCap :: RunContext -> IO ScenarioReport
runPollCap context = case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
  Left reason -> pure (failedWith ["invalid-measure-config"] reason)
  Right measureConfig -> do
    spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
    withKafkaEnv context spec \env -> do
      [topic] <- createTopics env [TopicSpec "poll-cap" 1 mempty]
      let count = fromIntegral (knobInt context.knobs (name "kafka.messages"))
          rate = fromIntegral (knobInt context.knobs (name "kafka.rate-per-second")) :: Double
          batch = fromIntegral (knobInt context.knobs (name "kafka.batch-size"))
          pollMillis = fromIntegral (knobInt context.knobs (name "kafka.poll-timeout-ms"))
          config = (defaultConfig [topic]) {AdapterConfig.batchSize = BatchSize batch, AdapterConfig.pollTimeout = Timeout pollMillis}
          group = groupName env "poll-cap"
      ((producerOutcome, consumerOutcome), _) <- withMeasurement context measureConfig \measurement -> do
        handle <- registerOp (measurementRecorder measurement) (OpName "intended-to-poll") >>= flip newWorkerRecorder 0
        offered <- newIORef 0
        completed <- newIORef 0
        failed <- newIORef 0
        maxLag <- newIORef 0
        series <- openLoadSeries measurement
        enterPhase (measurementPhaseClock measurement) Steady
        sampleLoadSeries series measurement offered offered completed failed maxLag
        origin <- getMonotonicTimeNSec
        let produce = do
              acked <- newIORef (0 :: Int)
              let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
              result <- runEff . runError @KafkaError $ P.runKafkaProducer props $ do
                forM_ [0 .. count - 1] \index -> do
                  let intended = origin + floor (fromIntegral index * 1e9 / rate)
                  now <- liftIO getMonotonicTimeNSec
                  when (now < intended) (liftIO (threadDelay (fromIntegral ((intended - now) `div` 1000))))
                  P.produceMessage' (record topic index intended) \report -> case report of
                    P.DeliverySuccess _ _ -> atomicModifyIORef' acked (\old -> (old + 1, ()))
                    _ -> pure ()
                P.flushProducer
              delivered <- readIORef acked
              pure (result, delivered)
            consume = timeout (max 20000000 (ceiling (fromIntegral count / rate * 1e6) + 20000000)) do
              state <- newKafkaAdapterState
              let props = C.brokersList (firstBrokers env) <> C.groupId group <> C.noAutoOffsetStore
                  subscription = C.topics [topic] <> C.offsetReset C.Earliest
              runEff . runError @KafkaError $ C.runKafkaConsumer props subscription $ do
                let observe candidate = case candidate of
                      Left _ -> pure Nothing
                      Right row -> do
                        arrived <- liftIO getMonotonicTimeNSec
                        C.commitOffsetMessage C.OffsetCommit row
                        case C.crValue row >>= parseValue of
                          Nothing -> pure Nothing
                          Just (number, intended) -> do
                            liftIO $ recordOp handle intended arrived arrived (OpOk 1)
                            pure (Just number)
                Stream.fold Fold.toList (Stream.mapM observe (Stream.take count (kafkaSource state config)))
        outcomes <- concurrently produce consume
        writeIORef offered (fromIntegral count)
        writeIORef completed (fromIntegral count)
        enterPhase (measurementPhaseClock measurement) Drain
        sampleLoadSeries series measurement offered offered completed failed maxLag
        closeLoadSeries series
        pure outcomes
      snapshot <- describeGroup env group
      _ <- deleteRunGroups env
      _ <- deleteRunTopics env
      let produced = case producerOutcome of (Right (), delivered) -> delivered; _ -> 0
          observed = case consumerOutcome of Just (Right rows) -> [value | Just value <- rows]; _ -> []
          expected = Set.fromList [0 .. count - 1]
          failures =
            ["poll-cap-producer-ack" | produced /= count]
              <> ["poll-cap-no-loss" | Set.fromList observed /= expected || length observed /= count]
              <> ["poll-cap-zero-lag" | length snapshot.offsets /= 1 || any ((/= Just 0) . (.lag)) snapshot.offsets]
      putSummary context Verdicts "pollCap" (object ["produced" .= produced, "observed" .= length observed, "batchSize" .= batch, "requestedPollTimeoutMs" .= pollMillis, "effectivePollCapMs" .= (min 100 pollMillis), "ratePerSecond" .= rate, "consumerCompleted" .= (case consumerOutcome of Just (Right _) -> True; _ -> False)])
      pure $ if null failures then passed else failedWith failures ("produced=" <> Text.pack (show produced) <> " observed=" <> Text.pack (show (length observed)))

record :: TopicName -> Int -> Word64 -> P.ProducerRecord
record topic index intended =
  P.ProducerRecord topic (P.SpecifiedPartition 0) (Just (ByteString.pack (show index))) (Just (ByteString.pack (show index <> ":" <> show intended))) mempty

parseValue :: ByteString.ByteString -> Maybe (Int, Word64)
parseValue bytes = case ByteString.split ':' bytes of
  [index, intended] -> (,) <$> readMaybeInt index <*> readMaybeInt intended
  _ -> Nothing

readMaybeInt :: (Read a) => ByteString.ByteString -> Maybe a
readMaybeInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []
