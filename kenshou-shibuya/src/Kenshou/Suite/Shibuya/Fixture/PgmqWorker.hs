module Kenshou.Suite.Shibuya.Fixture.PgmqWorker (role) where

import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)
import Data.Aeson (Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (liftIO)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (insertEffect, runPgmqStack, withPgmqConnectionPool)
import Shibuya.Adapter.Pgmq (FifoConfig (..), FifoReadStrategy (..), PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, mkPgmqAdapterEnv, parseQueueName, pgmqAdapter)
import Shibuya.App (AppConfig (..), QueueProcessor (..), ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))

role :: WorkerRole
role = WorkerRole roleName "Consumes PGMQ deliveries in a separate Shibuya process with an optional lease heartbeat." worker

roleName :: RoleName
roleName = either (error . Text.unpack) id (mkRoleName "shibuya/pgmq-consumer")

data Args = Args
  { queue :: !Text,
    arm :: !Text,
    visibilitySeconds :: !Int,
    extendLease :: !Bool,
    handlerMicros :: !Int,
    slowEvery :: !Int,
    slowHandlerMicros :: !Int,
    readBatchSize :: !Int,
    concurrentHandlers :: !Int,
    fifoStrategy :: !(Maybe Text),
    retryGroup :: !(Maybe Text),
    retrySequence :: !(Maybe Int)
  }

parseArgs :: Value -> Parser Args
parseArgs = withObject "PGMQ consumer arguments" $ \value -> do
  queue <- value .: "queue"
  arm <- value .: "arm"
  visibilitySeconds <- value .: "visibilitySeconds"
  extendLease <- value .: "extendLease"
  handlerMicros <- value .:? "handlerMicros" .!= 5000000
  slowEvery <- value .:? "slowEvery" .!= 0
  slowHandlerMicros <- value .:? "slowHandlerMicros" .!= handlerMicros
  readBatchSize <- value .:? "readBatchSize" .!= 1
  concurrentHandlers <- value .:? "concurrentHandlers" .!= 1
  fifoStrategy <- value .:? "fifoStrategy"
  retryGroup <- value .:? "retryGroup"
  retrySequence <- value .:? "retrySequence"
  pure Args {queue, arm, visibilitySeconds, extendLease, handlerMicros, slowEvery, slowHandlerMicros, readBatchSize, concurrentHandlers, fifoStrategy, retryGroup, retrySequence}

worker :: RoleContext -> IO ()
worker context = do
  postgres <- maybe (fail "PGMQ consumer requires PostgreSQL") pure context.init.postgres
  args <- either fail pure (parseEither parseArgs context.init.args)
  queue <- either (fail . show) pure (parseQueueName args.queue)
  strategy <- case args.fifoStrategy of
    Nothing -> pure Nothing
    Just "head-per-group" -> pure (Just (FifoConfig HeadPerGroup))
    Just "throughput-optimized" -> pure (Just (FifoConfig ThroughputOptimized))
    Just "round-robin" -> pure (Just (FifoConfig RoundRobin))
    Just other -> fail ("unknown PGMQ FIFO strategy: " <> Text.unpack other)
  context.send WrkReady
  awaitStart
  withPgmqConnectionPool postgres.connectionString 10 $ \consumerPool ->
    withPgmqConnectionPool postgres.connectionString 2 $ \observerPool -> do
      let config =
            (defaultConfig queue)
              { batchSize = fromIntegral args.readBatchSize,
                visibilityTimeout = fromIntegral args.visibilitySeconds,
                polling = StandardPolling 0.05,
                maxRetries = 10,
                fifoConfig = strategy
              }
          handler message = do
            let MessageId identifier = message.envelope.messageId
                attempt = maybe (-1) (\(Attempt index) -> fromIntegral index) message.envelope.attempt
            startedAt <- liftIO getCurrentTime
            liftIO $ context.send (WrkCustom "delivery-start" (object ["messageId" .= identifier, "attempt" .= attempt, "at" .= startedAt]))
            if args.extendLease
              then case message.lease of
                Nothing -> liftIO (fail "PGMQ delivery had no lease to extend")
                Just lease -> do
                  replicateM_ 7 $ do
                    liftIO (threadDelay 600000)
                    lease.leaseExtend 2
                  liftIO (threadDelay 800000)
              else do
                let sequenceNumber = parseMaybe (withObject "PGMQ workload message" (.: "sequence")) message.envelope.payload
                    delay =
                      if args.slowEvery > 0 && maybe False (\number -> number `mod` args.slowEvery == 0) (sequenceNumber :: Maybe Int)
                        then args.slowHandlerMicros
                        else args.handlerMicros
                liftIO (threadDelay delay)
            let retryThis =
                  case (args.retryGroup, args.retrySequence, message.envelope.attempt) of
                    (Just group, Just sequenceNumber, Just (Attempt 0)) ->
                      parseMaybe (withObject "PGMQ workload message" $ \value -> (,) <$> value .: "group" <*> value .: "sequence") message.envelope.payload == Just (group, sequenceNumber)
                    _ -> False
            if retryThis
              then do
                liftIO $ context.send (WrkCustom "retried" (object ["messageId" .= identifier]))
                pure (AckRetry (RetryDelay 0))
              else do
                completedAt <- liftIO getCurrentTime
                liftIO $ do
                  insertEffect observerPool args.arm identifier attempt startedAt completedAt Nothing
                  context.send (WrkCustom "effect-done" (object ["messageId" .= identifier, "attempt" .= attempt, "at" .= completedAt]))
                pure AckOk
      outcome <- runPgmqStack consumerPool $ do
        adapterResult <- pgmqAdapter (mkPgmqAdapterEnv consumerPool) config
        case adapterResult of
          Left err -> error (show err)
          Right adapter -> do
            let processor = (mkProcessor adapter handler) {concurrency = if args.concurrentHandlers == 1 then Serial else Async args.concurrentHandlers}
            started <- runApp defaultAppConfig {inboxSize = 2} [(ProcessorId ("pgmq-" <> args.arm), processor)]
            case started of
              Left err -> error (show err)
              Right handle -> do
                liftIO $ context.send (WrkCustom "running" (object []))
                quiesce <- liftIO awaitAction
                stopped <- stopAppGracefully defaultShutdownConfig {drainTimeout = 6} handle
                waitApp handle
                if quiesce
                  then do
                    liftIO $ context.send (WrkCustom "quiesced" (object ["drained" .= stopped]))
                    liftIO awaitStop
                  else pure ()
                liftIO $ context.send (WrkCustom "stopped" (object ["drained" .= stopped]))
      either (fail . show) pure outcome
  where
    awaitStart =
      context.receive >>= \case
        Just CtlStart -> pure ()
        Just (CtlStop _) -> fail "PGMQ consumer stopped before start"
        Nothing -> fail "PGMQ consumer parent disconnected before start"
        _ -> awaitStart
    awaitAction =
      context.receive >>= \case
        Just (CtlCustom "quiesce" _) -> pure True
        Just (CtlStop _) -> pure False
        Nothing -> pure False
        _ -> awaitAction
    awaitStop =
      context.receive >>= \case
        Just (CtlStop _) -> pure ()
        Nothing -> pure ()
        _ -> awaitStop
