module Kenshou.Suite.Kiroku.Concurrency.Fault (scenarios) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Check.Fault.Network (ProxyMode (..), proxiedConnectionString, resetConnections, setProxyMode, withTcpProxy)
import Kenshou.Check.Fault.Postgres (Backend (..), listBackends)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (Environment (..), RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..), zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario
import Kenshou.Diagnose.Stall qualified as Stall
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore, withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [postgresRestart, listenKillAndNotifyLoss, networkPartition, allLockHold]

postgresRestart :: Scenario
postgresRestart =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/postgres-restart"),
      revision = 1,
      summary = "Restarts an ephemeral PostgreSQL server during appends and subscription delivery.",
      tier = TierStandard,
      placement = PlaceLocal,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runRestart
    }

runRestart :: RunContext -> IO ScenarioReport
runRestart context = case context.env.postgres >>= (.control) of
  Nothing -> pure (failedWith ["no-postgres-control"] "postgres-restart requires an ephemeral local PostgreSQL server")
  Just control -> withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let batches = 100
        batchSize = 10
        eventIds index = [eventIdFor context.seed index (fromIntegral ordinal) | ordinal <- [0 .. batchSize - 1]]
        appendBatch index = do
          let stream = StreamName ("restart-" <> Text.pack (show index))
              events = [EventData (Just eventId) (EventType "Restart") (object []) Nothing Nothing Nothing | eventId <- eventIds index]
              attempt n errors
                | n >= (500 :: Int) = pure (False, reverse errors)
                | otherwise = do
                    response <- try @SomeException (runStoreIO store (appendToStream stream NoStream events))
                    case response of
                      Right (Right _) -> pure (True, reverse errors)
                      Right (Left err) -> retry n errors (Text.pack (show err))
                      Left err -> retry n errors (Text.pack (show err))
              retry n errors reason = do
                observed <- try @SomeException (runStoreIO store (readStreamForward stream (StreamVersion 0) (fromIntegral (batchSize + 1))))
                let exact = case observed of Right (Right rows) -> fmap (.eventId) (Vector.toList rows) == eventIds index; _ -> False
                if exact then pure (True, reverse (reason : errors)) else threadDelay 10000 >> attempt (n + 1) (reason : errors)
          result <- attempt 0 []
          threadDelay 5000
          pure result
        deliveries child = do
          state <- atomically (progress child)
          let records = [record | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just record <- [parseMaybe (withObject "delivery" (\row -> (,) <$> row .: "sequence" <*> row .: "position")) payload :: Maybe (Int, Int64)]]
          pure [position | (_, position) <- sort records]
        awaitCoverage child = do
          observed <- deliveries child
          if Set.size (Set.fromList observed) >= batches * batchSize then pure observed else threadDelay 10000 >> awaitCoverage child
        awaitNextDelivery child previous = do
          observed <- deliveries child
          if length observed > previous then pure () else threadDelay 10000 >> awaitNextDelivery child previous
    spec <- roleProcess check "kiroku/subscriber" 0 (object ["name" .= ("postgres-restart" :: Text), "guard" .= False, "emitDeliveries" .= True])
    child <- spawn supervisor spec
    awaitReady child 10000
    sendCommand child CtlStart
    initialCheckpoints <- Oracle.checkpoints store.pool
    results <- newEmptyMVar
    _ <- forkIO (traverse appendBatch [0 .. batches - 1] >>= putMVar results)
    threadDelay 150000
    control.restartServer
    afterFast <- getCurrentTime
    threadDelay 150000
    beforeImmediateCheckpoints <- Oracle.checkpoints store.pool
    beforeImmediate <- length <$> deliveries child
    control.stopServer StopImmediate
    control.startServer
    afterImmediate <- getCurrentTime
    firstDelivery <- timeout 90000000 (awaitNextDelivery child beforeImmediate)
    firstDeliveryAt <- getCurrentTime
    firstDeliveryCheckpoints <- Oracle.checkpoints store.pool
    appendResults <- takeMVar results
    delivered <- timeout 180000000 (awaitCoverage child)
    recoveredAt <- getCurrentTime
    durable <- runStoreIO store (readAllForward (GlobalPosition 0) (fromIntegral (batches * batchSize + 1)))
    checkpoints <- Oracle.checkpoints store.pool
    counts <- Oracle.threeCounts store.pool
    let expectedIds = Set.fromList [uuid | index <- [0 .. batches - 1], EventId uuid <- eventIds index]
        actualIds = case durable of Right rows -> Set.fromList [uuid | row <- Vector.toList rows, let EventId uuid = row.eventId]; Left _ -> Set.empty
        positions = maybe [] id delivered
        checkpointOf rows = maximum (0 : [position | (name, member, position) <- rows, name == "postgres-restart", member == 0])
        checkpointSamples = map checkpointOf [initialCheckpoints, beforeImmediateCheckpoints, firstDeliveryCheckpoints, checkpoints]
        finalCheckpoint = last checkpointSamples
        duplicates = length positions - Set.size (Set.fromList positions)
        errors = concatMap snd appendResults
        errorConstructors = Map.toList (Map.fromListWith (+) [(Text.takeWhile (/= ' ') err, 1 :: Int) | err <- errors])
        cells =
          [ ("append-retries-converged", all fst appendResults),
            ("acknowledged-identifiers-durable", actualIds == expectedIds),
            ("subscriber-covers-all", Set.fromList positions == Set.fromList [1 .. fromIntegral (batches * batchSize)]),
            ("subscriber-order", positions == sort positions),
            ("checkpoint-reaches-head", finalCheckpoint == fromIntegral (batches * batchSize)),
            ("checkpoint-samples-monotonic", checkpointSamples == sort checkpointSamples),
            ("duplicates-within-restart-budgets", duplicates <= 2000),
            ("durable-counts-agree", counts == (fromIntegral (batches * batchSize), fromIntegral (batches * batchSize), fromIntegral (batches * batchSize))),
            ("first-delivery-within-ninety-seconds", firstDelivery == Just () && diffUTCTime firstDeliveryAt afterImmediate <= 90)
          ]
    putSummary context Measurements "postgres-restart" (object ["batches" .= batches, "events" .= (batches * batchSize), "retryErrors" .= errors, "errorConstructors" .= errorConstructors, "delivered" .= length positions, "duplicates" .= duplicates, "checkpointSamples" .= checkpointSamples, "afterFast" .= afterFast, "afterImmediate" .= afterImmediate, "firstDeliveryAt" .= firstDeliveryAt, "recoveredAt" .= recoveredAt])
    recordCells context "postgres-restart" [] cells

