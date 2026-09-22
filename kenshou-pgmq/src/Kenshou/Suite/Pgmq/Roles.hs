module Kenshou.Suite.Pgmq.Roles (CrashPoint (..), roles) where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.Aeson (Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Hasql.Connection.Settings qualified as Connection
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Kenshou.Core.Role
import Pgmq.Config qualified as Config
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Types
import Pgmq.Types (Message (..), MessageBody (..), QueueName, parseQueueName)

data CrashPoint = AfterRead | AfterHandled | MidBatchAck deriving stock (Eq, Ord, Show)

data RoleArgs = RoleArgs
  { queue :: QueueName,
    count :: Int,
    batchSize :: Int,
    visibilityTimeout :: Int,
    acknowledge :: Bool,
    holdAfterRead :: Bool
  }

roles :: [WorkerRole]
roles =
  [ WorkerRole (roleName "pgmq/pgmq-producer") "Produces a finite, atomically batched PGMQ workload." producer,
    WorkerRole (roleName "pgmq/pgmq-consumer") "Drains PGMQ messages or pauses at the after-read crash point." consumer,
    WorkerRole (roleName "pgmq/pgmq-reconciler") "Reconciles a declared PGMQ queue." reconciler
  ]

producer :: RoleContext -> IO ()
producer context = do
  arguments <- parseArgs context.init.args
  context.send WrkReady
  awaitStart context do
    withRolePool context \pool -> do
      let bodies = [MessageBody (object ["k" .= (context.init.instanceName <> "-" <> Text.pack (show index))]) | index <- [1 .. arguments.count]]
      identifiers <- use pool (Sessions.batchSendMessage (Types.BatchSendMessage arguments.queue bodies Nothing))
      now <- getCurrentTime
      context.send (WrkFacts [object ["kind" .= ("sent" :: Text), "ids" .= identifiers]])
      context.send (WrkProgress (fromIntegral (length identifiers)) now)

consumer :: RoleContext -> IO ()
consumer context = do
  arguments <- parseArgs context.init.args
  context.send WrkReady
  awaitStart context (withRolePool context (drain arguments 0))
  where
    drain arguments handled pool = do
      messages <-
        use
          pool
          ( Sessions.readMessage
              (Types.ReadMessage arguments.queue (fromIntegral arguments.visibilityTimeout) (Just (fromIntegral arguments.batchSize)) Nothing)
          )
      if Vector.null messages
        then getCurrentTime >>= context.send . WrkProgress (fromIntegral handled)
        else do
          let values = Vector.toList messages
              identifiers = fmap (.messageId) values
          context.send (WrkCustom "after-read" (object ["ids" .= identifiers, "readCounts" .= fmap (.readCount) values, "visibleAt" .= fmap (.visibilityTime) values, "readAt" .= fmap (.lastReadAt) values]))
          if arguments.holdAfterRead
            then hold context
            else do
              if arguments.acknowledge
                then void (use pool (Sessions.batchDeleteMessages (Types.BatchMessageQuery arguments.queue identifiers)))
                else pure ()
              now <- getCurrentTime
              context.send (WrkProgress (fromIntegral (handled + length values)) now)
              drain arguments (handled + length values) pool

reconciler :: RoleContext -> IO ()
reconciler context = do
  arguments <- parseArgs context.init.args
  context.send WrkReady
  awaitStart context do
    withRolePool context \pool -> do
      report <- use pool (Config.ensureQueuesReport [Config.standardQueue arguments.queue])
      context.send (WrkCustom "reconciled" (object ["actions" .= fmap show report]))

awaitStart :: RoleContext -> IO () -> IO ()
awaitStart context action =
  context.receive >>= \case
    Just CtlStart -> action
    Just (CtlStop _) -> pure ()
    Just _ -> awaitStart context action
    Nothing -> pure ()

hold :: RoleContext -> IO ()
hold context =
  context.receive >>= \case
    Just (CtlStop _) -> pure ()
    Nothing -> pure ()
    _ -> hold context

parseArgs :: Value -> IO RoleArgs
parseArgs value = either (ioError . userError) pure (parseEither parser value)
  where
    parser :: Value -> Parser RoleArgs
    parser = withObject "pgmq role arguments" \objectValue -> do
      queueText <- objectValue .: "queue"
      queue <- either (fail . show) pure (parseQueueName queueText)
      RoleArgs queue
        <$> objectValue .:? "count" .!= 100
        <*> objectValue .:? "batchSize" .!= 10
        <*> objectValue .:? "visibilityTimeout" .!= 3
        <*> objectValue .:? "acknowledge" .!= True
        <*> objectValue .:? "holdAfterRead" .!= False

withRolePool :: RoleContext -> (Pool.Pool -> IO value) -> IO value
withRolePool context action = case context.init.postgres of
  Nothing -> ioError (userError "pgmq worker requires PostgreSQL")
  Just postgres ->
    bracket
      (Pool.acquire (PoolConfig.settings [PoolConfig.size 2, PoolConfig.acquisitionTimeout 10, PoolConfig.staticConnectionSettings (Connection.connectionString postgres.connectionString <> Connection.applicationName ("kenshou-" <> context.init.instanceName))]))
      Pool.release
      action

use :: Pool.Pool -> Session.Session value -> IO value
use pool action = either (ioError . userError . show) pure =<< Pool.use pool action

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName
