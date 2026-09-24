module Kenshou.Suite.Keiro.Shard.Roles (roles) where

import Control.Exception (try)
import Control.Monad (void)
import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Keiro.Subscription.Shard (ShardCountMismatch, ShardLease (..), WorkerId (..), ensureShards)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))

roles :: [WorkerRole]
roles = [WorkerRole roleName "Starts a sharded subscription and reports its count validation result." ensureWorker]
  where
    roleName = either (error . Text.unpack) id (mkRoleName "keiro/shard-worker")

ensureWorker :: RoleContext -> IO ()
ensureWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "shard worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "shard worker args" (\value -> (,) <$> value .: "subscription" <*> value .: "shardCount")) context.init.args of
    Nothing -> context.send (WrkError "invalid shard worker arguments")
    Just (subscription, count) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture -> do
          let lease = ShardLease (SubscriptionName subscription) (WorkerId UUID.nil) count 10
          outcome <- try @ShardCountMismatch (runStoreIO (durableKirokuStore fixture) (ensureShards lease))
          case outcome of
            Left err -> context.send (WrkError (Text.pack (show err)))
            Right (Left err) -> context.send (WrkError (Text.pack (show err)))
            Right (Right ()) -> context.send (WrkDone Nothing)
        _ -> void (context.send (WrkDone (Just "not started")))