listenKillAndNotifyLoss :: Scenario
listenKillAndNotifyLoss =
  postgresRestart
    { id = either (error . show) id (parseScenarioId "kiroku/notifier/concurrency/listen-kill-and-notify-loss"),
      summary = "Kills listener backends, suppresses notifications, and checks all three live subscription paths.",
      phases = PhasePlan 0 180 0,
      run = runListenKill
    }

runListenKill :: RunContext -> IO ScenarioReport
runListenKill context = do
  reconnects <- newIORef (0 :: Int)
  reconnecting <- newIORef (0 :: Int)
  reconnectTimesRef <- newIORef ([] :: [UTCTime])
  let tap event = case event of
        KirokuEventNotifierReconnecting _ _ -> atomicModifyIORef' reconnecting (\count -> (count + 1, ()))
        KirokuEventNotifierReconnected -> do
          now <- getCurrentTime
          atomicModifyIORef' reconnects (\count -> (count + 1, ()))
          atomicModifyIORef' reconnectTimesRef (\times -> (now : times, ()))
        _ -> pure ()
  withKirokuStoreWithTap context (Just tap) \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let names = ["listen-all", "listen-category", "listen-group"] :: [Text]
        args name = object (["name" .= name, "guard" .= False, "emitDeliveries" .= True, "target" .= (if name == "listen-category" then "category" else "all" :: Text)] <> if name == "listen-group" then ["member" .= (0 :: Int), "size" .= (1 :: Int)] else [])
        entries child = do
          state <- atomically (progress child)
          let rows = [row | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just row <- [parseMaybe (withObject "delivery" (\value -> (,,) <$> value .: "sequence" <*> value .: "position" <*> value .: "receivedAt")) payload :: Maybe (Int, Int64, UTCTime)]]
          pure [(position, receivedAt) | (_, position, receivedAt) <- sort rows]
        awaitHead child headPosition = do
          rows <- entries child
          if Set.fromList (map fst rows) == Set.fromList [1 .. headPosition]
            then pure rows
            else threadDelay 10000 >> awaitHead child headPosition
        checkpoint name rows = maximum (0 : [position | (rowName, member, position) <- rows, rowName == name, member == 0])
    children <- forM (zip [0 ..] names) \(index, name) -> do
      spec <- roleProcess check "kiroku/subscriber" index (args name)
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      pure child
    before <- Oracle.checkpoints store.pool
    producedVar <- newEmptyMVar
    _ <- forkIO do
      rows <- forM [0 .. 899] \index -> do
        let event = EventData (Just (eventIdFor context.seed index 0)) (EventType "NotifyFault") (object []) Nothing Nothing Nothing
        result <- runStoreIO store (appendToStream (StreamName "crash-notify") AnyVersion [event])
        committedAt <- getCurrentTime
        threadDelay 200000
        pure (result, committedAt)
      putMVar producedVar rows
    kills <- forM [1 .. (3 :: Int)] \_ -> do
      threadDelay 20000000
      killListenerBackends context
    afterKills <- Oracle.checkpoints store.pool
    (disabledAt, disabledTriggers) <- bracket (setNotifyTriggers context False >> getCurrentTime) (const (setNotifyTriggers context True)) \stamp -> do
      states <- notifyTriggerStates context
      threadDelay 70000000
      pure (stamp, states)
    enabledAt <- getCurrentTime
    enabledTriggers <- notifyTriggerStates context
    afterSilence <- Oracle.checkpoints store.pool
    threadDelay 50000000
    produced <- takeMVar producedVar
    let positions = [position | (Right result, _) <- produced, let GlobalPosition position = result.globalPosition]
        headPosition = maximum (0 : positions)
        phaseB = [(position, committedAt) | (Right result, committedAt) <- produced, let GlobalPosition position = result.globalPosition, committedAt >= disabledAt, committedAt <= enabledAt]
    deliveries <- forM children \child -> timeout 45000000 (awaitHead child headPosition)
    final <- Oracle.checkpoints store.pool
    reconnectCount <- readIORef reconnects
    reconnectingCount <- readIORef reconnecting
    reconnectTimes <- reverse <$> readIORef reconnectTimesRef
    let deliveredRows = [maybe [] id rows | rows <- deliveries]
        checkpoints = [[checkpoint name sample | sample <- [before, afterKills, afterSilence, final]] | name <- names]
        complete = all (\rows -> Set.fromList (map fst rows) == Set.fromList [1 .. headPosition]) deliveredRows
        ordered = all (\rows -> map fst rows == sort (map fst rows)) deliveredRows
        withinPoll rows = all (\(position, committedAt) -> maybe False (\receivedAt -> diffUTCTime receivedAt committedAt <= 35) (lookup position rows)) phaseB
        phaseBDelays rows = [realToFrac (diffUTCTime receivedAt committedAt) :: Double | (position, committedAt) <- phaseB, Just receivedAt <- [lookup position rows]]
        reconnectDelays rows = [realToFrac (diffUTCTime receivedAt committedAt) :: Double | restartedAt <- reconnectTimes, Just (position, committedAt) <- [findAfter restartedAt produced], Just receivedAt <- [lookup position rows]]
        findAfter restartedAt = foldr (\(result, committedAt) next -> case result of Right appendResult | committedAt >= restartedAt -> let GlobalPosition position = appendResult.globalPosition in Just (position, committedAt); _ -> next) Nothing
        cells =
          [ ("all-appends-acknowledged", length positions == 900),
            ("notification-outage-had-events", not (null phaseB)),
            ("listener-backends-terminated", all (> 0) kills),
            ("notifier-reconnect-observed", reconnectingCount > 0 && reconnectCount > 0),
            ("notification-triggers-disabled", length disabledTriggers == 2 && all ((== "D") . snd) disabledTriggers),
            ("notification-triggers-restored", length enabledTriggers == 2 && all ((== "O") . snd) enabledTriggers),
            ("three-path-coverage", complete),
            ("three-path-order", ordered),
            ("checkpoints-monotonic", all (\sample -> sample == sort sample) checkpoints),
            ("checkpoints-reach-head", all (\sample -> last sample == headPosition) checkpoints),
            ("notifications-lost-but-safety-poll-catches-up", all withinPoll deliveredRows)
          ]
    putSummary context Measurements "listen-kill-and-notify-loss" (object ["kills" .= kills, "reconnectingEvents" .= reconnectingCount, "reconnectedEvents" .= reconnectCount, "events" .= length positions, "phaseBEvents" .= length phaseB, "maxSafetyPollDelaySeconds" .= map (maximum . (0 :) . phaseBDelays) deliveredRows, "afterReconnectDeliverySeconds" .= map reconnectDelays deliveredRows, "delivered" .= map length deliveredRows, "checkpointSamples" .= checkpoints, "disabledAt" .= disabledAt, "enabledAt" .= enabledAt, "disabledTriggers" .= disabledTriggers, "enabledTriggers" .= enabledTriggers])
    recordCells context "listen-kill-and-notify-loss" [] cells

