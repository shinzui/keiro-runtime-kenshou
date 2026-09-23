{-# LANGUAGE BangPatterns #-}

module Kenshou.Suite.Kiroku.Soak.AppendSubscribe (scenarios) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (bracket, finally, mask_)
import Control.Monad (forM, void)
import Data.Aeson (Value, eitherDecodeStrict', object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Check.Process (awaitReady, killChild, restartChild, roleProcess, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (Dimensions (..), TracingArm (..))
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Role (WorkerMessage (..))
import Kenshou.Core.Scenario (Scenario, ScenarioReport (..), failedWith, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), judgeLeaks)
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Measure.Summary (MeasurementSummary (..), SummaryWindow (..))
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore, withKirokuStoreWithCallbacks)
import Kenshou.Suite.Kiroku.Fixture.Telemetry (composeEventHandler)
import Kenshou.Suite.Kiroku.Soak.Common (SoakDefinition (..), SoakProfile, applyLeakVerdict, effectivePhases, soakLeakSpec, soakPair)
import Kenshou.Suite.Kiroku.Soak.Growth (Drift (..), Growth (..), appendLatencyDrift, relationGrowth)
import Kenshou.Telemetry (TelemetryHandles (..), withTelemetry)
import Kenshou.Telemetry.Spec (telemetrySpecFromContext)
import Kiroku.Store hiding (id, withKirokuStore)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), IOMode (WriteMode), hClose, hPutStrLn, hSetBuffering, openFile)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = soakPair (SoakDefinition "subscription" "append-and-subscribe" "Appends across a thousand streams while native, category, group, and ack-stream subscribers run through process kills." runAppendSubscribe)

type DeliveryState = IORef (Int64, Int64, Int64)

