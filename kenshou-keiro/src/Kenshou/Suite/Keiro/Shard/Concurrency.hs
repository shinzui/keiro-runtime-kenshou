module Kenshou.Suite.Keiro.Shard.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Subscription.Shard (ownershipSnapshotFor)
import Kenshou.Check.Fact (Fact (..), FactKind (..), ProcId (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (ChildSignal (..), ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, signalChild, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobDouble, knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardKnobs)
import Kenshou.Suite.Keiro.Shard.Oracle (ShardTiming (..), checkpointsMonotonic, failoverDeadline, recordShardCells, recordShardTimingCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, ensureDurableTables, runDurable, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO, runTransaction)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [lateJoinerGetsNoBuckets, sigkillFailoverVsGracefulRelinquish, coverageAfterMembershipChange, fairShareShedding, zombiePastLeaseTtl]

zombiePastLeaseTtl :: Scenario
zombiePastLeaseTtl =
  lateJoinerGetsNoBuckets
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/zombie-past-lease-ttl"),
      summary = "Pauses a shard owner beyond lease expiry, resumes it, and checks checkpoint direction and the duplicate window.",
      knownDefect = Nothing,
      run = runZombie
    }

runZombie :: RunContext -> IO ScenarioReport
runZombie context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    ensureDurableTables fixture
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardZombie"
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        leaseMicros = round (knobDouble context.knobs (shardKnobName "shard.lease-ttl-seconds") * 1000000)
        renewMicros = round (knobDouble context.knobs (shardKnobName "shard.renew-interval-seconds") * 1000000)
        eventCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.events")) :: Int
        streamCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.streams")) :: Int
        ownership = runStoreIO store (ownershipSnapshotFor name)
        checkpoints = runDurable fixture (runTransaction (Tx.statement "kenshouShardZombie" checkpointStatement))
        sinkCount = runDurable fixture (runTransaction (Tx.statement () sinkCountStatement))
        covered result = case result of Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner /= Nothing) rows; Left _ -> False
        owners result = case result of Right rows -> Set.fromList [owner | (_, Just owner, _) <- rows]; Left _ -> Set.empty
        transferred before after = covered after && Set.null (Set.intersection (owners before) (owners after))
    (initial, lost, ownershipAfterLoss, resumedOwnership, checkpointSamples, appenderDone, drained, continueAt) <- withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "keiro/shard-worker" 0 (object ["subscription" .= ("kenshouShardZombie" :: Text), "shardCount" .= bucketCount, "delivery" .= True, "handlerDelayMicros" .= (3000000 :: Int)])
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      initial <- waitUntil (covered <$> ownership) 160
      before <- ownership
      appenderSpec <- roleProcess check "keiro/shard-appender" 0 (object ["eventCount" .= eventCount, "streamCount" .= streamCount, "idPrefix" .= ("kenshou:shard:zombie:" :: Text), "streamPrefix" .= ("account-zombie-" :: Text), "pauseMicros" .= (1000 :: Int)])
      appender <- spawn supervisor appenderSpec
      awaitReady appender 10000
      sendCommand appender CtlStart
      _ <- waitUntil (any (Text.isPrefixOf "delivery-start-") . Map.keys . (.marks) <$> atomically (progress first)) 80
      c0 <- checkpoints
      signalChild supervisor first Stop
      secondSpec <- roleProcess check "keiro/shard-worker" 1 (object ["subscription" .= ("kenshouShardZombie" :: Text), "shardCount" .= bucketCount, "delivery" .= True])
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      threadDelay (2 * leaseMicros)
      lost <- waitUntil (transferred before <$> ownership) 120
      ownershipAfterLoss <- ownership
      c1 <- checkpoints
      signalChild supervisor first Cont
      continueAt <- getCurrentTime
      threadDelay (renewMicros + 3500000)
      resumedOwnership <- ownership
      c2 <- checkpoints
      appenderDone <- timeout 180000000 $ atomically do
        state <- progress appender
        case state.lastMessage of
          Just (WrkDone Nothing) -> pure True
          Just (WrkError _) -> pure False
          _ -> retry
      drained <- waitUntil ((== Right eventCount) <$> sinkCount) (max 160 (eventCount `div` 25))
      _ <- stopGracefully supervisor first 5000
      _ <- stopGracefully supervisor second 5000
      pure (initial, lost, ownershipAfterLoss, resumedOwnership, [c0, c1, c2], appenderDone == Just True, drained, continueAt)
    sealLedger check.ledger
    ledgers <- discoverLedgers check.ledgerDirectory
    facts <- foldFacts ledgers [] \seen fact -> pure (fact : seen)
    let checkpointRows = concat [[(Text.pack (show member), position) | (member, position) <- rows] | Right rows <- checkpointSamples]
        cutoff = round (utcTimeToPOSIXSeconds continueAt * 1000000) + fromIntegral renewMicros + 1000000
        zombieEffects = [fact | fact <- facts, fact.kind == Effect, fact.proc.index == 0]
        lateZombieEffects = [fact | fact <- facts, fact.kind == Effect, fact.proc.index == 0, fact.wall > cutoff]
    recordShardCells
      check
      [ ("initial-owner-covered", initial),
        ("survivor-claimed-expired-leases", lost),
        ("zombie-did-not-reclaim", covered resumedOwnership && owners resumedOwnership == owners ownershipAfterLoss && lost),
        ("checkpoints-never-regressed", length checkpointSamples == 3 && all (either (const False) (not . null)) checkpointSamples && checkpointsMonotonic checkpointRows),
        ("zombie-effects-ended-after-reconcile", not (null zombieEffects) && null lateZombieEffects),
        ("all-events-delivered", appenderDone && drained)
      ]

