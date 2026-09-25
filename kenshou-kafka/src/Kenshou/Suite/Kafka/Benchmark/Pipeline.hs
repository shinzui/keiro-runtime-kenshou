module Kenshou.Suite.Kafka.Benchmark.Pipeline (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import Control.Monad (forM, forM_, replicateM, void)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
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
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load.Series (closeLoadSeries, openLoadSeries, sampleLoadSeries)
import Kenshou.Measure.Phase (Phase (..), enterPhase)
import Kenshou.Measure.Recorder (OpName (..), OpResult (..), newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (measureConfigFromKnobs, measurementPhaseClock, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kafka.Fixture (firstBrokers)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapterWith, kafkaRebalanceHandler, newKafkaAdapterState)
import Shibuya.Adapter.Kafka.Config qualified as AdapterConfig
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState (..))
import Shibuya.App (AppConfig (..), ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/pipeline/benchmark/produce-consume-throughput"),
        revision = 1,
        summary = "Measures acknowledged produce-to-handler latency through the adapter runner, adapter stream, or raw poll path.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ choice "kafka.consume-path" "adapter-runapp" ["adapter-stream", "raw-poll"],
            intKnob "kafka.partitions" 4 1 12,
            intKnob "kafka.consumers" 2 1 4,
            intKnob "kafka.batch-size" 100 1 1000,
            intKnob "kafka.payload-bytes" 100 32 16384,
            intKnob "kafka.messages" 1000 10 100000,
            intKnob "shibuya.inbox-size" 100 1 10000,
            choice "kafka.prop.acks" "all" ["1"],
            intKnob "kafka.prop.linger.ms" 0 0 1000,
            choice "kafka.prop.compression.type" "none" ["lz4", "zstd"],
            intKnob "kafka.prop.fetch.wait.max.ms" 500 0 5000,
            intKnob "kafka.prop.queued.min.messages" 100000 1 1000000
          ]
            <> measureKnobs Benchmark,
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runPipeline
      }
  ]

runPipeline :: RunContext -> IO ScenarioReport
runPipeline context = case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
  Left reason -> pure (failedWith ["invalid-measure-config"] reason)
  Right measureConfig -> do
    spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
    withKafkaEnv context spec \env -> do
      let knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
          partitions = knob "kafka.partitions"
          consumers = knob "kafka.consumers"
          count = knob "kafka.messages"
          batch = knob "kafka.batch-size"
          payloadBytes = knob "kafka.payload-bytes"
          inbox = knob "shibuya.inbox-size"
          path = knobText context.knobs (name "kafka.consume-path")
      [topic] <- createTopics env [TopicSpec "pipeline-benchmark" partitions mempty]
      let group = groupName env "pipeline-benchmark"
          producerProps =
            P.brokersList (firstBrokers env)
              <> P.extraProp "acks" (knobText context.knobs (name "kafka.prop.acks"))
              <> P.extraProp "linger.ms" (Text.pack (show (knob "kafka.prop.linger.ms")))
              <> P.extraProp "compression.type" (knobText context.knobs (name "kafka.prop.compression.type"))
      ((produced, handled, facts, earlyExits, reached, durationSeconds), _) <- withMeasurement context measureConfig \measurement -> do
        handle <- registerOp (measurementRecorder measurement) (OpName "produce-to-handler") >>= flip newWorkerRecorder 0
        offered <- newIORef 0
        completed <- newIORef 0
        failed <- newIORef 0
        maxLag <- newIORef 0
        series <- openLoadSeries measurement
        seen <- newIORef Set.empty
        factCount <- newIORef (0 :: Int)
        done <- newEmptyMVar
        let observe payload = case payload >>= parseValue of
              Nothing -> pure ()
              Just (number, intended) -> do
                arrived <- getMonotonicTimeNSec
                recordOp handle intended arrived arrived (OpOk 1)
                atomicModifyIORef' factCount (\old -> (old + 1, ()))
                unique <- atomicModifyIORef' seen \old -> let next = Set.insert number old in (next, Set.size next)
                if unique >= count then void (tryPutMVar done ()) else pure ()
            consumer state worker = consumePath env state topic group path batch inbox (knob "kafka.prop.fetch.wait.max.ms") (knob "kafka.prop.queued.min.messages") observe worker
        states <- replicateM consumers newKafkaAdapterState
        workers <- forM (zip states [0 .. consumers - 1]) (\(state, worker) -> async (consumer state worker))
        threadDelay 1000000
        enterPhase (measurementPhaseClock measurement) Steady
        sampleLoadSeries series measurement offered offered completed failed maxLag
        started <- getMonotonicTimeNSec
        result <- runEff . runError @KafkaError $
          P.runKafkaProducer producerProps $
            forM [0 .. count - 1] \index -> do
              intended <- liftIO getMonotonicTimeNSec
              P.produceMessageSync (record topic partitions payloadBytes index intended)
        produced <- either (ioError . userError . show) (pure . length) result
        reached <- timeout 30000000 (readMVar done)
        ended <- getMonotonicTimeNSec
        threadDelay 2000000
        exits <- traverse poll workers
        forM_ states \state -> atomically (writeTVar state.shutdownVar True)
        stopped <- traverse (timeout 10000000 . waitCatch) workers
        forM_ (zip workers stopped) \(worker, outcome) -> case outcome of
          Nothing -> cancel worker
          Just _ -> pure ()
        handled <- readIORef seen
        facts <- readIORef factCount
        writeIORef offered (fromIntegral count)
        writeIORef completed (fromIntegral (Set.size handled))
        enterPhase (measurementPhaseClock measurement) Drain
        sampleLoadSeries series measurement offered offered completed failed maxLag
        closeLoadSeries series
        pure (produced, handled, facts, length [() | Just _ <- exits], maybe False (const True) reached, fromIntegral (ended - started) / 1e9 :: Double)
      snapshot <- describeGroup env group
      _ <- deleteRunGroups env
      _ <- deleteRunTopics env
      let expected = Set.fromList [0 .. count - 1]
          failures =
            ["pipeline-producer-ack" | produced /= count]
              <> ["pipeline-no-loss" | handled /= expected]
              <> ["pipeline-drain-timeout" | not reached]
              <> ["pipeline-zero-lag" | length snapshot.offsets /= partitions || any ((/= Just 0) . (.lag)) snapshot.offsets]
              <> ["pipeline-premature-consumer-exit" | earlyExits > 0]
          throughput = fromIntegral (Set.size handled) / max 1e-9 durationSeconds
      putSummary context Measurements "pipeline" (object ["path" .= path, "partitions" .= partitions, "consumers" .= consumers, "messages" .= count, "handledPerSecond" .= throughput, "durationSeconds" .= durationSeconds, "authoritative" .= False])
      putSummary context Verdicts "pipeline" (object ["produced" .= produced, "uniqueHandled" .= Set.size handled, "handlerFacts" .= facts, "prematureConsumerExits" .= earlyExits, "drainedWithinDeadline" .= reached, "groupPartitions" .= length snapshot.offsets])
      pure $ if null failures then passed else failedWith failures ("path=" <> path <> " produced=" <> Text.pack (show produced) <> " handled=" <> Text.pack (show (Set.size handled)))

