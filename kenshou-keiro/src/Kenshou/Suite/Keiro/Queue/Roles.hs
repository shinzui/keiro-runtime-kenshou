module Kenshou.Suite.Keiro.Queue.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Aeson (object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Int (Int64)
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
import Keiro.PGMQ.Job (Job (..), JobContext (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), RetryDelay (..), RetryPolicy (..), defaultJobTuning, defaultRetryPolicy, jobProcessorWithContext, runJobOnceWithContext, runJobWorkers)
import Keiro.PGMQ.Runtime (JobRuntime (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Shibuya.App (SupervisionStrategy (..), waitApp)

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/queue-worker") "Runs a continuous typed-job processor under Shibuya supervision." worker]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

effectInsertStatement :: Statement.Statement Text ()
effectInsertStatement = Statement.preparable "INSERT INTO kenshou_fx.queue_effects (payload) VALUES ($1)" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult

fifoStartStatement :: Statement.Statement Text Int64
fifoStartStatement = Statement.preparable "INSERT INTO kenshou_fx.queue_fifo_spans (payload, started_at) VALUES ($1, clock_timestamp()) RETURNING id" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

fifoFinishStatement :: Statement.Statement Int64 ()
fifoFinishStatement = Statement.preparable "UPDATE kenshou_fx.queue_fifo_spans SET finished_at = clock_timestamp() WHERE id = $1" (Encoders.param (Encoders.nonNullable Encoders.int8)) Decoders.noResult

worker :: RoleContext -> IO ()
worker context = case context.init.postgres of
  Nothing -> context.send (WrkError "queue worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "queue worker args" (\o -> (,,,) <$> o .: "queue" <*> o .:? "mode" <*> o .:? "polling" <*> o .:? "extend")) context.init.args of
    Nothing -> context.send (WrkError "invalid queue worker arguments")
    Just (queue, mode, pollingMode, extend) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withJobRuntime postgres.connectionString Nothing \runtime -> do
          counter <- newIORef (0 :: Int)
          let holding = mode == Just ("hold" :: Text)
              draining = mode == Just ("lease-drain" :: Text)
              leasing = mode == Just ("lease" :: Text) || draining
              fifo = mode == Just ("fifo" :: Text)
              policy = if holding then RetryPolicy 3 (RetryDelay 60) True else defaultRetryPolicy
              tuning
                | holding = defaultJobTuning {visibilityTimeout = 3, polling = if pollingMode == Just ("long-poll" :: Text) then LongPoll 5 100 else PollEvery 1}
                | leasing = defaultJobTuning {visibilityTimeout = 2, polling = PollEvery 0.2}
                | mode == Just "throw-once" = defaultJobTuning {visibilityTimeout = 1, polling = PollEvery 0.2}
                | fifo = defaultJobTuning {visibilityTimeout = 10, batchSize = 8, polling = PollEvery 0.1, ordering = FifoHeads}
                | otherwise = defaultJobTuning
              job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) (if fifo then FifoHeads else Unordered) policy
              handler jobContext payload = do
                when (leasing && extend == Just True) (jobContext.extendLease 10)
                liftIO do
                  if holding
                    then do
                      now <- getCurrentTime
                      context.send (WrkCustom "delivery" (object ["attempt" .= jobContext.attempt, "payload" .= payload, "at" .= show now]))
                      _ <- context.receive
                      pure ()
                    else
                      if fifo
                        then do
                          started <- Pool.use runtime.runtimePool (Session.statement payload fifoStartStatement)
                          spanId <- either (fail . show) pure started
                          when (payload == "0:0") (threadDelay 5000000)
                          threadDelay 10000
                          finished <- Pool.use runtime.runtimePool (Session.statement spanId fifoFinishStatement)
                          either (fail . show) pure finished
                          count <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
                          now <- getCurrentTime
                          context.send (WrkProgress (fromIntegral count) now)
                        else do
                          when (not leasing) do
                            now <- getCurrentTime
                            context.send (WrkCustom "delivery" (object ["attempt" .= jobContext.attempt, "headers" .= jobContext.headers, "payload" .= payload, "at" .= show now]))
                          when leasing do
                            now <- getCurrentTime
                            context.send (WrkCustom "delivery" (object ["attempt" .= jobContext.attempt, "payload" .= payload, "at" .= show now]))
                            threadDelay 6000000
                          result <- Pool.use runtime.runtimePool (Session.statement payload effectInsertStatement)
                          either (fail . show) pure result
                          count <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
                          now <- getCurrentTime
                          context.send (WrkProgress (fromIntegral count) now)
                when (mode == Just "throw-once" && jobContext.attempt == Just 0) (liftIO (fail "fixture worker handler failure"))
                pure $ case mode of
                  Just "retry-once" | jobContext.attempt == Just 0 -> Retry (RetryDelay 1)
                  Just "dead" -> Dead "worker-poison"
                  _ -> Done
          result <-
            if draining
              then do
                context.send (WrkCustom "running" (object []))
                runJobEff runtime (runJobOnceWithContext tuning 1 job handler >> pure ())
              else runJobEff runtime do
                started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext tuning job handler]
                case started of
                  Left err -> liftIO (context.send (WrkError (Text.pack (show err))))
                  Right app -> do
                    liftIO (context.send (WrkCustom "running" (object [])))
                    waitApp app
          case result of
            Left err -> context.send (WrkError (Text.pack (show err)))
            Right _ -> context.send (WrkCustom "stopped" (object []))
        _ -> pure ()
