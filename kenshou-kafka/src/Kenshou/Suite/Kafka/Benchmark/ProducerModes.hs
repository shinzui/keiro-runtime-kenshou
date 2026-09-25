module Kenshou.Suite.Kafka.Benchmark.ProducerModes (scenarios) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import GHC.Clock (getMonotonicTimeNSec)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (KafkaError, Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load.Series (closeLoadSeries, openLoadSeries, sampleLoadSeries)
import Kenshou.Measure.Phase (Phase (..), enterPhase)
import Kenshou.Measure.Recorder (OpName (..), OpResult (..), newWorkerRecorder, recordDuration, registerOp)
import Kenshou.Measure.Session (measureConfigFromKnobs, measurementPhaseClock, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kafka.Fixture (firstBrokers)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/producer/benchmark/produce-modes"),
        revision = 1,
        summary = "Measures sync acknowledgements, asynchronous enqueue and flush, batch-loop, and delivery callbacks against a private broker.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ choice "kafka.produce-mode" "sync" ["async-flush", "batch-loop", "callback"],
            intKnob "kafka.messages" 1000 10 1000000,
            intKnob "kafka.payload-bytes" 100 16 16384,
            intKnob "kafka.prop.linger.ms" 0 0 1000,
            choice "kafka.prop.acks" "all" ["1", "0"],
            choice "kafka.prop.enable.idempotence" "false" ["true"]
          ]
            <> measureKnobs Benchmark,
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runProducerModes
      }
  ]