runAppendSubscribe :: SoakProfile -> RunContext -> IO ScenarioReport
runAppendSubscribe profile context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (effectivePhases profile context))) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right baseConfig) -> withSoakStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let name = either (error . show) id . mkKnobName
        killMinutes = fromIntegral (knobInt context.knobs (name "soak.kill-interval-minutes")) :: Int
        config = baseConfig {postgres = fmap (\pg -> pg {relations = ["kiroku.events", "kiroku.stream_events", "kiroku.streams", "kiroku.subscriptions"]}) baseConfig.postgres}
        operation _ sequenceNumber = do
          let streamNumber = sequenceNumber `mod` 1000
              category = streamNumber `mod` 8
              stream = StreamName ("soak" <> Text.pack (show category) <> "-" <> Text.pack (show streamNumber))
              event = EventData Nothing (EventType "SoakAppend") (object ["sequence" .= sequenceNumber]) Nothing Nothing Nothing
          result <- runStoreIO store (appendToStream stream AnyVersion [event])
          pure case result of Right _ -> OpOk 1; Left err -> OpFailed (ErrorCause (Text.pack (show err)))
    allStates <- forM [0 :: Int, 1] \_ -> (newIORef (0, 0, 0) :: IO DeliveryState)
    categoryStates <- forM [0 :: Int, 1] \_ -> (newIORef (0, 0, 0) :: IO DeliveryState)
    ackState <- newIORef (0, 0, 0) :: IO DeliveryState
    let groupZeroPath = context.outDir </> "logs" </> "soak-group-zero.positions"
    groupZeroHandle <- openFile groupZeroPath WriteMode
    hSetBuffering groupZeroHandle LineBuffering
    workerSpecs <- forM [1 :: Int, 2] \member -> roleProcess check "kiroku/subscriber" member (object ["name" .= ("soak-group" :: Text), "member" .= member, "size" .= (3 :: Int), "guard" .= False, "target" .= ("all" :: Text), "emitDeliveries" .= True, "compactDeliveries" .= True])
    workers <- forM workerSpecs \spec -> do
      child <- spawn supervisor spec
      awaitReady child 10000
      newIORef child
    kills <- newIORef (0 :: Int)
    let update contiguous state row = do
          let GlobalPosition position = row.globalPosition
          atomicModifyIORef' state \(count, previous, violations) ->
            let bad = if count > 0 && (if contiguous then position /= previous + 1 else position <= previous) then 1 else 0
                !nextCount = count + 1
                !nextViolations = violations + bad
             in ((nextCount, position, nextViolations), ())
        native subscriptionName target state contiguous = defaultSubscriptionConfig subscriptionName target (\row -> update contiguous state row >> pure Continue)
        allConfigs = [native (SubscriptionName ("soak-all-" <> Text.pack (show index))) AllStreams state True | (index, state) <- zip [0 :: Int ..] allStates]
        categoryConfigs = [native (SubscriptionName ("soak-category-" <> Text.pack (show index))) (Category (CategoryName ("soak" <> Text.pack (show index)))) state False | (index, state) <- zip [0 :: Int ..] categoryStates]
        groupConfig = (defaultSubscriptionConfig (SubscriptionName "soak-group") AllStreams (\row -> let GlobalPosition position = row.globalPosition in hPutStrLn groupZeroHandle (show position) >> pure Continue)) {consumerGroup = Just (ConsumerGroup 0 3), consumerGroupGuard = False}
        withNative [] action = action
        withNative (cfg : rest) action = withSubscription store cfg (\_ -> withNative rest action)
        killLoop = do
          threadDelay (killMinutes * 60 * 1000000)
          mask_ do
            cycleNumber <- readIORef kills
            let slot = cycleNumber `mod` 2
            old <- readIORef (workers !! slot)
            killChild supervisor old
            replacement <- restartChild supervisor old
            writeIORef (workers !! slot) replacement
            atomicModifyIORef' kills (\count -> (count + 1, ()))
          killLoop
        withKills action
          | killMinutes == 0 = action
          | otherwise = bracket (forkIO killLoop) killThread (const action)
        awaitLocal expected categoryExpected = do
          allRows <- traverse readIORef allStates
          categoryRows <- traverse readIORef categoryStates
          ackRow <- readIORef ackState
          if all (\(count, _, _) -> count >= expected) allRows && and [count >= wanted | ((count, _, _), wanted) <- zip categoryRows categoryExpected] && case ackRow of (count, _, _) -> count >= expected
            then pure (allRows, categoryRows, ackRow)
            else threadDelay 100000 >> awaitLocal expected categoryExpected
    (measurement, durable@(eventCount, _, _), categoryExpected, local, groupCaughtUp, killCount) <- flip finally (hClose groupZeroHandle) $ withNative (allConfigs <> categoryConfigs <> [groupConfig]) do
      let ackConfig = defaultSubscriptionConfig (SubscriptionName "soak-ack") AllStreams (\_ -> pure Continue)
      (items, cancelBridge) <- subscriptionAckStream store ackConfig 256
      consumer <- forkIO $ void $ Stream.fold Fold.drain $ Stream.mapM (\item -> do update True ackState item.ackEvent; atomically (putTMVar item.ackReply Continue); pure item.ackEvent) items
      flip finally (cancelBridge >> killThread consumer) do
        (_, measurement) <- withKills (withMeasurement context config \session -> runLoad session loadModel (Operation (OpName "append") operation))
        durable@(eventCount, _, _) <- Oracle.threeCounts store.pool
        categories <- Pool.use store.pool (Session.statement () categoryCountsStatement)
        let categoryExpected = either (const [0, 0]) id categories
        local <- timeout 120000000 (awaitLocal eventCount categoryExpected)
        groupCaughtUp <- timeout 120000000 (waitForGroupCheckpoint store eventCount)
        threadDelay 2000000
        killCount <- readIORef kills
        pure (measurement, durable, categoryExpected, local, groupCaughtUp, killCount)
    groupCoverage <- timeout 120000000 (waitForGroupCoverage context groupZeroPath eventCount)
    eventGrowth <- relationGrowth context "kiroku.events"
    streamEventGrowth <- relationGrowth context "kiroku.stream_events"
    drift <- appendLatencyDrift context measurement
    subscriptionRows <- Pool.use store.pool (Session.statement () subscriptionCountStatement)
    hotUpdates <- Pool.use store.pool (Session.statement () hotUpdateStatement)
    let groupPositions = maybe [] id groupCoverage
        uniqueGroup = Set.fromList groupPositions
        completeGroup = not (Set.null uniqueGroup) && Set.size uniqueGroup == fromIntegral eventCount && Set.findMin uniqueGroup == 1 && Set.findMax uniqueGroup == eventCount
        duplicateGroup = length groupPositions - Set.size uniqueGroup
        duplicateBudget = max 100 (killCount * 100)
        allGood = case local of
          Just (allRows, categoryRows, ackRow) ->
            all (\(count, lastPosition, violations) -> count == eventCount && lastPosition == eventCount && violations == 0) allRows
              && and [count == wanted && violations == 0 | ((count, _, violations), wanted) <- zip categoryRows categoryExpected]
              && ackRow == (eventCount, eventCount, 0)
          Nothing -> False
        completed = sum [load.completed | load <- measurement.loads]
        failed = sum [load.failed | load <- measurement.loads]
        base = if eventCount > 0 && durable == (eventCount, eventCount, eventCount) && failed == 0 && allGood && groupCaughtUp == Just True && completeGroup && duplicateGroup <= duplicateBudget && either (const False) (== 8) subscriptionRows then passed else failedWith ["append-subscribe-soak-contract"] ("durable=" <> Text.pack (show durable) <> ", failures=" <> Text.pack (show failed) <> ", group-unique=" <> Text.pack (show (Set.size uniqueGroup)) <> ", group-duplicates=" <> Text.pack (show duplicateGroup) <> ", local=" <> Text.pack (show local) <> ", subscription-rows=" <> Text.pack (show subscriptionRows))
        measured = if base.outcome == Passed then base {outcome = measuredOutcome measurement base.outcome} else base
        hotShare = case hotUpdates of Right (hot, total) | total > 0 -> Just (fromIntegral hot / fromIntegral total :: Double); _ -> Nothing
        growthOk = all (maybe True (.linear)) [eventGrowth, streamEventGrowth]
        growthMeasured = if measured.outcome == Passed && not growthOk then measured {outcome = Failed, reason = Just "relation size did not grow linearly", failures = "relation-growth" : measured.failures} else measured
        growthComplete = if growthMeasured.outcome == Passed && measurement.summary.window.steadySeconds >= 900 && any (== Nothing) [eventGrowth, streamEventGrowth] then growthMeasured {outcome = Inconclusive, reason = Just "relation growth lacked enough samples"} else growthMeasured
        hotMeasured = if growthComplete.outcome == Passed && maybe False (< 0.9) hotShare then growthComplete {outcome = Inconclusive, reason = Just "kiroku.streams HOT-update share below 0.9"} else growthComplete
        driftMeasured = if hotMeasured.outcome == Passed && maybe False (not . (.withinFactorTwo)) drift then hotMeasured {outcome = Inconclusive, reason = Just "append p99 rose by more than twofold"} else hotMeasured
        driftComplete = if driftMeasured.outcome == Passed && measurement.summary.window.steadySeconds >= 900 && drift == Nothing then driftMeasured {outcome = Inconclusive, reason = Just "append p99 drift lacked enough samples"} else driftMeasured
    putSummary context Verdicts "append-and-subscribe" (object ["completed" .= completed, "failed" .= failed, "durableCounts" .= durable, "categoryCounts" .= categoryExpected, "localSubscribers" .= local, "groupUnique" .= Set.size uniqueGroup, "groupDuplicates" .= duplicateGroup, "duplicateBudget" .= duplicateBudget, "groupCheckpointAtHead" .= (groupCaughtUp == Just True), "kills" .= killCount, "subscriptionRows" .= either (const Nothing) Just subscriptionRows, "eventsGrowth" .= growthValue eventGrowth, "streamEventsGrowth" .= growthValue streamEventGrowth, "streamsHotUpdateShare" .= hotShare, "appendP99Drift" .= driftValue drift])
    leak <- judgeLeaks context (soakLeakSpec profile)
    pure (applyLeakVerdict leak.verdict driftComplete)