networkPartition :: Scenario
networkPartition =
  postgresRestart
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/network-partition"),
      revision = 4,
      summary = "Resets, blackholes, and delays proxied subscription connections while direct appends continue.",
      placement = PlaceLocal,
      knobs = [if spec.name == keepaliveName then spec {def = VBool True} else spec | spec <- storeKnobs],
      knownDefect = Nothing,
      run = runNetworkPartition
    }
  where
    keepaliveName = either (error . show) id (mkKnobName "kiroku.conn.keepalives")

runNetworkPartition :: RunContext -> IO ScenarioReport
runNetworkPartition context = case (requirePostgres context).tcpEndpoint of
  Nothing -> pure (failedWith ["tcp-endpoint-unavailable"] "network-partition requires a PostgreSQL TCP endpoint")
  Just (host, port) -> withTcpProxy (pure (Text.unpack host, fromIntegral port)) \proxy -> do
    let postgres = requirePostgres context
        keepalives = knobBool context.knobs (either (error . show) id (mkKnobName "kiroku.conn.keepalives"))
        connection = proxiedConnectionString postgres proxy <> if keepalives then " keepalives=1 keepalives_idle=5 keepalives_interval=2 keepalives_count=3 tcp_user_timeout=10000" else ""
        proxiedPostgres = postgres {connectionString = connection}
        proxiedContext = context {env = context.env {postgres = Just proxiedPostgres}}
    withKirokuStore context \store -> withCheck proxiedContext \check -> withSupervisor check \supervisor -> do
      let names = ["network-all", "network-category", "network-group"] :: [Text]
          args name = object (["name" .= name, "guard" .= False, "emitDeliveries" .= True, "emitRuntimeEvents" .= True, "target" .= (if name == "network-category" then "category" else "all" :: Text)] <> if name == "network-group" then ["member" .= (0 :: Int), "size" .= (1 :: Int)] else [])
          entries child = do
            state <- atomically (progress child)
            let rows = [row | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just row <- [parseMaybe (withObject "delivery" (\value -> (,) <$> value .: "sequence" <*> value .: "position")) payload :: Maybe (Int, Int64)]]
            pure [position | (_, position) <- sort rows]
          awaitHead child target = do
            rows <- entries child
            if Set.fromList rows == Set.fromList [1 .. target] then pure rows else threadDelay 10000 >> awaitHead child target
          appendRange first lastIndex = forM [first .. lastIndex] \index -> do
            let event = EventData (Just (eventIdFor context.seed index 0)) (EventType "Partition") (object []) Nothing Nothing Nothing
            runStoreIO store (appendToStream (StreamName "crash-network") AnyVersion [event])
          checkpoint name rows = maximum (0 : [position | (rowName, member, position) <- rows, rowName == name, member == 0])
          coverage children target = do
            _ <- timeout 60000000 (traverse (\child -> awaitHead child target) children)
            map Just <$> traverse entries children
      children <- forM (zip [0 ..] names) \(index, name) -> do
        spec <- roleProcess check "kiroku/subscriber" index (args name)
        child <- spawn supervisor spec
        awaitReady child 10000
        sendCommand child CtlStart
        pure child
      initial <- Oracle.checkpoints store.pool
      baselineWrites <- appendRange 0 99
      baseline <- coverage children 100
      resetCount <- resetConnections proxy
      resetWrites <- appendRange 100 199
      threadDelay 5000000
      afterReset <- traverse entries children
      resetObservedAt <- getCurrentTime
      afterResetCheckpoints <- Oracle.checkpoints store.pool
      setProxyMode proxy Blackhole
      blackholeStarted <- getCurrentTime
      partitionWrites <- appendRange 200 299
      threadDelay 20000000
      duringBlackhole <- traverse entries children
      setProxyMode proxy Forward
      blackholeResetCount <- resetConnections proxy
      forwardAt <- getCurrentTime
      afterPartition <- coverage children 300
      partitionRecoveredAt <- getCurrentTime
      setProxyMode proxy (Latency 50)
      latencyStarted <- getCurrentTime
      latencyWrites <- appendRange 300 319
      afterLatency <- coverage children 320
      latencyCompleted <- getCurrentTime
      setProxyMode proxy Forward
      _ <- timeout 30000000 (awaitCheckpointHead store names 320)
      final <- Oracle.checkpoints store.pool
      let written = baselineWrites <> resetWrites <> partitionWrites <> latencyWrites
          delivered = [maybe [] id rows | rows <- afterLatency]
          sampleRows = [initial, afterResetCheckpoints, final]
          checkpoints = [[checkpoint name sample | sample <- sampleRows] | name <- names]
          waitedAfterForwardSeconds = realToFrac (diffUTCTime partitionRecoveredAt forwardAt) :: Double
          partitionCompleteAtDeadline = all (maybe False ((== 300) . Set.size . Set.fromList)) afterPartition
          cells =
            [ ("all-direct-appends-acknowledged", length written == 320 && all isRight written),
              ("baseline-delivered", all (maybe False ((== 100) . Set.size . Set.fromList)) baseline),
              ("reset-connections", resetCount > 0 && blackholeResetCount > 0),
              ("blackhole-blocks-proxy", all (\rows -> maximum (0 : rows) <= 200) duringBlackhole),
              ("keepalive-recovery-within-sixty-seconds", not keepalives || partitionCompleteAtDeadline),
              ("all-three-paths-delivered", all (\rows -> Set.fromList rows == Set.fromList [1 .. 320]) delivered),
              ("all-and-group-ordered", case delivered of [allRows, _, groupRows] -> allRows == sort allRows && groupRows == sort groupRows; _ -> False),
              ("category-order-after-reconnect", case delivered of [_, categoryRows, _] -> categoryRows == sort categoryRows; _ -> False),
              ("checkpoints-monotonic-to-head", all (\samples -> samples == sort samples && last samples == 320) checkpoints)
            ]
      putSummary context Measurements "network-partition" (object ["keepalives" .= keepalives, "resetConnections" .= resetCount, "blackholeResetConnections" .= blackholeResetCount, "resetDistinctAfterFiveSeconds" .= map (Set.size . Set.fromList) afterReset, "blackholeStarted" .= blackholeStarted, "forwardAt" .= forwardAt, "resetObservedAt" .= resetObservedAt, "distinctAtRecoveryDeadline" .= map (maybe 0 (Set.size . Set.fromList)) afterPartition, "waitedAfterForwardSeconds" .= waitedAfterForwardSeconds, "latencyStageSeconds" .= (realToFrac (diffUTCTime latencyCompleted latencyStarted) :: Double), "delivered" .= map length delivered, "checkpointSamples" .= checkpoints])
      recordCells context "network-partition" ["keepalive-recovery-within-sixty-seconds", "category-order-after-reconnect"] cells

