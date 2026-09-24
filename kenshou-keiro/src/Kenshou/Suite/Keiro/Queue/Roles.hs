module Kenshou.Suite.Keiro.Queue.Roles (roles) where

import Data.Aeson (object, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), defaultJobTuning, defaultRetryPolicy, jobProcessorWithContext, runJobWorkers)
import Keiro.PGMQ.Runtime (JobRuntime (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Shibuya.App (SupervisionStrategy (..), waitApp)

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/queue-worker") "Runs a continuous typed-job processor under Shibuya supervision." worker]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

effectInsertStatement :: Statement.Statement Text ()
effectInsertStatement = Statement.preparable "INSERT INTO kenshou_fx.queue_effects (payload) VALUES ($1)" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult

worker :: RoleContext -> IO ()
worker context = case context.init.postgres of
  Nothing -> context.send (WrkError "queue worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "queue worker args" (.: "queue")) context.init.args of
    Nothing -> context.send (WrkError "invalid queue worker arguments")
    Just queue -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withJobRuntime postgres.connectionString Nothing \runtime -> do
          counter <- newIORef (0 :: Int)
          let job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
              handler _ payload = do
                liftIO do
                  result <- Pool.use runtime.runtimePool (Session.statement payload effectInsertStatement)
                  either (fail . show) pure result
                  count <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
                  now <- getCurrentTime
                  context.send (WrkProgress (fromIntegral count) now)
                pure Done
          result <- runJobEff runtime do
            started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext defaultJobTuning job handler]
            case started of
              Left err -> liftIO (context.send (WrkError (Text.pack (show err))))
              Right app -> do
                liftIO (context.send (WrkCustom "running" (object [])))
                waitApp app
          case result of
            Left err -> context.send (WrkError (Text.pack (show err)))
            Right () -> context.send (WrkCustom "stopped" (object []))
        _ -> pure ()
