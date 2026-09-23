module Kenshou.Suite.Kiroku.Bench.Subscription (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Aeson (eitherDecodeStrict', object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.Word (Word64)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Check.Process (Child, ProgressSnapshot (..), awaitReady, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..), newWorkerRecorder, recordDuration, registerOp)
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStore, withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.FilePath ((</>))
import System.Info (os)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [catchUp, appendToHandlerLatency]

catchUp :: Scenario
catchUp =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/benchmark/catch-up"),
      revision = 1,
      summary = "Times cold subscriptions from start through CaughtUp after prepopulation.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 1}) <> measureKnobs Benchmark <> [intKnob "workload.prepopulate" 100000 100 1000000, intKnob "kiroku.subscription.batch-size" 100 1 1000, intKnob "kiroku.consumer-group.size" 0 0 8, choice "kiroku.subscription.target" "all" ["category"]],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = PhasePlan 30 120 15,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runCatchUp
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    choice key value others = KnobSpec (name key) key KnobText (VText value) (OneOf (VText value :| fmap VText others)) (fmap VText (value : others))

runCatchUp :: RunContext -> IO ScenarioReport
runCatchUp context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right (ClosedLoop closed), Right measureConfig) -> do
    active <- newIORef Nothing :: IO (IORef (Maybe (SubscriptionName, IORef (Set Int), MVar ())))
    nextName <- newIORef (0 :: Int)
    let name = either (error . show) id . mkKnobName
        knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
        prepopulate = knob "workload.prepopulate"
        batch = knob "kiroku.subscription.batch-size"
        groupSize = knob "kiroku.consumer-group.size"
        targetName = knobText context.knobs (name "kiroku.subscription.target")
        target = if targetName == "category" then Category (CategoryName "catchup") else AllStreams
        members = if groupSize == 0 then [Nothing] else [Just member | member <- [0 .. groupSize - 1]]
        tap event = case event of
          KirokuEventSubscriptionCaughtUp subscription _ group ->
            readIORef active >>= \case
              Just (expected, seen, done) | subscription == expected -> do
                let member = case group of NonGroup -> -1; GroupMember index _ -> fromIntegral index
                count <- atomicModifyIORef' seen (\current -> let next = Set.insert member current in (next, Set.size next))
                if count >= length members then void (tryPutMVar done ()) else pure ()
              _ -> pure ()
          _ -> pure ()
    withKirokuStoreWithTap context (Just tap) \store -> do
      let stream = StreamName "catchup-bench"
          event = EventData Nothing (EventType "CatchUp") (object []) Nothing Nothing Nothing
          batches = [min 1000 (prepopulate - offset) | offset <- [0, 1000 .. prepopulate - 1]]
      forM_ (zip [0 :: Int ..] batches) \(index, count) -> do
        result <- runStoreIO store (appendToStream stream (if index == 0 then NoStream else AnyVersion) (replicate count event))
        case result of Right _ -> pure (); Left err -> fail ("catch-up prepopulation failed: " <> show err)
      walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
      (_, report) <- withMeasurement context measureConfig \measurement -> do
        let operation _ _ = do
              ordinal <- atomicModifyIORef' nextName (\current -> (current + 1, current))
              let subscription = SubscriptionName ("catchup-bench-" <> Text.pack (show ordinal))
              done <- newEmptyMVar
              seen <- newIORef Set.empty
              delivered <- newIORef (0 :: Int)
              writeIORef active (Just (subscription, seen, done))
              let handler _ = atomicModifyIORef' delivered (\count -> (count + 1, ())) >> pure Continue
                  config member = (defaultSubscriptionConfig subscription target handler) {batchSize = fromIntegral batch, consumerGroup = fmap (\index -> ConsumerGroup (fromIntegral index) (fromIntegral groupSize)) member}
                  withMembers [] action = action
                  withMembers (member : rest) action = withSubscription store (config member) (\_ -> withMembers rest action)
              caughtUp <- try @SomeException (withMembers members (timeout 60000000 (takeMVar done)))
              writeIORef active Nothing
              count <- readIORef delivered
              pure case caughtUp of
                Right (Just ()) | count == prepopulate -> OpOk count
                Right (Just ()) -> OpFailed (ErrorCause ("catch-up-count=" <> Text.pack (show count)))
                Right Nothing -> OpFailed (ErrorCause "caught-up-timeout")
                Left err -> OpFailed (ErrorCause (Text.pack (show err)))
        runLoad measurement (ClosedLoop (closed {workers = 1})) (Operation (OpName "catch-up") operation)
      let completed = sum [load.completed | load <- report.loads]
          failed = sum [load.failed | load <- report.loads]
          base = if completed > 0 && failed == 0 then passed else failedWith ["catch-up-errors-or-no-work"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed))
          walMethod = either (const Nothing) Just walSync
          reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
      putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "prepopulate" .= prepopulate, "batchSize" .= batch, "target" .= targetName, "groupSize" .= groupSize, "trialsRequired" .= (3 :: Int)])
      putSummary context Verdicts "catch-up" (object ["completed" .= completed, "failed" .= failed])
      pure (if failed > 0 then base else base {outcome = measuredOutcome report base.outcome})
  (Right _, Right _) -> pure (failedWith ["unsupported-load-mode"] "catch-up repeats one cold subscription at a time and requires closed-loop load")

