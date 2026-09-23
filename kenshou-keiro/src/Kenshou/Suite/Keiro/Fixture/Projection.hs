module Kenshou.Suite.Keiro.Fixture.Projection
  ( fixtureSchema,
    ensureFixtureReadModels,
    accountBalanceProjection,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Connection (ensureProjectionSchema)
import Keiro.Projection (InlineProjection (..))
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..), StreamVersion (..))

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