fairShareShedding :: Scenario
fairShareShedding =
  lateJoinerGetsNoBuckets
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/fair-share-shedding"),
      summary = "Starts a second worker while buckets remain unowned and checks balanced coverage and complete delivery.",
      knownDefect = Nothing,
      run = runFairShare
    }

runFairShare :: RunContext -> IO ScenarioReport
runFairShare context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    ensureDurableTables fixture
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardFairShare"
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        eventCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.events")) :: Int
        streamCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.streams")) :: Int
        ownership = runStoreIO store (ownershipSnapshotFor name)
        sinkCount = runDurable fixture (runTransaction (Tx.statement () sinkCountStatement))
        partlyOwned = \case
          Right rows -> length rows == bucketCount && let occupied = length [() | (_, Just _, _) <- rows] in occupied == (bucketCount + 1) `div` 2 + 1 && occupied < bucketCount
          Left _ -> False
        covered = \case
          Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner /= Nothing) rows
          Left _ -> False
    (joinedBeforeCoverage, shedBucketMoved, inFlightEvent, allCovered, fair, appenderDone, drained) <- withSupervisor check \supervisor -> do
      let start index = do
            spec <- roleProcess check "keiro/shard-worker" index (object ["subscription" .= ("kenshouShardFairShare" :: Text), "shardCount" .= bucketCount, "delivery" .= True, "handlerDelayMicros" .= if index == (0 :: Int) then Just (3000000 :: Int) else Nothing])
            worker <- spawn supervisor spec
            awaitReady worker 10000
            sendCommand worker CtlStart
            pure worker
      first <- start 0
      joinedBeforeCoverage <- waitUntil (partlyOwned <$> ownership) 40
      beforeJoin <- ownership
      let shedBucket = case beforeJoin of
            Right rows -> maximum (0 : [bucket | (bucket, Just _, _) <- rows])
            Left _ -> 0
      appenderSpec <- roleProcess check "keiro/shard-appender" 0 (object ["eventCount" .= eventCount, "streamCount" .= streamCount, "idPrefix" .= ("kenshou:shard:fair:" :: Text), "streamPrefix" .= ("account-fair-" :: Text), "pauseMicros" .= (1000 :: Int)])
      appender <- spawn supervisor appenderSpec
      awaitReady appender 10000
      sendCommand appender CtlStart
      let mark = "delivery-start-" <> Text.pack (show shedBucket)
      awaitMark first mark 20000
      firstState <- atomically (progress first)
      let inFlightEvent = case Map.lookup mark firstState.marks of
            Just (Object fields) -> case KeyMap.lookup "eventId" fields of Just (String value) -> Just value; _ -> Nothing
            _ -> Nothing
      second <- start 1
      allCovered <- waitUntil (covered <$> ownership) 120
      snapshot <- ownership
      let distribution = case snapshot of
            Right rows -> Map.fromListWith (+) [(owner, 1 :: Int) | (_, Just owner, _) <- rows]
            Left _ -> Map.empty
          fair = (bucketCount == 1 || Map.size distribution >= 2) && all (<= (bucketCount + 1) `div` 2) (Map.elems distribution)
          shedBucketMoved = case (beforeJoin, snapshot) of
            (Right beforeRows, Right afterRows) ->
              let beforeOwner = [owner | (bucket, Just owner, _) <- beforeRows, bucket == shedBucket]
                  afterOwner = [owner | (bucket, Just owner, _) <- afterRows, bucket == shedBucket]
               in length beforeOwner == 1 && length afterOwner == 1 && beforeOwner /= afterOwner
            _ -> False
      _ <- stopGracefully supervisor first 5000
      appenderDone <- timeout 180000000 $ atomically do
        state <- progress appender
        case state.lastMessage of
          Just (WrkDone Nothing) -> pure True
          Just (WrkError _) -> pure False
          _ -> retry
      drained <- waitUntil ((== Right eventCount) <$> sinkCount) (max 160 (eventCount `div` 25))
      _ <- stopGracefully supervisor second 5000
      pure (joinedBeforeCoverage, shedBucketMoved, inFlightEvent, allCovered, fair, appenderDone == Just True, drained)
    sealLedger check.ledger
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    recordShardCells
      check
      [ ("second-joined-before-complete-coverage", joinedBeforeCoverage),
        ("full-bucket-coverage", allCovered),
        ("fair-share-cap", fair),
        ("no-event-loss", appenderDone && drained),
        ("shed-in-flight-event-redelivered", shedBucketMoved && maybe False (\key -> Map.findWithDefault 0 key effects >= 2) inFlightEvent)
      ]

