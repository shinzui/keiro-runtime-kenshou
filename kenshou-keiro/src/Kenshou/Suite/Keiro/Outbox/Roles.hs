module Kenshou.Suite.Keiro.Outbox.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson (object, withObject, (.!=), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Outbox (BackoffSchedule (..), OutboxPublishOptions (..), OutboxPublishSummary (..), defaultPublishOptions, publishClaimedOutbox)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kiroku.Store (defaultConnectionSettings)

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/outbox-publisher") "Publishes one claimed outbox batch, with a controllable acknowledgement window." publisher]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

publisher :: RoleContext -> IO ()
publisher context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox publisher requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "publisher args" (\value -> (,,,) <$> (value .:? "parkBeforeAppend" .!= False) <*> (value .:? "parkAfterAppend" .!= False) <*> (value .:? "loop" .!= False) <*> (value .:? "pauseMicros" .!= (0 :: Int)))) context.init.args of
    Nothing -> context.send (WrkError "invalid outbox publisher arguments")
    Just (parkBeforeAppend, parkAfterAppend, loop, pauseMicros) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> Broker.withTableBroker postgres.connectionString \broker -> do
          let KeiroRunner runFixture = fixture.runner
              model = Broker.BrokerModel 0 0 4
              hooks =
                Broker.PublishHook
                  ( \rows -> do
                      context.send (WrkCustom "batch-claimed" (object ["rows" .= length rows]))
                      if parkBeforeAppend then forever (threadDelay 1000000) else pure ()
                  )
                  ( \rows -> do
                      context.send (WrkCustom "broker-appended" (object ["rows" .= length rows]))
                      if parkAfterAppend then forever (threadDelay 1000000) else pure ()
                  )
              callback = Broker.publishScripted broker model (const Broker.Succeed) hooks context.init.instanceName
              options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}
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
