module Kenshou.Suite.Kiroku.Concurrency.KnownDefects (scenarios) where

import Control.Concurrent (forkIO, killThread, threadDelay, yield)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (forM, replicateM, replicateM_)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..), zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStore, withKirokuStoreWithDecodeHook, withKirokuStoreWithRole, withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Suite.Kiroku.Roles (appenderRoleName)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [batchSizeValidation, resizeLeavesGaps, decodeHookStallsSubscribers, reconnectCursorRegression, multiStreamFreshDeadlock]

multiStreamFreshDeadlock :: Scenario
multiStreamFreshDeadlock =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/append/concurrency/multi-stream-fresh-deadlock"),
      summary = "Races multi-stream and single-stream fresh appends while auditing transaction atomicity and deadlocks.",
      knobs = storeKnobs <> [intKnob "deadlock.rounds" 500 1 5000, intKnob "deadlock.spinners" 8 0 32],
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7" "Fresh-stream append can deadlock" ["deadlock-count-stable"] AllCohorts),
      run = runFreshDeadlock
    }

runFreshDeadlock :: RunContext -> IO ScenarioReport
runFreshDeadlock context = withKirokuStore context \store -> do
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      rounds = knob "deadlock.rounds"
      spinnerCount = knob "deadlock.spinners"
      asText (EventId uuid) = UUID.toText uuid
      status :: Maybe WorkerMessage -> Maybe Text.Text
      status (Just (WrkCustom "fresh-deadlock" value)) = parseMaybe (withObject "fresh-deadlock reply" (.: "status")) value
      status _ = Nothing
  before <- Oracle.deadlockCount store.pool
  withWorker context appenderRoleName "deadlock-multi" (object []) \multi ->
    withWorker context appenderRoleName "deadlock-single" (object []) \single -> do
      ready <- traverse (\worker -> worker.receive 10000) [multi, single]
      multi.send CtlStart
      single.send CtlStart
      bracket (replicateM spinnerCount (forkIO spin)) (traverse killThread) \_ -> do
        results <- forM [0 .. rounds - 1] \index -> do
          let a = Text.pack ("deadlock-a-" <> show index)
              b = Text.pack ("deadlock-b-" <> show index)
              payload mode ordinal = object ["mode" .= (mode :: Text.Text), "a" .= a, "b" .= b, "idA" .= asText (eventIdFor context.seed index (fromIntegral (ordinal :: Int))), "idB" .= asText (eventIdFor context.seed index (fromIntegral (ordinal + 1)))]
              multiRequest = CtlCustom "fresh-deadlock" (payload "multi" 10)
              singleRequest = CtlCustom "fresh-deadlock" (payload "single" 20)
          multi.send multiRequest
          single.send singleRequest
          multiStatus <- status <$> multi.receive 30000
          singleStatus <- status <$> single.receive 30000
          first <- runStoreIO store (getStream (StreamName a))
          second <- runStoreIO store (getStream (StreamName b))
          firstRows <- runStoreIO store (readStreamForward (StreamName a) (StreamVersion 0) 2)
          secondRows <- runStoreIO store (readStreamForward (StreamName b) (StreamVersion 0) 2)
          multi.send multiRequest
          single.send singleRequest
          multiRetry <- status <$> multi.receive 30000
          singleRetry <- status <$> single.receive 30000
          retryFirst <- runStoreIO store (readStreamForward (StreamName a) (StreamVersion 0) 2)
          retrySecond <- runStoreIO store (readStreamForward (StreamName b) (StreamVersion 0) 2)
          let aExists = case first of Right (Just value) -> value.version == StreamVersion 1; Right Nothing -> True; _ -> False
              bExists = case second of Right (Just value) -> value.version == StreamVersion 1; _ -> False
              aRows = either (const []) Vector.toList firstRows
              bRows = either (const []) Vector.toList secondRows
              batchAtomic =
                length bRows == 1 && case aRows of
                  [] -> fmap (.eventId) bRows == [eventIdFor context.seed index 21]
                  [row] -> row.eventId == eventIdFor context.seed index 10 && fmap (.eventId) bRows == [eventIdFor context.seed index 11]
                  _ -> False
              statusesOk = all (`elem` [Just "success", Just "conflict", Just "transient"]) [multiStatus, singleStatus] && Just "success" `elem` [multiStatus, singleStatus]
              retried = all (`elem` [Just "conflict", Just "duplicate"]) [multiRetry, singleRetry] && fmap (fmap (.eventId)) retryFirst == fmap (fmap (.eventId)) firstRows && fmap (fmap (.eventId)) retrySecond == fmap (fmap (.eventId)) secondRows
          pure (aExists && bExists, batchAtomic, statusesOk, retried, multiStatus, singleStatus)
        after <- Oracle.deadlockCount store.pool
        let infrastructure = all (\(exists, _, _, _, _, _) -> exists) results && all (== Just WrkReady) ready
            atomic = all (\(_, clean, _, _, _, _) -> clean) results
            statusesValid = all (\(_, _, valid, _, _, _) -> valid) results
            retriesStable = all (\(_, _, _, stable, _, _) -> stable) results
            deadlocks = max 0 (after - before)
            cells = [("workers-ready-and-streams-created", infrastructure), ("no-partial-multi-stream-commits", atomic), ("responses-classified", statusesValid), ("same-id-retries-converge", retriesStable), ("deadlock-count-stable", deadlocks == 0)]
        putSummary context Measurements "multi-stream-fresh-deadlock" (object ["rounds" .= rounds, "spinners" .= spinnerCount, "databaseDeadlocksBefore" .= before, "databaseDeadlocksAfter" .= after, "databaseDeadlocks" .= deadlocks, "transientResults" .= length [() | (_, _, _, _, left, right) <- results, Just "transient" <- [left, right]]])
        recordCells context "multi-stream-fresh-deadlock" [] cells
  where
    spin = replicateM_ 100 yield >> threadDelay 5000 >> spin

