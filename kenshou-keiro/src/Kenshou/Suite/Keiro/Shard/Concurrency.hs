module Kenshou.Suite.Keiro.Shard.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (diffUTCTime, getCurrentTime)
import Keiro.Subscription.Shard (ownershipSnapshotFor)
import Kenshou.Check.Process (awaitReady, killChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobDouble, knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardKnobs)
import Kenshou.Suite.Keiro.Shard.Oracle (ShardTiming (..), failoverDeadline, recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))

scenarios :: [Scenario]
scenarios = [lateJoinerGetsNoBuckets, sigkillFailoverVsGracefulRelinquish]

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
