module Kenshou.Suite.Shibuya.Fixture.KirokuWorker (role) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (liftIO, runEff)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (EffectRow (..), insertEffect, withKirokuConnectionPool)
import Kiroku.Store (CategoryName (..), GlobalPosition (..), RecordedEvent (..), defaultConnectionSettings, withStore)
import Shibuya.Adapter.Kiroku (ConsumerGroup (..), KirokuAdapterConfig (..), SubscriptionName (..), SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)

role :: WorkerRole
role = WorkerRole roleName "Consumes a Kiroku subscription in a separate Shibuya process with durable handler effects." worker

roleName :: RoleName
roleName = either (error . Text.unpack) id (mkRoleName "shibuya/kiroku-consumer")

data Args = Args
  { subscription :: !Text,
    category :: !Text,
    arm :: !Text,
    member :: !Int32,
    groupSize :: !Int32,
    processIndex :: !Int32
  }

parseArgs :: Value -> Parser Args
parseArgs = withObject "Kiroku consumer arguments" $ \value -> do
  subscription <- value .: "subscription"
  category <- value .: "category"
  arm <- value .: "arm"
  member <- value .: "member"
  groupSize <- value .: "groupSize"
  processIndex <- value .: "processIndex"
  pure Args {subscription, category, arm, member, groupSize, processIndex}

worker :: RoleContext -> IO ()
worker context = do
  postgres <- maybe (fail "Kiroku consumer requires PostgreSQL") pure context.init.postgres
  args <- either fail pure (parseEither parseArgs context.init.args)
  context.send WrkReady
  awaitStart
  let connection = postgres.connectionString
      applicationName = "kenshou-shibuya-kiroku-" <> Text.pack (show args.processIndex)
      settings = defaultConnectionSettings (connection <> " application_name=" <> applicationName)
  withKirokuConnectionPool connection applicationName $ \pool ->
    withStore settings $ \store -> do
      let config =
            (defaultKirokuAdapterConfig (SubscriptionName args.subscription) (Category (CategoryName args.category)))
              { consumerGroup = if args.groupSize == 0 then Nothing else Just (ConsumerGroup args.member args.groupSize)
              }
          handler message = do
            let GlobalPosition position = message.envelope.payload.globalPosition
                MessageId eventId = message.envelope.messageId
            at <- liftIO getCurrentTime
            liftIO $ insertEffect pool args.arm (EffectRow position eventId args.member args.processIndex at)
            pure AckOk
      runEff $ runTracingNoop $ do
        adapter <- kirokuAdapter store config
        started <- runApp defaultAppConfig [(ProcessorId ("kiroku-" <> args.arm <> "-" <> Text.pack (show args.processIndex)), mkProcessor adapter handler)]
        case started of
          Left err -> error (show err)
          Right handle -> do
            liftIO $ context.send (WrkCustom "running" (object ["process" .= args.processIndex]))
            liftIO awaitStop
            drained <- stopAppGracefully defaultShutdownConfig handle
            waitApp handle
            liftIO $ context.send (WrkCustom "stopped" (object ["drained" .= drained]))
  where
    awaitStart =
      context.receive >>= \case
        Just CtlStart -> pure ()
        Just (CtlStop _) -> fail "Kiroku consumer stopped before start"
        Nothing -> fail "Kiroku consumer parent disconnected before start"
        _ -> awaitStart
    awaitStop =
      context.receive >>= \case
        Just (CtlStop _) -> pure ()
        Nothing -> pure ()
        _ -> awaitStop
