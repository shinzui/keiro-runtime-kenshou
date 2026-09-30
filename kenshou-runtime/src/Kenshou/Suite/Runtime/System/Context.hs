module Kenshou.Suite.Runtime.System.Context
  ( RuntimeContext (..),
    RuntimeResources (..),
    runtimeRequirements,
    withRuntimeResources,
  )
where

import Data.Map.Strict qualified as Map
import Kenshou.Core.Context (Environment (..), RunContext (..), requirePostgres)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker, withRuntimeBroker)
import Kiroku.Store (KirokuStore, defaultConnectionSettings, withStore)

data RuntimeContext = RuntimeContext
  { postgres :: !PostgresEnv,
    store :: !KirokuStore
  }

data RuntimeResources = RuntimeResources
  { shop :: !RuntimeContext,
    warehouse :: !RuntimeContext,
    broker :: !RuntimeBroker
  }

-- | The two contexts get separate stores. The kernel provisions separate
-- PostgreSQL environments locally; a cell may place their databases on its
-- shared server and records that placement in the environment fingerprint.
runtimeRequirements :: EnvRequirements
runtimeRequirements =
  noEnvironment
    { postgres = Just databaseRequirement,
      extraPostgres = [("warehouse", databaseRequirement)],
      kafka = True
    }
  where
    databaseRequirement = PostgresRequirement [SchemaKiroku, SchemaKeiro, SchemaPgmq] [] False

withRuntimeResources :: RunContext -> Int -> (RuntimeResources -> IO value) -> IO value
withRuntimeResources context partitions action = do
  let shopPostgres = requirePostgres context
  warehousePostgres <-
    maybe (ioError (userError "runtime scenario did not declare warehouse PostgreSQL")) pure $
      Map.lookup "warehouse" context.env.extraPostgres
  withStore (defaultConnectionSettings shopPostgres.connectionString) \shopStore ->
    withStore (defaultConnectionSettings warehousePostgres.connectionString) \warehouseStore ->
      withRuntimeBroker context partitions \broker ->
        action
          RuntimeResources
            { shop = RuntimeContext shopPostgres shopStore,
              warehouse = RuntimeContext warehousePostgres warehouseStore,
              broker
            }