awaitCheckpointHead :: KirokuStore -> [Text] -> Int64 -> IO ()
awaitCheckpointHead store names target = do
  rows <- Oracle.checkpoints store.pool
  let current name = maximum (0 : [position | (rowName, member, position) <- rows, rowName == name, member == 0])
  if all ((>= target) . current) names then pure () else threadDelay 10000 >> awaitCheckpointHead store names target

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False

allLockHold :: Scenario
allLockHold =
  postgresRestart
    { id = either (error . show) id (parseScenarioId "kiroku/transaction/concurrency/all-lock-hold"),
      summary = "Kills a transaction continuation while it holds the global append lock.",
      knobs = storeKnobs <> [KnobSpec sleepName "Time the continuation holds the global lock" KnobInt (VInt 200) (IntRange 100 5000) []],
      run = runAllLockHold
    }
  where
    sleepName = either (error . show) id (mkKnobName "kiroku.tx.continuation-sleep-ms")

runAllLockHold :: RunContext -> IO ScenarioReport
runAllLockHold context = Stall.withWatchdog context watchdogConfig \watchdog -> withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
  let sleepMs = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "kiroku.tx.continuation-sleep-ms"))) :: Int
  created <- runStoreIO store (runTransaction (Tx.sql "create schema if not exists kenshou_kiroku; create table if not exists kenshou_kiroku.tx_hold_probe (value int not null)"))
  case created of
    Left err -> pure (failedWith ["probe-schema-failed"] (Text.pack (show err)))
    Right () -> do
      spec <- roleProcess check "kiroku/tx-appender" 0 (object [])
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child (CtlCustom "hold" (object ["sleepMs" .= sleepMs]))
      awaitMark child "hold-start" 10000
      holder <- timeout 5000000 (awaitSleepingBackend context)
      replies <- forM [0 .. (2 :: Int)] \index -> do
        reply <- newEmptyMVar
        _ <- forkIO do
          let event = EventData (Just (eventIdFor context.seed (index + 1) 0)) (EventType "PlainAfterHold") (object []) Nothing Nothing Nothing
          result <- runStoreIO store (appendToStream (StreamName ("plain-" <> Text.pack (show index))) NoStream [event])
          finishedAt <- getCurrentTime
          putMVar reply (result, finishedAt)
        pure reply
      blocker <- case holder of
        Nothing -> pure 0
        Just backend -> maybe 0 id <$> timeout (min 100000 (sleepMs * 500)) (awaitBlockedAppender context backend.pid)
      diagnosis <-
        if sleepMs >= 1000 && blocker > 0
          then threadDelay 300000 >> Just <$> Stall.captureNow watchdog "plain appenders waiting behind the transaction continuation"
          else pure Nothing
      premature <- traverse tryReadMVar replies
      killedAt <- getCurrentTime
      killChild supervisor child
      results <- timeout 10000000 (traverse takeMVar replies)
      recoveredAt <- getCurrentTime
      durable <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
      probeCount <- Pool.use store.pool (Session.statement () probeCountStatement) >>= either (fail . show) pure
      counts <- Oracle.threeCounts store.pool
      let rows = case durable of Right events -> Vector.toList events; Left _ -> []
          positions = [position | row <- rows, let GlobalPosition position = row.globalPosition]
          ids = Set.fromList [uuid | row <- rows, let EventId uuid = row.eventId]
          expectedIds = Set.fromList [uuid | index <- [1 .. 3], EventId uuid <- [eventIdFor context.seed index 0]]
          resultRows = maybe [] id results
          cells =
            [ ("hold-backend-entered-continuation", maybe False (const True) holder),
              ("plain-appenders-blocked-by-holder", blocker > 0 && all (maybe True (const False)) premature),
              ("killed-transaction-rolled-back", probeCount == 0 && ids == expectedIds),
              ("plain-appends-resumed-within-ten-seconds", length resultRows == 3 && all (isRight . fst) resultRows && diffUTCTime recoveredAt killedAt <= 10),
              ("global-order-and-counts", positions == [1, 2, 3] && counts == (3, 3, 3))
            ]
              <> [("watchdog-classifies-lock-wait", maybe False ((== Stall.LockWait) . (.classification)) diagnosis) | sleepMs >= 1000]
      putSummary context Measurements "all-lock-hold" (object ["sleepMs" .= sleepMs, "holderPid" .= fmap (.pid) holder, "blockedAppenders" .= blocker, "prematureCompletions" .= length [() | Just _ <- premature], "probeRows" .= probeCount, "durablePositions" .= positions, "killedAt" .= killedAt, "recoveredAt" .= recoveredAt, "stallClassification" .= fmap (Stall.stallClassText . (.classification)) diagnosis])
      recordCells context "all-lock-hold" ["plain-appenders-blocked-by-holder"] cells
  where
    watchdogConfig = Stall.defaultWatchdogConfig {Stall.deadlineSeconds = 0.2, Stall.maxCaptures = 0, Stall.onStall = Stall.CaptureAndContinue, Stall.postgres = Just (requirePostgres context).connectionString, Stall.captureStacks = False, Stall.spinProbeSeconds = 0.05}