reconnectCursorRegression :: Scenario
reconnectCursorRegression =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/reconnect-cursor-regression"),
      summary = "Expects a live category subscriber to reconnect without replaying its entire live history.",
      knobs = storeKnobs <> [intKnob "workload.live-events" 5000 100 10000, intKnob "workload.after-reconnect" 100 1 1000, intKnob "kiroku.subscription.batch-size" 100 1 1000],
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size" "Category reconnect resumes from its old live cursor" ["reconnect-duplicate-bound"] AllCohorts),
      run = runReconnect
    }

runReconnect :: RunContext -> IO ScenarioReport
runReconnect context = do
  reconnects <- newIORef (0 :: Int)
  let name = SubscriptionName "reconnect-cursor"
      knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      beforeCount = knob "workload.live-events"
      afterCount = knob "workload.after-reconnect"
      batch = knob "kiroku.subscription.batch-size"
      tap = \case
        KirokuEventSubscriptionReconnecting observed _ _ | observed == name -> atomicModifyIORef' reconnects (\count -> (count + 1, ()))
        _ -> pure ()
  withKirokuStoreWithRole context "producer" \producer -> withKirokuStoreWithTap context (Just tap) \store -> do
    observed <- newIORef []
    let stream = StreamName "reconnect-events"
        event = EventData Nothing (EventType "Reconnect") (object []) Nothing Nothing Nothing
        config = (defaultSubscriptionConfig name (Category (CategoryName "reconnect")) (\row -> atomicModifyIORef' observed (\rows -> (row.globalPosition : rows, ())) >> pure Continue)) {batchSize = fromIntegral batch}
        awaitPosition target = timeout 30000000 loop
          where
            loop = do
              rows <- readIORef observed
              if GlobalPosition (fromIntegral target) `elem` rows then pure True else threadDelay 10000 >> loop
        awaitLive handle = timeout 10000000 loop
          where
            loop = do
              state <- handle.currentState
              case state of
                Just value | stateName value == "live" -> pure True
                _ -> threadDelay 10000 >> loop
    withSubscription store config \handle -> do
      live <- awaitLive handle
      firstAppend <- runStoreIO producer (appendToStream stream NoStream (replicate beforeCount event))
      firstCaughtUp <- awaitPosition beforeCount
      firstCheckpoint <- awaitCheckpoint producer name beforeCount
      killed <- terminateStoreBackends context (storeOptionsFromKnobs context "scenario").applicationName
      secondAppend <- runStoreIO producer (appendToStream stream AnyVersion (replicate afterCount event))
      secondCaughtUp <- awaitPosition (beforeCount + afterCount)
      secondCheckpoint <- awaitCheckpoint producer name (beforeCount + afterCount)
      positions <- reverse <$> readIORef observed
      reconnectCount <- readIORef reconnects
      let distinct = Set.fromList positions
          duplicates = length positions - Set.size distinct
          cells =
            [ ("entered-live", live == Just True),
              ("initial-live-history-delivered", isRight firstAppend && firstCaughtUp == Just True),
              ("pooled-backends-terminated", killed > 0),
              ("reconnect-event-observed", reconnectCount > 0),
              ("post-reconnect-events-delivered", isRight secondAppend && secondCaughtUp == Just True),
              ("all-positions-covered", distinct == Set.fromList [GlobalPosition value | value <- [1 .. fromIntegral (beforeCount + afterCount)]]),
              ("durable-checkpoint-monotonic", maybe False (>= GlobalPosition (fromIntegral beforeCount)) firstCheckpoint && maybe False (>= maybe (GlobalPosition 0) id firstCheckpoint) secondCheckpoint),
              ("reconnect-duplicate-bound", duplicates <= batch)
            ]
      putSummary context Measurements "reconnect-cursor" (object ["beforeEvents" .= beforeCount, "afterEvents" .= afterCount, "backendsTerminated" .= killed, "reconnectEpisodes" .= reconnectCount, "duplicates" .= duplicates, "batchSize" .= batch, "firstCheckpoint" .= fmap (\(GlobalPosition value) -> value) firstCheckpoint, "secondCheckpoint" .= fmap (\(GlobalPosition value) -> value) secondCheckpoint])
      recordCells context "reconnect-cursor-regression" [] cells
  where
    isRight (Right _) = True
    isRight _ = False

checkpointPositionFor :: KirokuStore -> SubscriptionName -> IO (Maybe GlobalPosition)
checkpointPositionFor store name = do
  snapshot <- runStoreIO store subscriptionCheckpointInventory
  pure case snapshot of
    Right inventory -> case [row.checkpointPosition | row <- Vector.toList inventory.checkpoints, row.subscriptionName == name] of
      position : _ -> Just position
      [] -> Nothing
    Left _ -> Nothing

awaitCheckpoint :: KirokuStore -> SubscriptionName -> Int -> IO (Maybe GlobalPosition)
awaitCheckpoint store name target = do
  result <- timeout 10000000 loop
  pure (result >>= id)
  where
    loop = do
      position <- checkpointPositionFor store name
      if maybe False (>= GlobalPosition (fromIntegral target)) position
        then pure position
        else threadDelay 10000 >> loop

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (either (error . show) id (mkKnobName key)) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

terminateStoreBackends :: RunContext -> Text.Text -> IO Int64
terminateStoreBackends context applicationName = bracket acquire Connection.release \connection -> do
  found <- Connection.use connection (Session.statement applicationName storeBackendStatement) >>= either (fail . show) pure
  killed <- forM found \pid -> do
    result <- Connection.use connection (Session.statement pid terminateStatement)
    either (fail . show) pure result
  pure (fromIntegral (length (filter id killed)))
  where
    acquire = Connection.acquire (ConnectionSettings.connectionString (requirePostgres context).adminConnectionString <> ConnectionSettings.applicationName "kenshou-kiroku-oracle") >>= either (fail . show) pure

storeBackendStatement :: Statement.Statement Text.Text [Int32]
storeBackendStatement =
  Statement.unpreparable
    "select pid from pg_stat_activity where application_name = $1 and pid <> pg_backend_pid()"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int4)))

