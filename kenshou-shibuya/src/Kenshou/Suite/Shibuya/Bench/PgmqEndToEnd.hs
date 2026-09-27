{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Bench.PgmqEndToEnd (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, poll, wait, withAsync)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.Aeson (FromJSON, Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (IOE, liftIO, (:>))
import Hasql.Pool qualified as Pool
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
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueRows, runPgmqStack, withPgmqFixture)
import Pgmq qualified
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), PrefetchConfig (..), defaultConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..))
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency"),
      revision = 1,
      summary = "Measures intended-send-to-delete latency through raw PGMQ and the Shibuya adapter.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        measureKnobs Benchmark
          <> [ KnobSpec (name "bench.arm") "Direct client or Shibuya adapter" KnobText (VText "adapter") (OneOf (VText "raw-client" :| [VText "adapter"])) [VText "raw-client", VText "adapter"],
               KnobSpec (name "bench.rate") "Scheduled messages per second" KnobInt (VInt 200) (IntRange 200 1000) [VInt 200, VInt 1000],
               KnobSpec (name "shibuya.messages") "Scheduled messages" KnobInt (VInt 1000) (IntRange 1000 10000) [VInt 1000, VInt 10000],
               KnobSpec (name "pgmq-adapter.batch-size") "Messages read per poll" KnobInt (VInt 10) (OneOf (VInt 1 :| [VInt 10, VInt 50, VInt 100])) [VInt 1, VInt 10, VInt 50, VInt 100],
               KnobSpec (name "pgmq-adapter.polling") "Standard or long polling" KnobText (VText "standard:1") (OneOf (VText "standard:1" :| [VText "long:5:100"])) [VText "standard:1", VText "long:5:100"],
               KnobSpec (name "pgmq-adapter.prefetch-buffer-size") "Buffered read batches" KnobInt (VInt 0) (OneOf (VInt 0 :| [VInt 4])) [VInt 0, VInt 4],
               KnobSpec (name "shibuya.concurrency") "Serial or asynchronous handler slots" KnobText (VText "async:4") (OneOf (VText "serial" :| [VText "async:4", VText "async:16"])) [VText "serial", VText "async:4", VText "async:16"],
               KnobSpec (name "pgmq-adapter.pool-size") "Consumer pool connections" KnobInt (VInt 10) (IntRange 10 20) [VInt 10],
               KnobSpec (name "bench.payload-bytes") "Encoded JSON payload bytes" KnobInt (VInt 256) (OneOf (VInt 256 :| [VInt 16384])) [VInt 256, VInt 16384]
             ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
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
    duplicate :: !(IORef Int)
  }

newCounters :: IO Counters
newCounters = Counters <$> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef Set.empty <*> newIORef 0

sampleLoad :: LoadSeries -> Measurement -> Counters -> IO ()
sampleLoad series measurement counters = sampleLoadSeries series measurement counters.offered counters.started counters.completed counters.failed counters.maxLag