awaitSleepingBackend :: RunContext -> IO Backend
awaitSleepingBackend context = do
  backends <- listBackends (requirePostgres context)
  case [backend | backend <- backends, backend.applicationName == "kenshou-tx-appender", "pg_sleep" `Text.isInfixOf` backend.query, backend.state == "active"] of
    backend : _ -> pure backend
    [] -> threadDelay 1000 >> awaitSleepingBackend context

awaitBlockedAppender :: RunContext -> Int32 -> IO Int64
awaitBlockedAppender context holderPid = do
  blocked <- withAdmin context \connection -> Connection.use connection (Session.statement holderPid blockingStatement) >>= either (fail . show) pure
  if blocked > 0 then pure blocked else threadDelay 1000 >> awaitBlockedAppender context holderPid

blockingStatement :: Statement.Statement Int32 Int64
blockingStatement =
  Statement.unpreparable
    "select count(*) from pg_stat_activity where wait_event_type = 'Lock' and $1::int4 = any(pg_blocking_pids(pid))"
    (Encoders.param (Encoders.nonNullable Encoders.int4))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

probeCountStatement :: Statement.Statement () Int64
probeCountStatement =
  Statement.unpreparable
    "select count(*) from kenshou_kiroku.tx_hold_probe"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

killListenerBackends :: RunContext -> IO Int
killListenerBackends context = withAdmin context \connection -> do
  pids <- Connection.use connection (Session.statement () listenerPidsStatement) >>= either (fail . show) pure
  results <- forM pids \pid -> Connection.use connection (Session.statement pid terminateStatement) >>= either (fail . show) pure
  pure (length (filter id results))