terminateStatement :: Statement.Statement Int32 Bool
terminateStatement =
  Statement.unpreparable
    "select pg_terminate_backend($1::int4)"
    (Encoders.param (Encoders.nonNullable Encoders.int4))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

decodeHookStallsSubscribers :: Scenario
decodeHookStallsSubscribers =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/decode-hook-stalls-subscribers"),
      summary = "Expects both subscribers to progress or stop when a publisher decode hook fails.",
      phases = PhasePlan 0 60 0,
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/83-contain-persistent-publisher-decode-hook-failures" "Persistent publisher decode-hook failures leave subscribers live but stalled" ["subscriber-stalled"] AllCohorts),
      run = runDecodeHook
    }

runDecodeHook :: RunContext -> IO ScenarioReport
runDecodeHook context = do
  publisherErrors <- newIORef (0 :: Int)
  let hook row
        | row.eventType == EventType "Poison" = throwIO (userError "seeded decode-hook failure")
        | otherwise = pure row
      tap = \case
        KirokuEventPublisherLoopError _ -> atomicModifyIORef' publisherErrors (\count -> (count + 1, ()))
        _ -> pure ()
  withKirokuStoreWithDecodeHook context hook (Just tap) \store -> do
    firstSeen <- newIORef []
    secondSeen <- newIORef []
    let stream = StreamName "decode-hook-events"
        event eventType = EventData Nothing eventType (object []) Nothing Nothing Nothing
        config name ref = defaultSubscriptionConfig (SubscriptionName name) AllStreams (\row -> atomicModifyIORef' ref (\rows -> (row.globalPosition : rows, ())) >> pure Continue)
        awaitLive handles = timeout 10000000 loop
          where
            loop = do
              states <- traverse (.currentState) handles
              if all (\case Just state -> stateName state == "live"; _ -> False) states
                then pure True
                else threadDelay 10000 >> loop
        resolved handle ref = do
          positions <- readIORef ref
          finished <- timeout 1000 (wait handle)
          pure (GlobalPosition 3 `elem` positions || case finished of Just (Left _) -> True; _ -> False)
    initial <- runStoreIO store (appendToStream stream NoStream [event (EventType "Ordinary")])
    withSubscription store (config "decode-a" firstSeen) \first ->
      withSubscription store (config "decode-b" secondSeen) \second -> do
        live <- awaitLive [first, second]
        poison <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 1)) [event (EventType "Poison")])
        tailEvent <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 2)) [event (EventType "Ordinary")])
        threadDelay (round (context.phases.steadySeconds * 1000000))
        firstResolved <- resolved first firstSeen
        secondResolved <- resolved second secondSeen
        firstPositions <- readIORef firstSeen
        secondPositions <- readIORef secondSeen
        errors <- readIORef publisherErrors
        let cells =
              [ ("initial-appended", isRight initial),
                ("both-entered-live", live == Just True),
                ("poison-and-tail-appended", isRight poison && isRight tailEvent),
                ("pre-poison-delivered", GlobalPosition 1 `elem` firstPositions && GlobalPosition 1 `elem` secondPositions),
                ("subscriber-stalled", firstResolved && secondResolved)
              ]
        putSummary context Measurements "decode-hook" (object ["publisherLoopErrors" .= errors, "firstPositions" .= fmap (\(GlobalPosition value) -> value) (reverse firstPositions), "secondPositions" .= fmap (\(GlobalPosition value) -> value) (reverse secondPositions), "firstResolved" .= firstResolved, "secondResolved" .= secondResolved])
        recordCells context "decode-hook-stalls-subscribers" [] cells
  where
    isRight (Right _) = True
    isRight _ = False