coverageAfterMembershipChange :: Scenario
coverageAfterMembershipChange =
  lateJoinerGetsNoBuckets
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/coverage-after-membership-change"),
      summary = "Measures bucket recovery after graceful and killed membership changes while an appender feeds the subscription.",
      knownDefect = Nothing,
      run = runMembershipChange
    }

runMembershipChange :: RunContext -> IO ScenarioReport
runMembershipChange context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    ensureDurableTables fixture
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardMembership"
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        eventCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.events")) :: Int
        streamCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.streams")) :: Int
        renewSeconds = realToFrac (knobDouble context.knobs (shardKnobName "shard.renew-interval-seconds"))
        leaseSeconds = realToFrac (knobDouble context.knobs (shardKnobName "shard.lease-ttl-seconds"))
        ownership = runStoreIO store (ownershipSnapshotFor name)
        owners result = case result of Right rows -> Set.fromList [owner | (_, Just owner, _) <- rows]; Left _ -> Set.empty
        valid result = case result of
          Right rows -> length rows == bucketCount && Set.size (Set.fromList [bucket | (bucket, _, _) <- rows]) == bucketCount && all (\(bucket, _, _) -> bucket >= 0 && bucket < bucketCount) rows
          Left _ -> False
        covered result = valid result && Set.size (owners result) >= 1 && case result of Right rows -> all (\(_, owner, _) -> owner /= Nothing) rows; Left _ -> False
        transferred prior current = covered current && Set.null (Set.intersection (owners prior) (owners current))
        workerSpec index = roleProcess check "keiro/shard-worker" index (object ["subscription" .= ("kenshouShardMembership" :: Text), "shardCount" .= bucketCount, "delivery" .= True])
        sinkCount = runDurable fixture (runTransaction (Tx.statement () sinkCountStatement))
        waitOwnership predicate = go (0 :: Int) True
          where
            go attempts allValid = do
              current <- ownership
              let validNow = valid current
              if predicate current
                then pure (True, allValid && validNow)
                else
                  if attempts >= 200
                    then pure (False, allValid && validNow)
                    else threadDelay 100000 >> go (attempts + 1) (allValid && validNow)
    (initial, gracefulGap, gracefulValid, killedGap, killedValid, appenderDone, drained) <- withSupervisor check \supervisor -> do
      let start index = do
            spec <- workerSpec index
            worker <- spawn supervisor spec
            awaitReady worker 10000
            sendCommand worker CtlStart
            pure worker
      first <- start 0
      initial <- fst <$> waitOwnership covered
      appenderSpec <- roleProcess check "keiro/shard-appender" 0 (object ["eventCount" .= eventCount, "streamCount" .= streamCount, "idPrefix" .= ("kenshou:shard:membership:" :: Text), "streamPrefix" .= ("account-membership-" :: Text), "pauseMicros" .= (1000 :: Int)])
      appender <- spawn supervisor appenderSpec
      awaitReady appender 10000
      sendCommand appender CtlStart
      gracefulSurvivor <- start 1
      beforeGrace <- ownership
      _ <- stopGracefully supervisor first 5000
      graceAt <- getCurrentTime
      (_, gracefulValid) <- waitOwnership (transferred beforeGrace)
      afterGrace <- ownership
      graceDone <- getCurrentTime
      killedSurvivor <- start 2
      beforeKill <- ownership
      killChild supervisor gracefulSurvivor
      killAt <- getCurrentTime
      (_, killedValid) <- waitOwnership (transferred beforeKill)
      afterKill <- ownership
      killDone <- getCurrentTime
      appenderDone <- timeout 180000000 $ atomically do
        state <- progress appender
        case state.lastMessage of
          Just (WrkDone Nothing) -> pure True
          Just (WrkError _) -> pure False
          _ -> retry
      drained <- waitUntil ((== Right eventCount) <$> sinkCount) (max 160 (eventCount `div` 25))
      _ <- stopGracefully supervisor killedSurvivor 5000
      pure (initial, if transferred beforeGrace afterGrace then Just (diffUTCTime graceDone graceAt) else Nothing, gracefulValid, if transferred beforeKill afterKill then Just (diffUTCTime killDone killAt) else Nothing, killedValid, appenderDone == Just True, drained)
    recordShardTimingCells
      check
      [ ("initial-coverage", initial, Nothing),
        ("graceful-coverage-by-deadline", maybe False (<= fromIntegral (bucketCount + 2) * renewSeconds) gracefulGap, gracefulGap),
        ("graceful-samples-disjoint", gracefulValid, Nothing),
        ("killed-coverage-by-deadline", maybe False (<= failoverDeadline (ShardTiming leaseSeconds renewSeconds) bucketCount 1) killedGap, killedGap),
        ("killed-samples-disjoint", killedValid, Nothing),
        ("all-appended-events-delivered", appenderDone && drained, Nothing)
      ]

