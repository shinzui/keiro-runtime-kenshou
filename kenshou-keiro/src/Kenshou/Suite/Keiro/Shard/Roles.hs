module Kenshou.Suite.Keiro.Shard.Roles (roles) where

import Control.Exception (try)
import Control.Monad (void)
import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Keiro.Subscription.Shard (ShardCountMismatch, ShardLease (..), WorkerId (..), ensureShards)
import Keiro.Subscription.Shard.Worker (ShardedWorkerOptions (..), defaultShardedWorkerOptions, mkShardedWorkerOptions)
import Kenshou.Core.Knob (resolvedKnobsMap)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardOptionsFrom)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Subscription.Types (SubscriptionName (..), SubscriptionTarget (..))

roles :: [WorkerRole]
roles = [WorkerRole roleName "Starts a sharded subscription and reports its count validation result." ensureWorker]
  where
    roleName = either (error . Text.unpack) id (mkRoleName "keiro/shard-worker")

ensureWorker :: RoleContext -> IO ()
ensureWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "shard worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "shard worker args" (\value -> (,) <$> value .: "subscription" <*> value .: "shardCount")) context.init.args of
    Nothing -> context.send (WrkError "invalid shard worker arguments")
    Just (subscription, count) -> case optionsResult count of
      Left err -> context.send (WrkError (Text.pack (show err)))
      Right options -> do
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture -> do
            let lease = ShardLease (SubscriptionName subscription) (WorkerId UUID.nil) options.shardCount options.leaseTtl
            outcome <- try @ShardCountMismatch (runStoreIO (durableKirokuStore fixture) (ensureShards lease))
            case outcome of
              Left err -> fail (show err)
              Right (Left err) -> fail (show err)
              Right (Right ()) -> context.send (WrkDone Nothing)
          _ -> void (context.send (WrkDone (Just "not started")))
  where
    optionsResult count =
      if Map.member (shardKnobName "shard.shard-count") (resolvedKnobsMap context.init.knobs)
        then shardOptionsFrom AllStreams context.init.knobs
        else mkShardedWorkerOptions (defaultShardedWorkerOptions AllStreams count) {leaseTtl = 10, renewInterval = 2}