resizeLeavesGaps :: Scenario
resizeLeavesGaps =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/consumer-group/concurrency/resize-leaves-gaps"),
      summary = "Expects a resized consumer group to cover every event or reject the topology change.",
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps" "Consumer-group resize can skip events" ["coverage-or-topology-refusal"] AllCohorts),
      run = runResize
    }

runResize :: RunContext -> IO ScenarioReport
runResize context = withKirokuStore context \store -> do
  let name = SubscriptionName "resize-gap"
      event = EventData Nothing (EventType "Resize") (object []) Nothing Nothing Nothing
      config size member ref =
        (defaultSubscriptionConfig name AllStreams (\row -> atomicModifyIORef' ref (\rows -> (row.globalPosition : rows, ())) >> pure Continue))
          { consumerGroup = Just (ConsumerGroup member size)
          }
      awaitHead members = timeout 30000000 loop
        where
          loop = do
            inventory <- runStoreIO store subscriptionCheckpointInventory
            let positions = case inventory of
                  Right snapshot -> [(row.consumerGroupMember, row.checkpointPosition) | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name]
                  Left _ -> []
            if all (\member -> lookup member positions == Just (GlobalPosition 200)) members
              then pure True
              else threadDelay 10000 >> loop
      awaitLive handles = timeout 10000000 loop
        where
          loop = do
            states <- traverse (.currentState) handles
            if all (\case Just state -> stateName state == "live"; _ -> False) states
              then pure True
              else threadDelay 10000 >> loop
      withMembers [] action = action []
      withMembers ((member, ref) : rest) action = withSubscription store (config 3 member ref) \handle -> withMembers rest (\handles -> action (handle : handles))
  seeded <- forM [0 .. 199 :: Int] \index -> runStoreIO store (appendToStream (StreamName ("resize-" <> Text.pack (show index))) NoStream [event])
  firstRef <- newIORef []
  firstCaughtUp <- withSubscription store (config 2 0 firstRef) \_ -> awaitHead [0]
  firstRows <- readIORef firstRef
  refs <- forM [0 .. 2] \member -> (member,) <$> newIORef []
  resized <- try @SomeException (withMembers refs awaitLive)
  laterRows <- fmap concat (traverse (readIORef . snd) refs)
  let refused = case resized of Left _ -> True; _ -> False
      allSeen = Set.fromList (firstRows <> laterRows)
      cells =
        [ ("seeded-200-streams", length seeded == 200 && all isRight seeded),
          ("initial-member-checkpoint-head", firstCaughtUp == Just True),
          ("resized-members-live", refused || case resized of Right (Just True) -> True; _ -> False),
          ("coverage-or-topology-refusal", refused || allSeen == Set.fromList [GlobalPosition value | value <- [1 .. 200]])
        ]
  putSummary context Measurements "resize-leaves-gaps" (object ["firstMemberDeliveries" .= length firstRows, "totalDistinctDelivered" .= Set.size allSeen, "topologyRefused" .= refused])
  recordCells context "resize-leaves-gaps" [] cells
  where
    isRight (Right _) = True
    isRight _ = False

batchSizeValidation :: Scenario
batchSizeValidation =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/batch-size-validation"),
      revision = 1,
      summary = "Expects zero and negative subscription batch sizes to be rejected promptly.",
      tier = TierStandard,
      placement = PlaceEither,
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
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size" "Subscription accepts invalid batch sizes" ["zero-refused", "negative-refused"] AllCohorts),
      run = runBatchSizeValidation
    }

runBatchSizeValidation :: RunContext -> IO ScenarioReport
runBatchSizeValidation context = withKirokuStore context \store -> do
  let event = EventData Nothing (EventType "InvalidBatch") (object []) Nothing Nothing Nothing
  seeded <- runStoreIO store (appendToStream (StreamName "invalid-batch-events") NoStream [event])
  (zeroRefused, zeroCalls) <- probe store (SubscriptionName "invalid-batch-zero") 0
  (negativeRefused, negativeCalls) <- probe store (SubscriptionName "invalid-batch-negative") (-1)
  putSummary context Measurements "batch-size-validation" (object ["zeroRefused" .= zeroRefused, "zeroHandlerCalls" .= zeroCalls, "negativeRefused" .= negativeRefused, "negativeHandlerCalls" .= negativeCalls])
  recordCells
    context
    "batch-size-validation"
    []
    [ ("seeded-event", case seeded of Right _ -> True; _ -> False),
      ("zero-refused", zeroRefused && zeroCalls == 0),
      ("negative-refused", negativeRefused && negativeCalls == 0)
    ]

probe :: KirokuStore -> SubscriptionName -> Int32 -> IO (Bool, Int)
probe store name size = do
  calls <- newIORef (0 :: Int)
  let handler _ = atomicModifyIORef' calls (\count -> (count + 1, ())) >> pure Continue
      config = (defaultSubscriptionConfig name AllStreams handler) {batchSize = size}
  started <- try @SomeException (subscribe store config)
  refused <- case started of
    Left _ -> pure True
    Right handle -> do
      outcome <- timeout 5000000 (wait handle)
      handle.cancel
      pure (case outcome of Just (Left _) -> True; _ -> False)
  delivered <- readIORef calls
  pure (refused, delivered)