sinkCountStatement :: Statement.Statement () Int
sinkCountStatement =
  Statement.preparable
    "SELECT count(*)::int FROM kenshou_durable.shard_sink"
    Encoders.noParams
    (fromIntegral <$> Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

checkpointStatement :: Statement.Statement Text [(Int, Int64)]
checkpointStatement =
  Statement.preparable
    "SELECT consumer_group_member, last_seen FROM kiroku.subscriptions WHERE subscription_name = $1 ORDER BY consumer_group_member"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList ((,) <$> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

sigkillFailoverVsGracefulRelinquish :: Scenario
sigkillFailoverVsGracefulRelinquish =
  lateJoinerGetsNoBuckets
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/sigkill-failover-vs-graceful-relinquish"),
      summary = "Compares lease-expiry failover after SIGKILL with immediate release after a graceful stop.",
      knownDefect = Nothing,
      run = runFailover
    }

runFailover :: RunContext -> IO ScenarioReport
runFailover context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        renewMicros = round (knobDouble context.knobs (shardKnobName "shard.renew-interval-seconds") * 1000000)
        leaseMicros = round (knobDouble context.knobs (shardKnobName "shard.lease-ttl-seconds") * 1000000)
        snapshot name = runStoreIO store (ownershipSnapshotFor (SubscriptionName name))
        spec name index = roleProcess check "keiro/shard-worker" index (object ["subscription" .= name, "shardCount" .= bucketCount, "delivery" .= True])
        covered result = case result of Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner /= Nothing) rows; Left _ -> False
        unowned result = case result of Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner == Nothing) rows; Left _ -> False
        owners result = case result of Right rows -> Set.fromList [owner | (_, Just owner, _) <- rows]; Left _ -> Set.empty
        transferred previous current = covered current && Set.null (Set.intersection (owners previous) (owners current))
    (killInitial, killImmediate, killBeforeExpiry, killRecovered, killElapsed, graceInitial, graceImmediate, graceRecovered, graceElapsed) <- withSupervisor check \supervisor -> do
      let killedName = "kenshouShardKilled" :: Text
          gracefulName = "kenshouShardGraceful" :: Text
          start name index = do
            processSpec <- spec name index
            worker <- spawn supervisor processSpec
            awaitReady worker 10000
            sendCommand worker CtlStart
            pure worker
      killed <- start killedName 0
      killInitial <- waitUntil (covered <$> snapshot killedName) 160
      survivor <- start killedName 1
      killChild supervisor killed
      killAt <- getCurrentTime
      killImmediate <- snapshot killedName
      now <- getCurrentTime
      let leaseStillHeld = case killImmediate of
            Right rows -> length rows == bucketCount && all (\(_, owner, expires) -> owner /= Nothing && maybe False (> now) expires) rows
            Left _ -> False
      threadDelay (max 100000 (leaseMicros `div` 2))
      midLease <- snapshot killedName
      let killBeforeExpiry = leaseStillHeld && owners midLease == owners killImmediate && covered midLease
      threadDelay (max 100000 (leaseMicros `div` 2))
      killRecovered <- waitUntil (transferred killImmediate <$> snapshot killedName) (max 40 (bucketCount * renewMicros `div` 250000 + 20))
      killDoneAt <- getCurrentTime
      _ <- stopGracefully supervisor survivor 5000
      graceful <- start gracefulName 2
      graceInitial <- waitUntil (covered <$> snapshot gracefulName) 160
      _ <- stopGracefully supervisor graceful 5000
      graceAt <- getCurrentTime
      graceImmediate <- snapshot gracefulName
      graceSurvivor <- start gracefulName 3
      graceRecovered <- waitUntil (transferred graceImmediate <$> snapshot gracefulName) (max 40 (bucketCount * renewMicros `div` 250000 + 20))
      graceDoneAt <- getCurrentTime
      _ <- stopGracefully supervisor graceSurvivor 5000
      pure (killInitial, killImmediate, killBeforeExpiry, killRecovered, diffUTCTime killDoneAt killAt, graceInitial, graceImmediate, graceRecovered, diffUTCTime graceDoneAt graceAt)
    let renewSeconds = realToFrac (knobDouble context.knobs (shardKnobName "shard.renew-interval-seconds"))
        leaseSeconds = realToFrac (knobDouble context.knobs (shardKnobName "shard.lease-ttl-seconds"))
    recordShardCells
      check
      [ ("killed-owner-covered-before-death", killInitial && covered killImmediate),
        ("killed-lease-held-until-expiry", killBeforeExpiry),
        ("killed-buckets-recovered", killRecovered && killElapsed <= failoverDeadline (ShardTiming leaseSeconds renewSeconds) bucketCount 1),
        ("graceful-owner-covered-before-stop", graceInitial),
        ("graceful-release-immediate", unowned graceImmediate),
        ("graceful-buckets-recovered", graceRecovered && graceElapsed <= fromIntegral (bucketCount + 2) * renewSeconds)
      ]