waitForGroupCheckpoint :: KirokuStore -> Int64 -> IO Bool
waitForGroupCheckpoint store target = do
  inventory <- runStoreIO store subscriptionCheckpointInventory
  let positions = case inventory of
        Right snapshot -> [position | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == SubscriptionName "soak-group", let GlobalPosition position = row.checkpointPosition]
        Left _ -> []
  if length positions == 3 && all (>= max 0 (target - 100)) positions then pure True else threadDelay 100000 >> waitForGroupCheckpoint store target

waitForGroupCoverage :: RunContext -> FilePath -> Int64 -> IO [Int64]
waitForGroupCoverage context groupZeroPath target = do
  contents <- ByteString.readFile groupZeroPath
  let local = [fromIntegral position | line <- ByteString.lines contents, Just (position, rest) <- [ByteString.readInt line], ByteString.null rest]
  workers <- readGroupWorkerLogs context
  let positions = local <> workers
  if Set.size (Set.fromList positions) >= fromIntegral target then pure positions else threadDelay 1000000 >> waitForGroupCoverage context groupZeroPath target

readGroupWorkerLogs :: RunContext -> IO [Int64]
readGroupWorkerLogs context = do
  let directory = context.outDir </> "logs"
  entries <- listDirectory directory
  fmap concat $ forM entries \entry ->
    if ("kiroku-subscriber-1." `isPrefixOf` entry || "kiroku-subscriber-2." `isPrefixOf` entry) && ".control.jsonl" `isSuffixOf` entry
      then do
        contents <- ByteString.readFile (directory </> entry)
        pure [position | line <- ByteString.lines contents, Right (WrkCustom "delivery-latest" payload) <- [eitherDecodeStrict' line], Just position <- [parseMaybe (withObject "delivery" (.: "position")) payload]]
      else pure []

categoryCountsStatement :: Statement.Statement () [Int64]
categoryCountsStatement = Statement.preparable "select count(*) filter (where s.category='soak0'), count(*) filter (where s.category='soak1') from kiroku.stream_events se join kiroku.streams s on s.stream_id=se.original_stream_id where se.stream_id=0" Encoders.noParams (Decoders.singleRow ((\a b -> [a, b]) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

subscriptionCountStatement :: Statement.Statement () Int64
subscriptionCountStatement = Statement.preparable "select count(*) from kiroku.subscriptions" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

hotUpdateStatement :: Statement.Statement () (Int64, Int64)
hotUpdateStatement = Statement.preparable "select n_tup_hot_upd, n_tup_upd from pg_stat_user_tables where relid='kiroku.streams'::regclass" Encoders.noParams (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

growthValue :: Maybe Growth -> Value
growthValue value = case value of
  Nothing -> object ["sufficientData" .= False]
  Just growth -> object ["sufficientData" .= True, "firstBytesPerRow" .= growth.firstBytesPerRow, "lastBytesPerRow" .= growth.lastBytesPerRow, "insertedRows" .= growth.insertedRows, "linear" .= growth.linear]

driftValue :: Maybe Drift -> Value
driftValue value = case value of
  Nothing -> object ["sufficientData" .= False]
  Just drift -> object ["sufficientData" .= True, "firstP99Ns" .= drift.firstP99Ns, "lastP99Ns" .= drift.lastP99Ns, "firstSamples" .= drift.firstSamples, "lastSamples" .= drift.lastSamples, "withinFactorTwo" .= drift.withinFactorTwo]

withSoakStore :: RunContext -> (KirokuStore -> IO result) -> IO result
withSoakStore context action = case context.dimensions.tracing of
  Just TracingSdkOtlp -> case telemetrySpecFromContext context of
    Left reason -> fail (Text.unpack reason)
    Right spec -> withTelemetry spec \telemetry -> do
      handler <- composeEventHandler Nothing telemetry.tracer Nothing
      withKirokuStoreWithCallbacks context handler Nothing action
  _ -> withKirokuStore context action