runProducerModes :: RunContext -> IO ScenarioReport
runProducerModes context = case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
  Left reason -> pure (failedWith ["invalid-measure-config"] reason)
  Right measureConfig -> do
    spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
    withKafkaEnv context spec \env -> do
      [topic] <- createTopics env [TopicSpec "producer-benchmark" 1 mempty]
      let mode = knobText context.knobs (name "kafka.produce-mode")
          count = fromIntegral (knobInt context.knobs (name "kafka.messages"))
          payloadBytes = fromIntegral (knobInt context.knobs (name "kafka.payload-bytes"))
          records = fmap (makeRecord topic payloadBytes) [0 .. count - 1]
          props =
            P.brokersList (firstBrokers env)
              <> P.extraProp "acks" (knobText context.knobs (name "kafka.prop.acks"))
              <> P.extraProp "linger.ms" (Text.pack (show (knobInt context.knobs (name "kafka.prop.linger.ms"))))
              <> P.extraProp "enable.idempotence" (knobText context.knobs (name "kafka.prop.enable.idempotence"))
      callbacks <- newIORef (0 :: Int)
      ((started, ended, enqueueFailures), _) <- withMeasurement context measureConfig \measurement -> do
        let recorder = measurementRecorder measurement
        ack <- registerOp recorder (OpName "broker-ack") >>= flip newWorkerRecorder 0
        enqueue <- registerOp recorder (OpName "enqueue") >>= flip newWorkerRecorder 0
        flush <- registerOp recorder (OpName "flush") >>= flip newWorkerRecorder 0
        offered <- newIORef 0
        completed <- newIORef 0
        failed <- newIORef 0
        maxLag <- newIORef 0
        loadSeries <- openLoadSeries measurement
        enterPhase (measurementPhaseClock measurement) Steady
        sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
        started <- getMonotonicTimeNSec
        result <- runEff . runError @KafkaError $ P.runKafkaProducer props $ case mode of
          "sync" -> do
            forM_ records \record -> do
              before <- liftIO getMonotonicTimeNSec
              _ <- P.produceMessageSync record
              after <- liftIO getMonotonicTimeNSec
              liftIO $ recordDuration ack after (after - before) (OpOk 1)
            pure (0 :: Int)
          "async-flush" -> do
            forM_ records \record -> do
              before <- liftIO getMonotonicTimeNSec
              P.produceMessage record
              after <- liftIO getMonotonicTimeNSec
              liftIO $ recordDuration enqueue after (after - before) (OpOk 1)
            before <- liftIO getMonotonicTimeNSec
            P.flushProducer
            after <- liftIO getMonotonicTimeNSec
            liftIO $ recordDuration flush after (after - before) (OpOk count)
            pure 0
          "batch-loop" -> do
            before <- liftIO getMonotonicTimeNSec
            failures <- P.produceMessageBatch records
            after <- liftIO getMonotonicTimeNSec
            liftIO $ recordDuration enqueue after (after - before) (OpOk (count - length failures))
            beforeFlush <- liftIO getMonotonicTimeNSec
            P.flushProducer
            afterFlush <- liftIO getMonotonicTimeNSec
            liftIO $ recordDuration flush afterFlush (afterFlush - beforeFlush) (OpOk (count - length failures))
            pure (length failures)
          "callback" -> do
            forM_ records \record -> do
              before <- liftIO getMonotonicTimeNSec
              P.produceMessage' record \report -> case report of
                P.DeliverySuccess _ _ -> do
                  after <- getMonotonicTimeNSec
                  recordDuration ack after (after - before) (OpOk 1)
                  atomicModifyIORef' callbacks (\old -> (old + 1, ()))
                _ -> pure ()
            P.flushProducer
            pure 0
          _ -> pure count
        ended <- getMonotonicTimeNSec
        failures <- either (ioError . userError . show) pure result
        writeIORef offered (fromIntegral count)
        writeIORef completed (fromIntegral (count - failures))
        writeIORef failed (fromIntegral failures)
        enterPhase (measurementPhaseClock measurement) Drain
        sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
        closeLoadSeries loadSeries
        pure (started, ended, failures)
      received <- consumeIds env topic count
      callbackCount <- readIORef callbacks
      _ <- deleteRunGroups env
      _ <- deleteRunTopics env
      let durationSeconds = fromIntegral (ended - started) / 1e9 :: Double
          observed = Set.fromList received
          unique = Set.size observed
          throughput = fromIntegral count / max 1e-9 durationSeconds
          failures =
            ["producer-enqueue" | enqueueFailures /= 0]
              <> ["producer-delivery" | observed /= Set.fromList [0 .. count - 1] || length received /= count]
              <> ["producer-callbacks" | mode == "callback" && callbackCount /= count]
      putSummary context Measurements "producerModes" (object ["mode" .= mode, "count" .= count, "durationSeconds" .= durationSeconds, "recordsPerSecond" .= throughput, "payloadBytes" .= payloadBytes, "latencyBasis" .= (if mode `elem` ["sync", "callback"] then "broker acknowledgement" else "enqueue and flush only" :: Text), "authoritative" .= False])
      putSummary context Verdicts "producerModes" (object ["received" .= length received, "unique" .= unique, "callbackSuccesses" .= callbackCount, "enqueueFailures" .= enqueueFailures])
      pure $ if null failures then passed else failedWith failures ("mode=" <> mode <> " received=" <> Text.pack (show (length received)) <> " callbacks=" <> Text.pack (show callbackCount))

makeRecord :: TopicName -> Int -> Int -> P.ProducerRecord
makeRecord topic payloadBytes value =
  P.ProducerRecord
    { P.prTopic = topic,
      P.prPartition = P.SpecifiedPartition 0,
      P.prKey = Just (ByteString.pack (show value)),
      P.prValue = Just (ByteString.pack (show value <> ":" <> replicate (max 0 (payloadBytes - length (show value) - 1)) '0')),
      P.prHeaders = mempty
    }

consumeIds :: KafkaEnv -> TopicName -> Int -> IO [Int]
consumeIds env topic count = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "producer-benchmark") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (loop 0 [])
  either (ioError . userError . show) pure result
  where
    loop emptyPolls collected
      | length collected >= count || emptyPolls >= (20 :: Int) = pure (reverse collected)
      | otherwise = do
          candidate <- C.pollMessage (Timeout 500)
          case candidate of
            Nothing -> loop (emptyPolls + 1) collected
            Just record -> do
              C.commitOffsetMessage C.OffsetCommit record
              let value = do
                    bytes <- C.crValue record
                    case reads (ByteString.unpack (ByteString.takeWhile (/= ':') bytes)) of
                      [(number, "")] -> Just number
                      _ -> Nothing
              loop 0 (maybe collected (: collected) value)

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

choice :: Text -> Text -> [Text] -> KnobSpec
choice key def others = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| fmap VText others)) (fmap VText (def : others))