runBenchmark :: RunContext -> IO ScenarioReport
runBenchmark context = case measureConfigFromKnobs context (phasePlanFromCore context.phases) of
  Left problem -> pure (failedWith ["invalid-measure-config"] problem)
  Right config -> do
    let messages = fromIntegral (knobInt context.knobs (name "shibuya.messages")) :: Int
        rate = fromIntegral (knobInt context.knobs (name "bench.rate")) :: Double
        batchSize = fromIntegral (knobInt context.knobs (name "pgmq-adapter.batch-size")) :: Int
        poolSize = fromIntegral (knobInt context.knobs (name "pgmq-adapter.pool-size")) :: Int
        payloadBytes = fromIntegral (knobInt context.knobs (name "bench.payload-bytes")) :: Int
        arm = knobText context.knobs (name "bench.arm")
        pollingMode = knobText context.knobs (name "pgmq-adapter.polling")
        prefetch = fromIntegral (knobInt context.knobs (name "pgmq-adapter.prefetch-buffer-size")) :: Int
        concurrencyMode = knobText context.knobs (name "shibuya.concurrency")
        measuredConfig = config {defaultPhases = MeasurePhase.PhasePlan (Nanos 0) (MeasurePhase.SteadyCount (fromIntegral messages)) (Nanos 0)}
    result <- try @SomeException $ timeout 180000000 $ withPgmqFixture context "throughput" poolSize $ \fixture ->
      withMeasurement context measuredConfig \measurement -> do
        operation <- registerOp (measurementRecorder measurement) (OpName "publish-to-finalize")
        recorder <- newWorkerRecorder operation 0
        recorderLock <- newMVar ()
        counters <- newCounters
        series <- openLoadSeries measurement
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Steady
        sampleLoad series measurement counters
        withAsync (produce fixture messages rate payloadBytes (sampleLoad series measurement counters) counters) $ \producer -> do
          if arm == "raw-client"
            then consumeRaw fixture messages batchSize pollingMode producer recorder recorderLock counters
            else consumeAdapter fixture messages batchSize pollingMode prefetch concurrencyMode producer recorder recorderLock counters
          wait producer
        MeasurePhase.enterPhase (measurementPhaseClock measurement) MeasurePhase.Drain
        sampleLoad series measurement counters
        closeLoadSeries series
        remaining <- queueRows fixture
        offeredCount <- readIORef counters.offered
        startedCount <- readIORef counters.started
        completedCount <- readIORef counters.completed
        failedCount <- readIORef counters.failed
        maxLagNs <- readIORef counters.maxLag
        seenIds <- readIORef counters.seen
        duplicateCount <- readIORef counters.duplicate
        appendLoadReport measurement $ LoadReport (OpenLoop (OpenConfig (ConstantRate rate) 1 1 (OverloadConfig 1000000000 3 30000000000))) offeredCount startedCount completedCount failedCount maxLagNs Nothing False
        pure (fromIntegral completedCount :: Int, Set.size seenIds, duplicateCount, remaining)
    case result of
      Left err -> pure (failedWith ["pgmq-benchmark-exception"] (Text.pack (displayException err)))
      Right Nothing -> pure (failedWith ["pgmq-benchmark-timeout"] "PGMQ benchmark exceeded 180 seconds")
      Right (Just ((count, distinct, duplicates, remaining), report)) -> do
        let failures =
              ["message-count-mismatch" | count /= messages]
                <> ["distinct-message-count-mismatch" | distinct /= messages]
                <> ["duplicate-delivery" | duplicates /= 0]
                <> ["queue-not-drained" | remaining /= 0]
            base = if null failures then passed else failedWith failures ("finalized " <> Text.pack (show count) <> " of " <> Text.pack (show messages))
            reasons = ["local-placement" | context.environmentSpec.placement /= RunOnCell] :: [Text]
        putSummary context Measurements "pgmq-end-to-end" $
          object
            [ "arm" .= arm,
              "messages" .= messages,
              "finalized" .= count,
              "distinct" .= distinct,
              "duplicates" .= duplicates,
              "remainingRows" .= remaining,
              "ratePerSecond" .= rate,
              "batchSize" .= batchSize,
              "polling" .= pollingMode,
              "prefetchBufferSize" .= prefetch,
              "concurrency" .= concurrencyMode,
              "poolSize" .= poolSize,
              "payloadBytes" .= payloadBytes
            ]
        putSummary context Measurements "methodology" $
          object ["authoritative" .= null reasons, "reasons" .= reasons, "steadyBound" .= ("scheduled-message-count" :: Text)]
        pure (base {outcome = measuredOutcome report base.outcome})

produce :: PgmqFixture -> Int -> Double -> Int -> IO () -> Counters -> IO ()
produce fixture messages rate payloadBytes sample counters = do
  first <- nowNs
  let gap = max 1 (round (1000000000 / rate)) :: Word64
  forM_ [1 .. messages] \number -> do
    let intended = first + fromIntegral (number - 1) * gap
    atomicModifyIORef' counters.offered (\value -> (value + 1, ()))
    sleepUntilNs intended
    published <- nowNs
    let base = object ["sequenceNumber" .= number, "intendedNs" .= intended, "publishedNs" .= published, "padding" .= ("" :: Text)]
        paddingBytes = payloadBytes - fromIntegral (LazyByteString.length (Aeson.encode base))
    unless (paddingBytes >= 0) $ ioError (userError "requested payload is smaller than benchmark metadata")
    let body = object ["sequenceNumber" .= number, "intendedNs" .= intended, "publishedNs" .= published, "padding" .= Text.replicate paddingBytes "x"]
    unless (LazyByteString.length (Aeson.encode body) == fromIntegral payloadBytes) $ ioError (userError "encoded payload size differs from requested bytes")
    sent <- Pool.use fixture.pool (Pgmq.sendMessage (Pgmq.SendMessage fixture.queue (Pgmq.MessageBody body) Nothing))
    either (throwIO . userError . show) (const (pure ())) sent
    atomicModifyIORef' counters.started (\value -> (value + 1, ()))
    atomicModifyIORef' counters.maxLag (\value -> (max value (published - min published intended), ()))
    if number `mod` 100 == 0 then sample else pure ()

payloadField :: (FromJSON a) => Text -> Value -> a
payloadField field (Object fields) = case KeyMap.lookup (Key.fromText field) fields of
  Just value -> case fromJSON value of
    Success parsed -> parsed
    Error problem -> error ("invalid benchmark payload: " <> problem)
  Nothing -> error ("missing benchmark payload field: " <> Text.unpack field)
