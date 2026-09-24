module Kenshou.Suite.Keiro.Shard.LeaseSmoke (scenarios) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Subscription.Shard (ShardLease (..), WorkerId (..), acquireOwnedBuckets, ensureShards, ownershipSnapshotFor, relinquish)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Oracle (coverageAndDisjointness, recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (Store, defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))

scenarios :: [Scenario]
scenarios = [leaseCoverageSmoke]

leaseCoverageSmoke :: Scenario
leaseCoverageSmoke =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/correctness/lease-coverage-smoke"),
      revision = 1,
      summary = "Claims all shard buckets one per pass, releases them, and checks immediate ownership transfer without overlap.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runLeaseCoverageSmoke
    }

runLeaseCoverageSmoke :: RunContext -> IO ScenarioReport
runLeaseCoverageSmoke context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardLeaseSmoke"
        worker :: Int -> WorkerId
        worker number = WorkerId $ maybe (error "invalid fixed worker UUID") id $ UUID.fromString ("00000000-0000-0000-0000-00000000000" <> show number)
        first = ShardLease name (worker 1) 4 10
        second = ShardLease name (worker 2) 4 10
        run :: Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
        run = runStoreIO store
    ensured <- run (ensureShards first)
    firstPasses <- traverse (\_ -> run (acquireOwnedBuckets first 1)) [1 :: Int .. 4]
    firstSnapshot <- run (ownershipSnapshotFor name)
    released <- run (relinquish first (Set.fromList [0 .. 3]))
    secondPasses <- traverse (\_ -> run (acquireOwnedBuckets second 1)) [1 :: Int .. 4]
    secondSnapshot <- run (ownershipSnapshotFor name)
    now <- getCurrentTime
    let healthy snapshot owner = case snapshot of
          Right rows ->
            coverageAndDisjointness 4 [(bucket, maybe [] (const ["owner"]) currentOwner) | (bucket, currentOwner, _) <- rows]
              && all (\(_, currentOwner, expires) -> currentOwner == Just owner && maybe False (> now) expires) rows
          _ -> False
        sizes passes = map (fmap Set.size) passes == map Right [1 .. 4]
        cells =
          [ ("ensure-shards", ensured == Right ()),
            ("one-bucket-per-pass", sizes firstPasses),
            ("first-owner-coverage", healthy firstSnapshot (worker 1)),
            ("relinquish", released == Right ()),
            ("second-owner-convergence", sizes secondPasses && healthy secondSnapshot (worker 2))
          ]
    recordShardCells check cells