appendToHandlerLatency :: Scenario
appendToHandlerLatency =
  catchUp
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/benchmark/append-to-handler-latency"),
      summary = "Joins producer acknowledgements and subscriber handler entries by caller event ID across processes.",
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {model = "open-constant", ratePerSecond = 500, executors = 32}) <> measureKnobs Benchmark <> [intKnob "kiroku.append.writers" 8 1 32, choice "kiroku.subscription.target" "all" ["category"]],
      run = runAppendLatency
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    choice key value others = KnobSpec (name key) key KnobText (VText value) (OneOf (VText value :| fmap VText others)) (fmap VText (value : others))

runAppendLatency :: RunContext -> IO ScenarioReport
runAppendLatency context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right measureConfig) -> withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let name = either (error . show) id . mkKnobName
        writers = fromIntegral (knobInt context.knobs (name "kiroku.append.writers")) :: Int
        target = knobText context.knobs (name "kiroku.subscription.target")
        stream writer = (if target == "category" then "crash-bench-" else "bench-") <> Text.pack (show writer)
    producerSpec <- roleProcess check "kiroku/appender" 0 (object [])
    producer <- spawn supervisor producerSpec
    awaitReady producer 10000
    sendCommand producer CtlStart
    subscriberSpec <- roleProcess check "kiroku/subscriber" 1 (object ["name" .= ("bench-latency" :: Text), "guard" .= False, "emitDeliveries" .= True, "compactDeliveries" .= True, "target" .= target])
    subscriber <- spawn supervisor subscriberSpec
    awaitReady subscriber 10000
    sendCommand subscriber CtlStart
    walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
    ((_loadReport, ackCount, matchedCount, negatives), report) <- withMeasurement context measureConfig \measurement -> do
      latencyHandle <- registerOp (measurementRecorder measurement) (OpName "append-to-handler")
      latencyRecorder <- newWorkerRecorder latencyHandle 0
      let operation worker sequenceNumber = do
            let slot = worker `mod` writers
                token = Text.pack (show worker <> "-" <> show sequenceNumber)
                EventId uuid = eventIdFor context.seed worker (fromIntegral sequenceNumber)
                eventId = UUID.toText uuid
                mark = "bench-ack-" <> Text.pack (show worker)
            sendCommand producer (CtlCustom "bench-append" (object ["token" .= token, "stream" .= stream slot, "eventId" .= eventId]))
            acknowledged <- timeout 30000000 (awaitAckToken producer mark token)
            pure case acknowledged of
              Just "success" -> OpOk 1
              Just status -> OpFailed (ErrorCause status)
              Nothing -> OpFailed (ErrorCause "append-ack-timeout")
      loadReport <- runLoad measurement loadModel (Operation (OpName "append") operation)
      producerMessages <- readWorkerMessages (context.outDir </> "logs" </> "kiroku-appender-0.0.control.jsonl")
      let acks = Map.fromList [row | WrkCustom key payload <- producerMessages, "bench-ack-" `Text.isPrefixOf` key, Just row <- [parseMaybe (withObject "ack" (\value -> do eventId <- value .: "eventId"; status <- value .: "status"; stamp <- value .: "ackMonoNs"; pure (eventId, (status, stamp)))) payload :: Maybe (Text, (Text, Word64))], fst (snd row) == "success"]
      _ <- timeout 60000000 (awaitLatestPosition subscriber (fromIntegral (Map.size acks)))
      subscriberMessages <- readWorkerMessages (context.outDir </> "logs" </> "kiroku-subscriber-1.0.control.jsonl")
      let deliveries = Map.fromListWith min [row | WrkCustom key payload <- subscriberMessages, key == "delivery-latest", Just row <- [parseMaybe (withObject "delivery" (\value -> (,) <$> value .: "eventId" <*> value .: "receivedMonoNs")) payload :: Maybe (Text, Word64)]]
          matched = [(ackNs, receivedNs) | (eventId, (_, ackNs)) <- Map.toList acks, Just receivedNs <- [Map.lookup eventId deliveries]]
          negatives = length [() | (ackNs, receivedNs) <- matched, receivedNs < ackNs]
      forM_ matched \(ackNs, receivedNs) -> recordDuration latencyRecorder receivedNs (receivedNs - min receivedNs ackNs) (OpOk 1)
      pure (loadReport, Map.size acks, length matched, negatives)
    counts <- Oracle.threeCounts store.pool
    let completed = sum [load.completed | load <- report.loads]
        failed = sum [load.failed | load <- report.loads]
        base = if failed == 0 && ackCount > 0 && matchedCount == ackCount && counts == (fromIntegral ackCount, fromIntegral ackCount, fromIntegral ackCount) then passed else failedWith ["cross-process-delivery"] ("acks=" <> Text.pack (show ackCount) <> ", matched=" <> Text.pack (show matchedCount) <> ", failures=" <> Text.pack (show failed))
        walMethod = either (const Nothing) Just walSync
        reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
    putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "writers" .= writers, "target" .= target, "clockSkewBoundNs" .= (0 :: Int), "clockSkewBasis" .= ("producer and subscriber are processes on one host" :: Text), "trialsRequired" .= (3 :: Int)])
    putSummary context Verdicts "append-to-handler-latency" (object ["acknowledged" .= ackCount, "matched" .= matchedCount, "handlerBeforeAck" .= negatives, "loadCompleted" .= completed, "loadFailed" .= failed, "durableCounts" .= counts])
    pure (if base.outcome == Passed then base {outcome = measuredOutcome report base.outcome} else base)

awaitAckToken :: Child -> Text -> Text -> IO Text
awaitAckToken child mark token = atomically do
  state <- progress child
  case Map.lookup mark state.marks >>= parseMaybe (withObject "ack" (\value -> (,) <$> value .: "token" <*> value .: "status")) of
    Just (observed, status) | observed == token -> pure status
    _ -> retry

awaitLatestPosition :: Child -> Int64 -> IO ()
awaitLatestPosition child target = do
  state <- atomically (progress child)
  let latest = Map.lookup "delivery-latest" state.marks >>= parseMaybe (withObject "delivery" (.: "position"))
  if maybe False (>= target) latest then pure () else threadDelay 10000 >> awaitLatestPosition child target

readWorkerMessages :: FilePath -> IO [WorkerMessage]
readWorkerMessages path = do
  contents <- ByteString.readFile path
  pure [message | line <- ByteString.lines contents, Right message <- [eitherDecodeStrict' line]]

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
