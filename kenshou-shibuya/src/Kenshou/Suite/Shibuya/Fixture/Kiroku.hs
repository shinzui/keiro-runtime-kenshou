module Kenshou.Suite.Shibuya.Fixture.Kiroku
  ( KirokuFixture (..),
    DeadLetterRow (..),
    withKirokuFixture,
    subscriptionFor,
    appendEvents,
    appendTypedEvents,
    eventPositions,
    checkpointOf,
    deadLettersOf,
  )
where

import Control.Exception (bracket)
import Data.Aeson (Value, object, (.=))
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as Text
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

withKirokuFixture :: RunContext -> (KirokuFixture -> IO a) -> IO a
withKirokuFixture context action = do
  let connection = (requirePostgres context).connectionString
      tag = Text.take 8 (Text.filter (/= '-') (renderRunId context.runId))
      category = CategoryName ("ks" <> tag)
      stream = StreamName ("ks" <> tag <> "-1")
      prefix = "ks-" <> renderRunId context.runId
      poolSettings =
        PoolConfig.settings
          [ PoolConfig.size 10,
            PoolConfig.acquisitionTimeout 5,
            PoolConfig.staticConnectionSettings (Connection.connectionString connection <> Connection.applicationName "kenshou-shibuya-kiroku-oracle")
          ]
  bracket (Pool.acquire poolSettings) Pool.release $ \pool ->
    withStore (defaultConnectionSettings connection) $ \store ->
      action (KirokuFixture store pool category stream prefix)

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

query :: Pool -> Session.Session a -> IO a
query pool session = do
  result <- Pool.use pool session
  either (ioError . userError . show) pure result
