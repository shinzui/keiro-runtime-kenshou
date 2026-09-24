module Kenshou.Suite.Keiro.Inbox.Roles (roles) where

import Control.Exception (SomeException, try)
import Data.Aeson (object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Transaction qualified as Tx
import Keiro.Command (defaultRunCommandOptions, runCommand, runCommandWithSql)
import Keiro.Inbox (InboxDedupePolicy (..), InboxResult (..), runInboxDelegated, runInboxTransaction)
import Keiro.Inbox.Delegated (delegatedCommand, delegatedEventId)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxRow (..), listOutbox)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountEventStream, accountStream, accountStreamName)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountId (..), DepositData (..))
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
  Just postgres -> case parseMaybe (withObject "inbox consumer args" (\value -> (,,,,) <$> value .: "source" <*> value .: "messageId" <*> (value .:? "parkInHandler" .!= False) <*> (value .:? "delegated" .!= False) <*> (value .:? "target"))) context.init.args of
    Nothing -> context.send (WrkError "invalid inbox consumer arguments")
    Just (source, messageId, parkInHandler, delegated, target) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
          let KeiroRunner runFixture = fixture.runner
              handler event = do
                Tx.sql (if parkInHandler then "SELECT pg_sleep(30)" else "SELECT pg_sleep(1)")
                Tx.statement event.messageId effectInsertStatement
          outboxRows <- runFixture (listOutbox source) >>= either (fail . show) pure
          case [row.event | row <- outboxRows, row.event.messageId == messageId] of
            [event] -> do
              classification <- case (delegated, target) of
                (True, Just targetName) -> do
                  let account = AccountId targetName
                      streamName = accountStreamName account
                  attempt <-
                    try @SomeException $
                      runFixture
                        ( runInboxDelegated Nothing PreferIntegrationMessageId event Nothing \dedupe delivered -> do
                            let receipt = delegatedEventId "kenshou-consumer" delivered.source dedupe streamName "deposit"
                            commandResult <- delegatedCommand defaultRunCommandOptions streamName receipt \prepared ->
                              if parkInHandler
                                then fmap (fmap fst) (runCommandWithSql prepared (accountEventStream SnapNever) (accountStream account) (Deposit (DepositData account 1 "delegated-race")) (\_ -> Tx.sql "SELECT pg_sleep(30)"))
                                else runCommand prepared (accountEventStream SnapNever) (accountStream account) (Deposit (DepositData account 1 "delegated-race"))
                            either (error . show) pure commandResult
                        )
                  pure (either (const "unexpected") classify attempt)
                (False, _) -> classify <$> runFixture (runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler)
                _ -> fail "delegated inbox consumer requires a target"
              context.send (WrkCustom "finished" (object ["classification" .= classification]))
            _ -> context.send (WrkError "inbox event missing")
        _ -> pure ()

classify :: Either e (Either e' (InboxResult a)) -> Text
classify = \case
  Right (Right (InboxProcessed _)) -> "processed"
  Right (Right InboxDuplicate) -> "duplicate"
  _ -> "unexpected"