lateJoinerGetsNoBuckets :: Scenario
lateJoinerGetsNoBuckets =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/late-joiner-gets-no-buckets"),
      revision = 1,
      summary = "Checks whether new workers receive buckets from an already healthy owner without a membership loss.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = shardKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/plans/51-consumer-group-sharding-for-category-subscriptions" "Healthy shard leases are renewed in place without redistribution to late joiners" ["shard-late-workers-share"] AllCohorts),
      run = runLateJoiner
    }

runLateJoiner :: RunContext -> IO ScenarioReport
runLateJoiner context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardLateJoiner"
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        renewMicros = round (knobDouble context.knobs (shardKnobName "shard.renew-interval-seconds") * 1000000)
        ownership = runStoreIO store (ownershipSnapshotFor name)
        complete = do
          snapshot <- ownership
          pure (case snapshot of Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner /= Nothing) rows; Left _ -> False)
        spec index = roleProcess check "keiro/shard-worker" index (object ["subscription" .= ("kenshouShardLateJoiner" :: Text), "shardCount" .= bucketCount, "delivery" .= True])
    (initiallyCovered, first, afterJoin) <- withSupervisor check \supervisor -> do
      firstSpec <- spec 0
      firstWorker <- spawn supervisor firstSpec
      awaitReady firstWorker 10000
      sendCommand firstWorker CtlStart
      initiallyCovered <- waitUntil complete 160
      first <- ownership
      lateWorkers <- forM [1, 2] \index -> do
        workerSpec <- spec index
        worker <- spawn supervisor workerSpec
        awaitReady worker 10000
        sendCommand worker CtlStart
        pure worker
      threadDelay (max 1000000 (bucketCount * renewMicros + 2 * renewMicros))
      afterJoin <- ownership
      forM_ lateWorkers (\worker -> stopGracefully supervisor worker 5000)
      _ <- stopGracefully supervisor firstWorker 5000
      pure (initiallyCovered, first, afterJoin)
    let owners snapshot = case snapshot of
          Right rows -> [owner | (_, Just owner, _) <- rows]
          Left _ -> []
        distribution = Map.fromListWith (+) [(owner, 1 :: Int) | owner <- owners afterJoin]
        sharing = Map.size distribution >= 3 && all (<= (bucketCount + 2) `div` 3) (Map.elems distribution)
        cells =
          [ ("initial-owner-covers-all", initiallyCovered && case first of Right rows -> length rows == bucketCount && Set.size (Set.fromList (owners first)) == 1; Left _ -> False),
            ("late-workers-share", sharing),
            ("coverage-persists", case afterJoin of Right rows -> length rows == bucketCount && length (owners afterJoin) == bucketCount; Left _ -> False)
          ]
    recordShardCells check cells

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