consumePath :: KafkaEnv -> KafkaAdapterState -> TopicName -> C.ConsumerGroupId -> Text -> Int -> Int -> Int -> Int -> (Maybe ByteString.ByteString -> IO ()) -> Int -> IO ()
consumePath env state topic group path batch inbox fetchWait queuedMin observe worker = do
  let rebalance consumer event = kafkaRebalanceHandler state consumer event
      props =
        C.brokersList (firstBrokers env)
          <> C.groupId group
          <> C.noAutoOffsetStore
          <> C.extraProp "auto.commit.interval.ms" "500"
          <> C.extraProp "fetch.wait.max.ms" (Text.pack (show fetchWait))
          <> C.extraProp "queued.min.messages" (Text.pack (show queuedMin))
          <> C.setCallback (C.rebalanceCallback rebalance)
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
      config = (defaultConfig [topic]) {AdapterConfig.batchSize = BatchSize batch}
  outcome <- runEff . runError @KafkaError . runTracingNoop $ C.runKafkaConsumer props subscription $ case path of
    "adapter-runapp" -> do
      adapter <- kafkaAdapterWith state config
      let handler Message {envelope = Envelope {payload}} = liftIO (observe payload) >> pure AckOk
      app <- runApp (defaultAppConfig {inboxSize = inbox}) [(ProcessorId ("pipeline-" <> Text.pack (show worker)), mkProcessor adapter handler)]
      case app of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right running -> waitApp running >> stopApp running
    "adapter-stream" -> do
      adapter <- kafkaAdapterWith state config
      let Adapter {source} = adapter
      Stream.fold Fold.drain $
        Stream.mapM
          ( \Ingested {envelope = Envelope {payload}, ack = AckHandle finalize} -> do
              liftIO (observe payload)
              finalize AckOk
          )
          source
    _ ->
      let loop = do
            stopped <- liftIO (readTVarIO state.shutdownVar)
            if stopped
              then pure ()
              else do
                candidate <- C.pollMessage (Timeout 100)
                forM_ candidate \row -> do
                  liftIO (observe (C.crValue row))
                  C.commitOffsetMessage C.OffsetCommit row
                loop
       in loop
  either (ioError . userError . show) pure outcome

record :: TopicName -> Int -> Int -> Int -> Word64 -> P.ProducerRecord
record topic partitions payloadBytes index intended =
  P.ProducerRecord
    { P.prTopic = topic,
      P.prPartition = P.SpecifiedPartition (index `mod` partitions),
      P.prKey = Just (ByteString.pack (show index)),
      P.prValue = Just (ByteString.pack (prefix <> replicate (max 0 (payloadBytes - length prefix)) '0')),
      P.prHeaders = mempty
    }
  where
    prefix = show index <> ":" <> show intended <> ":"

parseValue :: ByteString.ByteString -> Maybe (Int, Word64)
parseValue bytes = case take 2 (ByteString.split ':' bytes) of
  [index, intended] -> (,) <$> readMaybeInt index <*> readMaybeInt intended
  _ -> Nothing

readMaybeInt :: (Read a) => ByteString.ByteString -> Maybe a
readMaybeInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

choice :: Text -> Text -> [Text] -> KnobSpec
choice key def others = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| fmap VText others)) (fmap VText (def : others))
