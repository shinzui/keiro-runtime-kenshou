module Kenshou.Suite.Shibuya.Fixture.Kiroku
  ( KirokuFixture (..),
    DeadLetterRow (..),
    withKirokuFixture,
    withKirokuConnectionPool,
    subscriptionFor,
    appendEvents,
    appendTypedEvents,
    eventPositions,
    checkpointOf,
    deadLettersOf,
    EffectRow (..),
    ensureEffectsTable,
    insertEffect,
    effectsOf,
  )
where

import Control.Exception (bracket)
import Data.Aeson (Value, object, (.=))
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Hasql.Connection.Settings qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (renderRunId)
import Kiroku.Store (CategoryName (..), EventData (..), EventType (..), ExpectedVersion (..), KirokuStore, StreamName (..), SubscriptionName (..), appendToStream, defaultConnectionSettings, runStoreIO, withStore)

data KirokuFixture = KirokuFixture
  { store :: !KirokuStore,
    pool :: !Pool,
    category :: !CategoryName,
    stream :: !StreamName,
    prefix :: !Text
  }

data DeadLetterRow = DeadLetterRow
  { position :: !Int64,
    eventId :: !Text,
    reason :: !Value,
    attempts :: !Int32
  }
  deriving stock (Eq, Show)

data EffectRow = EffectRow
  { position :: !Int64,
    eventId :: !Text,
    member :: !Int32,
    process :: !Int32,
    at :: !UTCTime
  }
  deriving stock (Eq, Show)

withKirokuFixture :: RunContext -> (KirokuFixture -> IO a) -> IO a
withKirokuFixture context action = do
  let connection = (requirePostgres context).connectionString
      tag = Text.take 8 (Text.filter (/= '-') (renderRunId context.runId))
      category = CategoryName ("ks" <> tag)
      stream = StreamName ("ks" <> tag <> "-1")
      prefix = "ks-" <> renderRunId context.runId
  withKirokuConnectionPool connection "kenshou-shibuya-kiroku-oracle" $ \pool ->
    withStore (defaultConnectionSettings connection) $ \store ->
      action (KirokuFixture store pool category stream prefix)

withKirokuConnectionPool :: Text -> Text -> (Pool -> IO a) -> IO a
withKirokuConnectionPool connection applicationName =
  bracket (Pool.acquire settings) Pool.release
  where
    settings =
      PoolConfig.settings
        [ PoolConfig.size 10,
          PoolConfig.acquisitionTimeout 5,
          PoolConfig.staticConnectionSettings (Connection.connectionString connection <> Connection.applicationName applicationName)
        ]

subscriptionFor :: KirokuFixture -> Text -> SubscriptionName
subscriptionFor fixture suffix = SubscriptionName (fixture.prefix <> "-" <> suffix)

appendEvents :: KirokuFixture -> Int -> IO ()
appendEvents fixture count = appendTypedEvents fixture [(number, "Kenshou") | number <- [1 .. count]]

appendTypedEvents :: KirokuFixture -> [(Int, Text)] -> IO ()
appendTypedEvents fixture eventsToAppend = do
  let events =
        [ EventData Nothing (EventType eventType) (object ["sequence" .= number, "stream" .= streamName]) Nothing Nothing Nothing
        | (number, eventType) <- eventsToAppend
        ]
      StreamName streamName = fixture.stream
  result <- runStoreIO fixture.store (appendToStream fixture.stream NoStream events)
  either (ioError . userError . show) (const (pure ())) result

eventPositions :: KirokuFixture -> IO [Int64]
eventPositions fixture =
  query fixture.pool $ Session.statement streamName statement
  where
    StreamName streamName = fixture.stream
    statement =
      Statement.preparable
        "select a.stream_version from kiroku.stream_events a join kiroku.streams s on s.stream_id = a.original_stream_id where a.stream_id = 0 and s.stream_name = $1 order by a.stream_version"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int8)))

checkpointOf :: KirokuFixture -> SubscriptionName -> Int32 -> IO (Maybe Int64)
checkpointOf fixture (SubscriptionName name) member =
  query fixture.pool $ Session.statement (name, member) statement
  where
    statement =
      Statement.preparable
        "select last_seen from kiroku.subscriptions where subscription_name = $1 and consumer_group_member = $2"
        (contramap fst (Encoders.param (Encoders.nonNullable Encoders.text)) <> contramap snd (Encoders.param (Encoders.nonNullable Encoders.int4)))
        (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.int8)))

deadLettersOf :: KirokuFixture -> SubscriptionName -> Int32 -> IO [DeadLetterRow]
deadLettersOf fixture (SubscriptionName name) member =
  query fixture.pool $ Session.statement (name, member) statement
  where
    statement =
      Statement.preparable
        "select global_position, event_id::text, reason, attempt_count from kiroku.dead_letters where subscription_name = $1 and consumer_group_member = $2 order by global_position"
        (contramap fst (Encoders.param (Encoders.nonNullable Encoders.text)) <> contramap snd (Encoders.param (Encoders.nonNullable Encoders.int4)))
        (Decoders.rowList (DeadLetterRow <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.jsonb) <*> Decoders.column (Decoders.nonNullable Decoders.int4)))

ensureEffectsTable :: Pool -> IO ()
ensureEffectsTable pool =
  query pool $ Session.statement () statement
  where
    statement =
      Statement.unpreparable
        "create table if not exists kenshou_shibuya_kiroku_effects (arm text not null, global_position bigint not null, event_id text not null, member integer not null, process integer not null, at timestamptz not null)"
        Encoders.noParams
        Decoders.noResult

insertEffect :: Pool -> Text -> EffectRow -> IO ()
insertEffect pool arm row =
  query pool $ Session.statement (arm, row) statement
  where
    statement =
      Statement.preparable
        "insert into kenshou_shibuya_kiroku_effects (arm, global_position, event_id, member, process, at) values ($1, $2, $3, $4, $5, $6)"
        ( contramap fst (Encoders.param (Encoders.nonNullable Encoders.text))
            <> contramap (\(_, effect) -> effect.position) (Encoders.param (Encoders.nonNullable Encoders.int8))
            <> contramap (\(_, effect) -> effect.eventId) (Encoders.param (Encoders.nonNullable Encoders.text))
            <> contramap (\(_, effect) -> effect.member) (Encoders.param (Encoders.nonNullable Encoders.int4))
            <> contramap (\(_, effect) -> effect.process) (Encoders.param (Encoders.nonNullable Encoders.int4))
            <> contramap (\(_, effect) -> effect.at) (Encoders.param (Encoders.nonNullable Encoders.timestamptz))
        )
        Decoders.noResult

effectsOf :: Pool -> Text -> IO [EffectRow]
effectsOf pool arm =
  query pool $ Session.statement arm statement
  where
    statement =
      Statement.preparable
        "select global_position, event_id, member, process, at from kenshou_shibuya_kiroku_effects where arm = $1 order by at, global_position"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.rowList (EffectRow <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int4) <*> Decoders.column (Decoders.nonNullable Decoders.int4) <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)))

query :: Pool -> Session.Session a -> IO a
query pool session = do
  result <- Pool.use pool session
  either (ioError . userError . show) pure result