setNotifyTriggers :: RunContext -> Bool -> IO ()
setNotifyTriggers context enabled = withAdmin context \connection -> do
  let commands = if enabled then [enableInsert, enableUpdate] else [disableInsert, disableUpdate]
  mapM_ (\command -> Connection.use connection (Session.statement () command) >>= either (fail . show) pure) commands
  where
    disableInsert = Statement.unpreparable "alter table kiroku.streams disable trigger stream_events_notify_insert" Encoders.noParams Decoders.noResult
    disableUpdate = Statement.unpreparable "alter table kiroku.streams disable trigger stream_events_notify_update" Encoders.noParams Decoders.noResult
    enableInsert = Statement.unpreparable "alter table kiroku.streams enable trigger stream_events_notify_insert" Encoders.noParams Decoders.noResult
    enableUpdate = Statement.unpreparable "alter table kiroku.streams enable trigger stream_events_notify_update" Encoders.noParams Decoders.noResult

notifyTriggerStates :: RunContext -> IO [(Text, Text)]
notifyTriggerStates context = withAdmin context \connection ->
  Connection.use connection (Session.statement () triggerStateStatement) >>= either (fail . show) pure

triggerStateStatement :: Statement.Statement () [(Text, Text)]
triggerStateStatement =
  Statement.unpreparable
    "select tgname::text, tgenabled::text from pg_trigger where tgrelid = 'kiroku.streams'::regclass and tgname like 'stream_events_notify%' order by tgname"
    Encoders.noParams
    (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.text)))

withAdmin :: RunContext -> (Connection.Connection -> IO result) -> IO result
withAdmin context action = bracket acquire Connection.release action
  where
    acquire = Connection.acquire (ConnectionSettings.connectionString (requirePostgres context).adminConnectionString <> ConnectionSettings.applicationName "kenshou-kiroku-fault-oracle") >>= either (fail . show) pure

listenerPidsStatement :: Statement.Statement () [Int32]
listenerPidsStatement =
  Statement.unpreparable
    "select pid from pg_stat_activity where application_name = 'kiroku-listener' and pid <> pg_backend_pid()"
    Encoders.noParams
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int4)))

terminateStatement :: Statement.Statement Int32 Bool
terminateStatement =
  Statement.unpreparable
    "select pg_terminate_backend($1::int4)"
    (Encoders.param (Encoders.nonNullable Encoders.int4))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))
