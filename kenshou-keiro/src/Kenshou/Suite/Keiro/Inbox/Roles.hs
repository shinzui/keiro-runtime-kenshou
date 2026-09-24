module Kenshou.Suite.Keiro.Inbox.Roles (roles) where

import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxDedupePolicy (..), InboxResult (..), runInboxTransaction)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxRow (..), listOutbox)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Inbox.Correctness (effectInsertStatement)
import Kiroku.Store (defaultConnectionSettings)

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/inbox-consumer") "Delivers one integration event through the transactional inbox." consumer]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

consumer :: RoleContext -> IO ()
consumer context = case context.init.postgres of
  Nothing -> context.send (WrkError "inbox consumer requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "inbox consumer args" (\value -> (,) <$> value .: "source" <*> value .: "messageId")) context.init.args of
    Nothing -> context.send (WrkError "invalid inbox consumer arguments")
    Just (source, messageId) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
          let KeiroRunner runFixture = fixture.runner
              handler event = do
                Tx.sql "SELECT pg_sleep(1)"
                Tx.statement event.messageId effectInsertStatement
          outboxRows <- runFixture (listOutbox source) >>= either (fail . show) pure
          case [row.event | row <- outboxRows, row.event.messageId == messageId] of
            [event] -> do
              result <- runFixture (runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler)
              let classification = case result of
                    Right (Right (InboxProcessed ())) -> "processed"
                    Right (Right InboxDuplicate) -> "duplicate"
                    other -> "unexpected:" <> Text.pack (show other)
              context.send (WrkCustom "finished" (object ["classification" .= classification]))
            _ -> context.send (WrkError "inbox event missing")
        _ -> pure ()
