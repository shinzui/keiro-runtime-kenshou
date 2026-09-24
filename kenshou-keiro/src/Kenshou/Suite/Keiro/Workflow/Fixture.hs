module Kenshou.Suite.Keiro.Workflow.Fixture
  ( DurableStore,
    withDurableStore,
    ensureDurableTables,
    runDurable,
    durableKirokuStore,
    durableTelemetry,
    fixtureCategory,
  )
where

import Data.Text (Text)
import Hasql.Transaction qualified as Tx
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroEff, KeiroRunner (..), KeiroTelemetry, withFixtureEnv)
import Kiroku.Store (ConnectionSettings, KirokuStore, runTransaction)
import Kiroku.Store.Error (StoreError)

-- | The only EP-14 module that knows the EP-12 fixture's concrete names.
type DurableStore = FixtureEnv

withDurableStore :: ConnectionSettings -> (DurableStore -> IO a) -> IO a
withDurableStore = withFixtureEnv

runDurable :: DurableStore -> KeiroEff a -> IO (Either StoreError a)
runDurable fixture = let KeiroRunner run = fixture.runner in run

durableKirokuStore :: DurableStore -> KirokuStore
durableKirokuStore = (.store)

durableTelemetry :: DurableStore -> KeiroTelemetry
durableTelemetry = (.telemetry)

fixtureCategory :: Text
fixtureCategory = "account"

-- | Additive tables shared by workflow publication and shard delivery probes.
ensureDurableTables :: DurableStore -> IO ()
ensureDurableTables fixture = do
  outcome <- runDurable fixture $ runTransaction do
    Tx.sql "CREATE SCHEMA IF NOT EXISTS kenshou_durable"
    Tx.sql "CREATE TABLE IF NOT EXISTS kenshou_durable.awakeable_publications (workflow_name text NOT NULL, workflow_id text NOT NULL, generation integer NOT NULL, label text NOT NULL, awakeable_id uuid NOT NULL, PRIMARY KEY (workflow_name, workflow_id, generation, label))"
    Tx.sql "CREATE TABLE IF NOT EXISTS kenshou_durable.shard_sink (event_id uuid PRIMARY KEY, stream_id bigint NOT NULL, global_position bigint NOT NULL, bucket integer NOT NULL, first_worker text NOT NULL, deliveries integer NOT NULL DEFAULT 1)"
  either (fail . show) pure outcome
