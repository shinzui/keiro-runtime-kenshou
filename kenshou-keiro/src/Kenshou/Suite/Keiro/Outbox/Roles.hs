module Kenshou.Suite.Keiro.Outbox.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, forever)
import Data.Aeson (object, withObject, (.!=), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Keiro.Outbox (BackoffSchedule (..), OutboxMaintenanceOptions (..), OutboxMaintenanceSummary (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), defaultPublishOptions, garbageCollectSent, outboxMaintenancePass, publishClaimedOutbox)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.ProducerReplay qualified as ProducerReplay
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline)
import Kiroku.Store (defaultConnectionSettings)

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/outbox-enqueuer") "Enqueues a serial, run-namespaced integration-event workload." enqueuer, WorkerRole (roleName "keiro/outbox-maintenance") "Reclaims stale publisher claims and optionally collects sent rows." maintenance, WorkerRole (roleName "keiro/outbox-publisher") "Publishes one claimed outbox batch, with a controllable acknowledgement window." publisher, ProducerReplay.role]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

enqueuer :: RoleContext -> IO ()
enqueuer context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox enqueuer requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "enqueuer args" (\value -> (,,) <$> value .:? "source" <*> value .:? "rows" <*> value .:? "keyCardinality")) context.init.args of
    Just (Just source, Just rowCount, Just keyCardinality)
      | rowCount > 0 && keyCardinality > 0 -> do
          context.send WrkReady
          context.receive >>= \case
            Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
              let entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
              enqueueInline fixture source entries
              context.send (WrkCustom "finished" (object ["rows" .= rowCount]))
            _ -> pure ()
    _ -> context.send (WrkError "invalid outbox enqueuer arguments")

maintenance :: RoleContext -> IO ()
maintenance context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox maintenance requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "maintenance args" (\value -> (,,,,,) <$> (value .:? "maxAttempts" .!= (10 :: Int)) <*> (value .:? "publishingTimeoutSeconds" .!= (300 :: Double)) <*> (value .:? "gc" .!= False) <*> (value .:? "retentionSeconds" .!= (3600 :: Double)) <*> (value .:? "passes" .!= (1 :: Int)) <*> (value .:? "intervalMillis" .!= (500 :: Int)))) context.init.args of
    Just (maxAttempts, timeoutSeconds, gc, retentionSeconds, passes, intervalMillis)
      | maxAttempts > 0 && timeoutSeconds > 0 && retentionSeconds >= 0 && passes > 0 && intervalMillis >= 0 -> do
          context.send WrkReady
          context.receive >>= \case
            Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
              let KeiroRunner runFixture = fixture.runner
                  options = OutboxMaintenanceOptions maxAttempts (realToFrac timeoutSeconds)
              forM_ [1 .. passes] \index -> do
                result <- runFixture (outboxMaintenancePass options Nothing) >>= either (fail . show) pure
                collected <-
                  if gc
                    then do
                      now <- getCurrentTime
                      runFixture (garbageCollectSent (realToFrac retentionSeconds) now) >>= either (fail . show) pure
                    else pure 0
                context.send (WrkCustom "maintenance-pass" (object ["pass" .= index, "requeued" .= result.requeued, "deadLettered" .= result.deadLettered, "backlog" .= result.backlog, "collected" .= collected]))
                if index < passes then threadDelay (intervalMillis * 1000) else pure ()
              context.send (WrkCustom "finished" (object ["passes" .= passes]))
            _ -> pure ()
    _ -> context.send (WrkError "invalid outbox maintenance arguments")

publisher :: RoleContext -> IO ()
publisher context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox publisher requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "publisher args" (\value -> (,,,,,) <$> (value .:? "parkBeforeAppend" .!= False) <*> (value .:? "parkAfterAppend" .!= False) <*> (value .:? "loop" .!= False) <*> (value .:? "pauseMicros" .!= (0 :: Int)) <*> (value .:? "outcome" .!= ("succeeded" :: Text)) <*> (value .:? "maxAttempts" .!= (10 :: Int)))) context.init.args of
    Nothing -> context.send (WrkError "invalid outbox publisher arguments")
    Just (parkBeforeAppend, parkAfterAppend, loop, pauseMicros, outcome, maxAttempts) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> Broker.withTableBroker postgres.connectionString \broker -> do
          batchNumber <- newIORef (0 :: Int)
          let KeiroRunner runFixture = fixture.runner
              model = Broker.BrokerModel 0 0 4
              hooks =
                Broker.PublishHook
                  ( \rows -> do
                      number <- atomicModifyIORef' batchNumber (\n -> (n + 1, n + 1))
                      at <- getCurrentTime
                      context.send (WrkCustom "callback-start" (object ["batch" .= number, "at" .= at, "rowIds" .= map (show . (.outboxId)) rows]))
                      context.send (WrkCustom "batch-claimed" (object ["rows" .= length rows]))
                      if parkBeforeAppend then forever (threadDelay 1000000) else pure ()
                  )
                  ( \rows -> do
                      number <- readIORef batchNumber
                      at <- getCurrentTime
                      context.send (WrkCustom "callback-end" (object ["batch" .= number, "at" .= at, "rowIds" .= map (show . (.outboxId)) rows]))
                      context.send (WrkCustom "broker-appended" (object ["rows" .= length rows]))
                      if parkAfterAppend then awaitContinue else pure ()
                  )
              callback = Broker.publishScripted broker model (const (if outcome == "failed" then Broker.AlwaysFail else Broker.Succeed)) hooks context.init.instanceName
              options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0, maxAttempts = maxAttempts}
              awaitContinue =
                context.receive >>= \case
                  Just (CtlCustom "continue" _) -> pure ()
                  _ -> awaitContinue
              drive published idleMicros = do
                result <- runFixture (publishClaimedOutbox callback options Nothing)
                case result of
                  Left err -> context.send (WrkError (Text.pack (show err)))
                  Right summary
                    | loop && summary.claimed > 0 -> threadDelay (max 0 pauseMicros) >> drive (published + summary.published) 0
                    | loop && idleMicros < 1000000 -> threadDelay 10000 >> drive published (idleMicros + 10000)
                    | otherwise -> context.send (WrkCustom "finished" (object ["published" .= (published + summary.published)]))
          if loop then threadDelay 100000 else pure ()
          drive 0 (0 :: Int)
        _ -> pure ()
