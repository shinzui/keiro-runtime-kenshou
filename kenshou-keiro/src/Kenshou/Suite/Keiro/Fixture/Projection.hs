module Kenshou.Suite.Keiro.Fixture.Projection
  ( fixtureSchema,
    ensureFixtureReadModels,
    accountBalanceProjection,
    accountActivityProjection,
    accountActivityReadModelName,
    ProjectionSabotage (..),
    runAccountActivityWorker,
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int32)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Codec (Codec (..))
import Keiro.Connection (ensureProjectionSchema)
import Keiro.Projection (AsyncApplyOutcome (..), AsyncProjection (..), InlineProjection (..), applyAsyncProjection)
import Keiro.ReadModel.Schema (registerReadModel)
import Kenshou.Suite.Keiro.Fixture.Account (accountCodec)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store (KirokuStore, Store, runStoreIO, runTransaction)
import Kiroku.Store.Subscription (RetryDelay (..), SubscriptionConfigM (..), SubscriptionHandleM (..), SubscriptionName (..), SubscriptionResult (..), SubscriptionTarget (..), defaultSubscriptionConfig, withSubscription)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..), StreamVersion (..))

data ProjectionSabotage = NoProjectionSabotage | SkipDedup
  deriving stock (Eq, Show)

runAccountActivityWorker :: KirokuStore -> Int32 -> ProjectionSabotage -> (RecordedEvent -> AsyncApplyOutcome -> IO ()) -> IO ()
runAccountActivityWorker store batchSize sabotage observed = do
  let handle recorded = do
        outcome <- runStoreIO store $ runTransaction $ case sabotage of
          NoProjectionSabotage -> applyAsyncProjection accountActivityProjection recorded
          SkipDedup -> accountActivityProjection.applyRecorded recorded >> pure AsyncApplied
        case outcome of
          Right result -> do
            observed recorded result
            pure $ case result of
              AsyncFenced -> Retry (RetryDelay 1)
              _ -> Continue
          Left _ -> pure (Retry (RetryDelay 1))
      config =
        (defaultSubscriptionConfig (SubscriptionName "kenshou-account-activity") (Category (CategoryName "account")) handle)
          { batchSize = batchSize
          }
  withSubscription store config \subscription -> subscription.wait >>= either throwIO pure

fixtureSchema :: Text
fixtureSchema = "kenshou_keiro"

ensureFixtureReadModels :: (Store :> es) => Eff es ()
ensureFixtureReadModels = do
  ensureProjectionSchema fixtureSchema
  runTransaction $
    Tx.sql
      "CREATE TABLE IF NOT EXISTS kenshou_keiro.account_balance (account_id text PRIMARY KEY, balance bigint NOT NULL, entries bigint NOT NULL, last_version bigint NOT NULL, last_global_position bigint NOT NULL, status text NOT NULL)"
  runTransaction $
    Tx.sql
      "CREATE TABLE IF NOT EXISTS kenshou_keiro.account_activity (account_id text PRIMARY KEY, events_applied bigint NOT NULL, net_amount bigint NOT NULL, last_global_position bigint NOT NULL)"
  runTransaction $
    Tx.sql
      "CREATE TABLE IF NOT EXISTS kenshou_keiro.account_directory (account_id text PRIMARY KEY, segment text NOT NULL)"
  _ <- registerReadModel accountActivityReadModelName 1 "v1"
  pure ()

accountActivityReadModelName :: Text
accountActivityReadModelName = "kenshou-account-activity"

accountActivityProjection :: AsyncProjection
accountActivityProjection =
  AsyncProjection
    { name = "kenshou-account-activity",
      readModelName = accountActivityReadModelName,
      subscriptionName = "kenshou-account-activity",
      idempotencyKey = (.eventId),
      applyRecorded = \recorded ->
        case accountCodec.decode recorded.eventType recorded.payload of
          Left _ -> Tx.sql "SELECT 1/0"
          Right event ->
            let AccountId accountId = eventAccountId event
                delta = case event of
                  AccountOpened d -> d.openingBalance
                  Deposited d -> d.amount
                  Withdrawn d -> negate d.amount
                  TransferDebited d -> negate d.amount
                  TransferAnnounced {} -> 0
                  TransferCredited d -> d.amount
                  TransferConfirmed {} -> 0
                  BonusCredited d -> d.amount
                  AccountClosed {} -> 0
                GlobalPosition position = recorded.globalPosition
             in Tx.statement (object ["accountId" .= accountId, "delta" .= delta, "position" .= position]) activityStatement
    }

activityStatement :: Statement.Statement Value ()
activityStatement =
  Statement.preparable
    "INSERT INTO kenshou_keiro.account_activity (account_id, events_applied, net_amount, last_global_position) SELECT x->>'accountId', 1, (x->>'delta')::bigint, (x->>'position')::bigint FROM (SELECT $1::jsonb AS x) input ON CONFLICT (account_id) DO UPDATE SET events_applied = kenshou_keiro.account_activity.events_applied + 1, net_amount = kenshou_keiro.account_activity.net_amount + EXCLUDED.net_amount, last_global_position = EXCLUDED.last_global_position"
    (Encoders.param (Encoders.nonNullable Encoders.jsonb))
    Decoders.noResult

accountBalanceProjection :: InlineProjection AccountEvent
accountBalanceProjection =
  InlineProjection
    { name = "kenshou-account-balance",
      apply = \event recorded ->
        let AccountId accountId = eventAccountId event
            delta = case event of
              AccountOpened d -> d.openingBalance
              Deposited d -> d.amount
              Withdrawn d -> negate d.amount
              TransferDebited d -> negate d.amount
              TransferAnnounced {} -> 0
              TransferCredited d -> d.amount
              TransferConfirmed {} -> 0
              BonusCredited d -> d.amount
              AccountClosed {} -> 0
            status = case event of AccountClosed {} -> "closed" :: Text; _ -> "open"
            StreamVersion version = recorded.streamVersion
            GlobalPosition position = recorded.globalPosition
         in Tx.statement
              (object ["accountId" .= accountId, "delta" .= delta, "version" .= version, "position" .= position, "status" .= status])
              balanceStatement
    }

balanceStatement :: Statement.Statement Value ()
balanceStatement =
  Statement.preparable
    "INSERT INTO kenshou_keiro.account_balance (account_id, balance, entries, last_version, last_global_position, status) SELECT x->>'accountId', (x->>'delta')::bigint, 1, (x->>'version')::bigint, (x->>'position')::bigint, x->>'status' FROM (SELECT $1::jsonb AS x) input ON CONFLICT (account_id) DO UPDATE SET balance = kenshou_keiro.account_balance.balance + EXCLUDED.balance, entries = kenshou_keiro.account_balance.entries + 1, last_version = EXCLUDED.last_version, last_global_position = EXCLUDED.last_global_position, status = EXCLUDED.status"
    (Encoders.param (Encoders.nonNullable Encoders.jsonb))
    Decoders.noResult
