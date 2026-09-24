module Kenshou.Suite.Keiro.Shard.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Subscription.Shard (ownershipSnapshotFor)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
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
import Kenshou.Suite.Keiro.Shard.Oracle (recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))

scenarios :: [Scenario]
scenarios = [lateJoinerGetsNoBuckets]

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
