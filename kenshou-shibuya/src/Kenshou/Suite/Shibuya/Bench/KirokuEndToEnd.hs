{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Bench.KirokuEndToEnd (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll, wait, withAsync)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (SomeException, bracket, displayException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (FromJSON, Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (IOE, liftIO, runEff, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith, passed)
import Kenshou.Measure.Clock (Nanos (..), nowNs, sleepUntilNs)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (Arrival (..), LoadModel (..), LoadReport (..), OpenConfig (..), OverloadConfig (..))
import Kenshou.Measure.Load.Series (LoadSeries, closeLoadSeries, openLoadSeries, sampleLoadSeries)
import Kenshou.Measure.Phase qualified as MeasurePhase
import Kenshou.Measure.Recorder (OpName (..), OpResult (..), WorkerRecorder, newWorkerRecorder, recordOp, registerOp)
import Kenshou.Measure.Session (MeasureConfig (..), Measurement, appendLoadReport, measureConfigFromKnobs, measuredOutcome, measurementPhaseClock, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (KirokuFixture (..), checkpointOf, subscriptionFor, withKirokuFixture)
import Kiroku.Store (AppendResult (..), CategoryName (..), EventData (..), EventType (..), ExpectedVersion (..), GlobalPosition (..), RecordedEvent (..), StreamName (..), SubscriptionName, SubscriptionResult (..), SubscriptionTarget (..), appendToStream, defaultSubscriptionConfig, runStoreIO, subscribe)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types qualified as Sub
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (ConsumerGroup (..), KirokuAdapterConfig (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/benchmark/end-to-end-throughput-latency"),
      revision = 1,
      summary = "Measures scheduled-append-to-ack latency through Kiroku callback, ack stream, and Shibuya adapter.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        measureKnobs Benchmark
          <> [ KnobSpec (name "bench.arm") "Subscription consumer path" KnobText (VText "adapter") (OneOf (VText "subscribe-callback" :| [VText "ack-stream", VText "adapter"])) [VText "subscribe-callback", VText "ack-stream", VText "adapter"],
               KnobSpec (name "bench.phase") "Append before or during subscription" KnobText (VText "live") (OneOf (VText "catch-up" :| [VText "live"])) [VText "catch-up", VText "live"],
               KnobSpec (name "bench.rate") "Scheduled appends per second" KnobInt (VInt 200) (IntRange 200 1000) [VInt 200, VInt 1000],
               KnobSpec (name "shibuya.messages") "Scheduled events" KnobInt (VInt 1000) (IntRange 1000 10000) [VInt 1000, VInt 10000],
               KnobSpec (name "kiroku-adapter.batch-size") "Events fetched per catch-up batch" KnobInt (VInt 100) (OneOf (VInt 1 :| [VInt 10, VInt 100])) [VInt 1, VInt 10, VInt 100],
               KnobSpec (name "kiroku-adapter.group-size") "Consumer group members; zero means ungrouped" KnobInt (VInt 0) (OneOf (VInt 0 :| [VInt 4])) [VInt 0, VInt 4],
               KnobSpec (name "shibuya.concurrency") "Serial or eight asynchronous handlers" KnobText (VText "serial") (OneOf (VText "serial" :| [VText "async:8"])) [VText "serial", VText "async:8"]
             ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runBenchmark
    }

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

data Counters = Counters
  { offered :: !(IORef Word64),
    started :: !(IORef Word64),
    completed :: !(IORef Word64),
    failed :: !(IORef Word64),
    maxLag :: !(IORef Word64),
    seen :: !(IORef (Set.Set Int)),
    duplicate :: !(IORef Int),
    memberPositions :: !(IORef (Map Int Int64))
  }

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef Set.empty <*> newIORef 0 <*> newIORef Map.empty

sampleLoad :: LoadSeries -> Measurement -> Counters -> IO ()
sampleLoad series measurement counters = sampleLoadSeries series measurement counters.offered counters.started counters.completed counters.failed counters.maxLag

runBenchmark :: RunContext -> IO ScenarioReport
runBenchmark context = case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
  Left problem -> pure (failedWith ["invalid-measure-config"] problem)
  Right config -> do
    let messages = fromIntegral (knobInt context.knobs (name "shibuya.messages")) :: Int
        rate = fromIntegral (knobInt context.knobs (name "bench.rate")) :: Double
        batchSize = fromIntegral (knobInt context.knobs (name "kiroku-adapter.batch-size"))
        groupSize = fromIntegral (knobInt context.knobs (name "kiroku-adapter.group-size")) :: Int
        arm = knobText context.knobs (name "bench.arm")
        phase = knobText context.knobs (name "bench.phase")
        concurrencyMode = knobText context.knobs (name "shibuya.concurrency")
        measuredConfig = config {defaultPhases = MeasurePhase.PhasePlan (Nanos 0) (MeasurePhase.SteadyCount (fromIntegral messages)) (Nanos 0)}
    result <- try @SomeException $ timeout 180000000 $ withKirokuFixture context $ \fixture ->
      withMeasurement context measuredConfig \measurement -> do
        operation <- registerOp (measurementRecorder measurement) (OpName "publish-to-finalize")
        recorder <- newWorkerRecorder operation 0
        recorderLock <- newMVar ()
        counters <- newCounters
        series <- openLoadSeries measurement
        let sample = sampleLoad series measurement counters
            subscription = subscriptionFor fixture "throughput"
            finish producer = do
              finalPosition <- wait producer
              awaitCompleted messages producer counters
              positions <- readIORef counters.memberPositions
              awaitCheckpoint fixture subscription positions
              pure finalPosition
            consume producer = case arm of
              "subscribe-callback" -> consumeCallback fixture subscription batchSize groupSize messages producer recorder recorderLock counters finish
              "ack-stream" -> consumeAckStream fixture subscription batchSize groupSize producer recorder recorderLock counters finish
              _ -> consumeAdapter fixture subscription batchSize groupSize concurrencyMode producer recorder recorderLock counters finish
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Steady
        sample
        finalPosition <-
          if phase == "catch-up"
            then do
              position <- produce fixture groupSize messages rate sample counters
              withAsync (pure position) consume
            else withAsync (produce fixture groupSize messages rate sample counters) consume
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Drain
        sample
        closeLoadSeries series
        offeredCount <- readIORef counters.offered
        startedCount <- readIORef counters.started
        completedCount <- readIORef counters.completed
        failedCount <- readIORef counters.failed
        maxLagNs <- readIORef counters.maxLag
        seenIds <- readIORef counters.seen
        duplicateCount <- readIORef counters.duplicate
        memberPositions <- readIORef counters.memberPositions
        appendLoadReport measurement $ LoadReport (OpenLoop (OpenConfig (ConstantRate rate) 1 1 (OverloadConfig 1000000000 3 30000000000))) offeredCount startedCount completedCount failedCount maxLagNs Nothing False
        pure (fromIntegral completedCount :: Int, Set.size seenIds, duplicateCount, memberPositions, finalPosition)
    case result of
      Left err -> pure (failedWith ["kiroku-benchmark-exception"] (Text.pack (displayException err)))
      Right Nothing -> pure (failedWith ["kiroku-benchmark-timeout"] "Kiroku benchmark exceeded 180 seconds")
      Right (Just ((count, distinct, duplicates, memberPositions, finalPosition), report)) -> do
        let failures =
              ["event-count-mismatch" | count /= messages]
                <> ["distinct-event-count-mismatch" | distinct /= messages]
                <> ["duplicate-delivery" | duplicates /= 0]
                <> ["group-member-coverage" | Map.size memberPositions /= max 1 groupSize]
            base = if null failures then passed else failedWith failures ("finalized " <> Text.pack (show count) <> " of " <> Text.pack (show messages))
            reasons = ["local-placement" | context.environmentSpec.placement /= RunOnCell] :: [Text]
        putSummary context Measurements "kiroku-end-to-end" $
          object
            [ "arm" .= arm,
              "phase" .= phase,
              "events" .= messages,
              "finalized" .= count,
              "distinct" .= distinct,
              "duplicates" .= duplicates,
              "ratePerSecond" .= rate,
              "batchSize" .= batchSize,
              "groupSize" .= groupSize,
              "concurrency" .= concurrencyMode,
              "memberLastPositions" .= Map.toList memberPositions,
              "finalPosition" .= finalPosition
            ]
        putSummary context Measurements "methodology" $
          object ["authoritative" .= null reasons, "reasons" .= reasons, "steadyBound" .= ("scheduled-event-count" :: Text), "completion" .= ("handler-record-or-ack-reply; checkpoint checked separately" :: Text)]
        pure (base {outcome = measuredOutcome report base.outcome})

produce :: KirokuFixture -> Int -> Int -> Double -> IO () -> Counters -> IO Int64
produce fixture groupSize messages rate sample counters = do
  first <- nowNs
  let gap = max 1 (round (1000000000 / rate)) :: Word64
  lastPosition <- newIORef 0
  forM_ [1 .. messages] \number -> do
    let intended = first + fromIntegral (number - 1) * gap
    atomicModifyIORef' counters.offered (\value -> (value + 1, ()))
    sleepUntilNs intended
    published <- nowNs
    let body = object ["sequenceNumber" .= number, "intendedNs" .= intended, "publishedNs" .= published]
        event = EventData Nothing (EventType "KenshouBenchmark") body Nothing Nothing Nothing
        stream = if groupSize == 0 then fixture.stream else let CategoryName category = fixture.category in StreamName (category <> "-" <> Text.pack (show (1 + (number - 1) `mod` 16)))
    appended <- runStoreIO fixture.store (appendToStream stream AnyVersion [event])
    result <- either (throwIO . userError . show) pure appended
    let GlobalPosition position = result.globalPosition
    atomicModifyIORef' lastPosition (const (position, ()))
    atomicModifyIORef' counters.started (\value -> (value + 1, ()))
    atomicModifyIORef' counters.maxLag (\value -> (max value (published - min published intended), ()))
    when (number `mod` 100 == 0) sample
  readIORef lastPosition

payloadField :: (FromJSON a) => Text -> Value -> a
payloadField field (Object fields) = case KeyMap.lookup (Key.fromText field) fields of
  Just value -> case fromJSON value of
    Success parsed -> parsed
    Error problem -> error ("invalid benchmark payload: " <> problem)
  Nothing -> error ("missing benchmark payload field: " <> Text.unpack field)
payloadField _ _ = error "benchmark payload is not an object"

recordFinal :: WorkerRecorder -> MVar () -> Counters -> Int -> RecordedEvent -> IO ()
recordFinal recorder recorderLock counters member event = do
  let number = payloadField "sequenceNumber" event.payload :: Int
      intended = payloadField "intendedNs" event.payload :: Word64
      published = payloadField "publishedNs" event.payload :: Word64
  ended <- nowNs
  withMVar recorderLock $ \_ -> do
    recordOp recorder intended published ended (OpOk 1)
    atomicModifyIORef' counters.completed (\count -> (count + 1, ()))
    alreadySeen <- atomicModifyIORef' counters.seen (\ids -> (Set.insert number ids, Set.member number ids))
    when alreadySeen $ atomicModifyIORef' counters.duplicate (\count -> (count + 1, ()))
    let GlobalPosition position = event.globalPosition
    atomicModifyIORef' counters.memberPositions (\positions -> (Map.insertWith max member position positions, ()))

awaitCompleted :: Int -> Async Int64 -> Counters -> IO ()
awaitCompleted messages producer counters = do
  count <- readIORef counters.completed
  if count >= fromIntegral messages
    then pure ()
    else do
      state <- poll producer
      case state of
        Just (Left err) -> throwIO err
        _ -> threadDelay 10000 >> awaitCompleted messages producer counters

awaitCheckpoint :: KirokuFixture -> SubscriptionName -> Map Int Int64 -> IO ()
awaitCheckpoint fixture subscription positions = do
  checkpoints <- mapM (\(member, position) -> maybe False (>= position) <$> checkpointOf fixture subscription (fromIntegral member)) (Map.toList positions)
  unless (and checkpoints) $ threadDelay 10000 >> awaitCheckpoint fixture subscription positions

consumeCallback :: KirokuFixture -> SubscriptionName -> Int32 -> Int -> Int -> Async Int64 -> WorkerRecorder -> MVar () -> Counters -> (Async Int64 -> IO Int64) -> IO Int64
consumeCallback fixture subscription batchSize groupSize messages producer recorder recorderLock counters finish =
  bracket (mapM (subscribe fixture.store . config) members) (mapM_ Sub.cancel) $ \_ -> do
    awaitCompleted messages producer counters
    finish producer
  where
    members = if groupSize == 0 then [0] else [0 .. groupSize - 1]
    config member = (defaultSubscriptionConfig subscription (Category fixture.category) (handler member)) {Sub.batchSize = batchSize, Sub.consumerGroup = if groupSize == 0 then Nothing else Just (Sub.ConsumerGroup (fromIntegral member) (fromIntegral groupSize))}
    handler member event = recordFinal recorder recorderLock counters member event >> pure Continue

consumeAckStream :: KirokuFixture -> SubscriptionName -> Int32 -> Int -> Async Int64 -> WorkerRecorder -> MVar () -> Counters -> (Async Int64 -> IO Int64) -> IO Int64
consumeAckStream fixture subscription batchSize groupSize producer recorder recorderLock counters finish =
  bracket (mapM (\member -> subscriptionAckStream fixture.store (config member) 256) members) (mapM_ snd) $ \streams ->
    bracket (mapM (\(member, (stream, _)) -> async $ Stream.fold Fold.drain $ Stream.mapM (acknowledge member) stream) (zip members streams)) (mapM_ cancel) $ \_ ->
      finish producer
  where
    members = if groupSize == 0 then [0] else [0 .. groupSize - 1]
    config member = (defaultSubscriptionConfig subscription (Category fixture.category) (const (pure Continue))) {Sub.batchSize = batchSize, Sub.consumerGroup = if groupSize == 0 then Nothing else Just (Sub.ConsumerGroup (fromIntegral member) (fromIntegral groupSize))}
    acknowledge member item = do
      atomically $ putTMVar item.ackReply Continue
      recordFinal recorder recorderLock counters member item.ackEvent

consumeAdapter :: KirokuFixture -> SubscriptionName -> Int32 -> Int -> Text -> Async Int64 -> WorkerRecorder -> MVar () -> Counters -> (Async Int64 -> IO Int64) -> IO Int64
consumeAdapter fixture subscription batchSize groupSize concurrencyMode producer recorder recorderLock counters finish = runEff $ runTracingNoop $ do
  let config member = (defaultKirokuAdapterConfig subscription (Category fixture.category)) {batchSize = batchSize, consumerGroup = if groupSize == 0 then Nothing else Just (ConsumerGroup (fromIntegral member) (fromIntegral groupSize))}
      concurrencyConfig = if concurrencyMode == "serial" then Serial else Async 8
      members = if groupSize == 0 then [0] else [0 .. groupSize - 1]
  processors <- forM members $ \member -> do
    adapter <- kirokuAdapter fixture.store (config member)
    let wrapped = adapter {source = Stream.mapM (pure . wrapAck recorder recorderLock counters member) adapter.source}
        processor = (mkProcessor wrapped (const (pure AckOk))) {concurrency = concurrencyConfig}
    pure (ProcessorId ("kiroku-benchmark-" <> Text.pack (show member)), processor)
  started <- runApp defaultAppConfig processors
  application <- either (error . show) pure started
  position <- liftIO $ finish producer
  stopped <- stopAppGracefully defaultShutdownConfig application
  unless stopped (error "Kiroku benchmark app failed to stop gracefully")
  waitApp application
  pure position

wrapAck :: (IOE :> es) => WorkerRecorder -> MVar () -> Counters -> Int -> Ingested es RecordedEvent -> Ingested es RecordedEvent
wrapAck recorder recorderLock counters member ingested =
  let AckHandle original = ingested.ack
      event = ingested.envelope.payload
   in ingested {ack = AckHandle (\decision -> do original decision; liftIO $ recordFinal recorder recorderLock counters member event)}