payloadField _ _ = error "benchmark payload is not an object"

recordFinal :: WorkerRecorder -> MVar () -> Counters -> Value -> IO ()
recordFinal recorder recorderLock counters body = do
  let number = payloadField "sequenceNumber" body :: Int
      intended = payloadField "intendedNs" body :: Word64
      published = payloadField "publishedNs" body :: Word64
  ended <- nowNs
  withMVar recorderLock $ \_ -> do
    recordOp recorder intended published ended (OpOk 1)
    atomicModifyIORef' counters.completed (\count -> (count + 1, ()))
    alreadySeen <- atomicModifyIORef' counters.seen (\ids -> (Set.insert number ids, Set.member number ids))
    if alreadySeen then atomicModifyIORef' counters.duplicate (\count -> (count + 1, ())) else pure ()

awaitCompleted :: Int -> Async () -> Counters -> IO ()
awaitCompleted messages producer counters = do
  completed <- readIORef counters.completed
  if completed >= fromIntegral messages
    then pure ()
    else do
      producerState <- poll producer
      case producerState of
        Just (Left err) -> throwIO err
        _ -> threadDelay 10000 >> awaitCompleted messages producer counters

consumeRaw :: PgmqFixture -> Int -> Int -> Text -> Async () -> WorkerRecorder -> MVar () -> Counters -> IO ()
consumeRaw fixture messages batchSize pollingMode producer recorder recorderLock counters = loop
  where
    loop = do
      completed <- readIORef counters.completed
      if completed >= fromIntegral messages
        then pure ()
        else do
          producerState <- poll producer
          case producerState of
            Just (Left err) -> throwIO err
            _ -> pure ()
          fetched <-
            Pool.use fixture.pool $
              if pollingMode == "standard:1"
                then Pgmq.readMessage (Pgmq.ReadMessage fixture.queue 30 (Just (fromIntegral batchSize)) Nothing)
                else Pgmq.readWithPoll (Pgmq.ReadWithPollMessage fixture.queue 30 (Just (fromIntegral batchSize)) 5 100 Nothing)
          batch <- either (throwIO . userError . show) pure fetched
          if Vector.null batch && pollingMode == "standard:1" then threadDelay 1000000 else pure ()
          forM_ batch $ \message -> do
            deleted <- Pool.use fixture.pool (Pgmq.deleteMessage (Pgmq.MessageQuery fixture.queue message.messageId))
            success <- either (throwIO . userError . show) pure deleted
            unless success $ ioError (userError "raw PGMQ delete returned false")
            recordFinal recorder recorderLock counters message.body.unMessageBody
          loop

consumeAdapter :: PgmqFixture -> Int -> Int -> Text -> Int -> Text -> Async () -> WorkerRecorder -> MVar () -> Counters -> IO ()
consumeAdapter fixture messages batchSize pollingMode prefetch concurrencyMode producer recorder recorderLock counters = do
  let pollingConfig = if pollingMode == "standard:1" then StandardPolling 1 else LongPolling 5 100
      prefetchConfig = if prefetch == 0 then Nothing else Just (PrefetchConfig (fromIntegral prefetch))
      concurrencyConfig = case concurrencyMode of
        "serial" -> Serial
        "async:16" -> Async 16
        _ -> Async 4
      config = (defaultConfig fixture.queue) {batchSize = fromIntegral batchSize, polling = pollingConfig, prefetchConfig = prefetchConfig, visibilityTimeout = 30}
  result <- runPgmqStack fixture.pool $ do
    adapterResult <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) config
    adapter <- either (error . show) pure adapterResult
    let wrapped = adapter {source = Stream.mapM (pure . wrapAck recorder recorderLock counters) adapter.source}
        processor = (mkProcessor wrapped (const (pure AckOk))) {concurrency = concurrencyConfig}
    started <- runApp defaultAppConfig [(ProcessorId "pgmq-benchmark", processor)]
    application <- either (error . show) pure started
    liftIO $ awaitCompleted messages producer counters
    stopped <- stopAppGracefully defaultShutdownConfig application
    unless stopped (error "PGMQ benchmark app failed to stop gracefully")
    waitApp application
  either (throwIO . userError . show) pure result

wrapAck :: (IOE :> es) => WorkerRecorder -> MVar () -> Counters -> Ingested es Value -> Ingested es Value
wrapAck recorder recorderLock counters ingested =
  let AckHandle original = ingested.ack
      payload = ingested.envelope.payload
   in ingested {ack = AckHandle (\decision -> do original decision; liftIO $ recordFinal recorder recorderLock counters payload)}
