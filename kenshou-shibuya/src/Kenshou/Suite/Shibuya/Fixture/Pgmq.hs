module Kenshou.Suite.Shibuya.Fixture.Pgmq
  ( PgmqFixture (..),
    withPgmqFixture,
    withPgmqConnectionPool,
    runPgmqStack,
    queueRows,
    archiveRows,
    queueReadState,
    queueLeaseRows,
    queueLeaseRow,
    queuePayloads,
    dlqRowsWithReason,
    activeLongPolls,
    ensureEffectsTable,
    insertEffect,
    effectRows,
  )
where

import Control.Exception (bracket, finally)
import Data.Aeson (Value)
import Data.Functor.Contravariant (contramap)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
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
import Pgmq.Effectful (Pgmq, PgmqRuntimeError, createQueue, dropQueue, runPgmq)
import Shibuya.Adapter.Pgmq (QueueName, parseQueueName, queueNameToText)
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)

data PgmqFixture = PgmqFixture {pool :: !Pool, queue :: !QueueName}

withPgmqFixture :: RunContext -> Text -> Int -> (PgmqFixture -> IO a) -> IO a
withPgmqFixture context suffix poolSize action =
  withPgmqConnectionPool (requirePostgres context).connectionString poolSize $ \pool -> do
    let queue = queueFor context suffix
    created <- runPgmqStack pool (createQueue queue)
    case created of
      Left err -> ioError (userError (show err))
      Right () -> action (PgmqFixture pool queue) `finally` dropFixtureQueue pool queue

withPgmqConnectionPool :: Text -> Int -> (Pool -> IO a) -> IO a
withPgmqConnectionPool connection poolSize =
  bracket
    ( Pool.acquire $
        PoolConfig.settings
          [ PoolConfig.size poolSize,
            PoolConfig.acquisitionTimeout 5,
            PoolConfig.staticConnectionSettings (Connection.connectionString connection <> Connection.applicationName "kenshou-shibuya-pgmq")
          ]
    )
    Pool.release

queueFor :: RunContext -> Text -> QueueName
queueFor context suffix =
  either (error . show) id . parseQueueName $
    "ks_" <> Text.take 8 (Text.filter (/= '-') (renderRunId context.runId)) <> "_" <> Text.take 35 (Text.map safe (Text.toLower suffix))
  where
    safe character
      | character >= 'a' && character <= 'z' = character
      | character >= '0' && character <= '9' = character
      | otherwise = '_'

dropFixtureQueue :: Pool -> QueueName -> IO ()
dropFixtureQueue pool queue = do
  dropped <- runPgmqStack pool (dropQueue queue)
  either (ioError . userError . show) (const (pure ())) dropped

runPgmqStack :: Pool -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] a -> IO (Either PgmqRuntimeError a)
runPgmqStack pool = runEff . runErrorNoCallStack @PgmqRuntimeError . runTracingNoop . runPgmq pool

queueRows :: PgmqFixture -> IO Int64
queueRows fixture = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement = Statement.preparable ("select count(*) from " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result

archiveRows :: PgmqFixture -> IO Int64
archiveRows fixture = do
  let table = "pgmq.a_" <> queueNameToText fixture.queue
      statement = Statement.preparable ("select count(*) from " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result

queueReadState :: PgmqFixture -> IO [(Int64, UTCTime)]
queueReadState fixture = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement =
        Statement.preparable
          ("select read_ct, vt from " <> table <> " order by msg_id")
          Encoders.noParams
          (Decoders.rowList ((,) <$> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)))
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result

queueLeaseRows :: PgmqFixture -> IO [(Int64, Int64, UTCTime)]
queueLeaseRows fixture = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement =
        Statement.preparable
          ("select msg_id, read_ct, vt from " <> table <> " order by msg_id")
          Encoders.noParams
          ( Decoders.rowList
              ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz))
          )
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result

queueLeaseRow :: PgmqFixture -> Int64 -> IO (Maybe (Int64, UTCTime))
queueLeaseRow fixture identifier = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement =
        Statement.preparable
          ("select read_ct, vt from " <> table <> " where msg_id = $1")
          (Encoders.param (Encoders.nonNullable Encoders.int8))
          (Decoders.rowMaybe ((,) <$> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4)) <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)))
  result <- Pool.use fixture.pool (Session.statement identifier statement)
  either (ioError . userError . show) pure result

ensureEffectsTable :: Pool -> IO ()
ensureEffectsTable pool = do
  let statement =
        Statement.unpreparable
          "create table if not exists kenshou_shibuya_effects (arm text not null, message_id text not null, attempt bigint not null, started_at timestamptz not null, completed_at timestamptz not null, read_delay_seconds double precision)"
          Encoders.noParams
          Decoders.noResult
  result <- Pool.use pool (Session.statement () statement)
  either (ioError . userError . show) pure result

insertEffect :: Pool -> Text -> Text -> Int64 -> UTCTime -> UTCTime -> Maybe Double -> IO ()
insertEffect pool arm identifier attempt startedAt completedAt readDelay = do
  let statement =
        Statement.preparable
          "insert into kenshou_shibuya_effects (arm, message_id, attempt, started_at, completed_at, read_delay_seconds) values ($1, $2, $3, $4, $5, $6)"
          ( contramap (.effectArm) (Encoders.param (Encoders.nonNullable Encoders.text))
              <> contramap (.effectId) (Encoders.param (Encoders.nonNullable Encoders.text))
              <> contramap (.effectAttempt) (Encoders.param (Encoders.nonNullable Encoders.int8))
              <> contramap (.effectStartedAt) (Encoders.param (Encoders.nonNullable Encoders.timestamptz))
              <> contramap (.effectCompletedAt) (Encoders.param (Encoders.nonNullable Encoders.timestamptz))
              <> contramap (.effectReadDelay) (Encoders.param (Encoders.nullable Encoders.float8))
          )
          Decoders.noResult
  result <- Pool.use pool (Session.statement (EffectInsert arm identifier attempt startedAt completedAt readDelay) statement)
  either (ioError . userError . show) pure result

data EffectInsert = EffectInsert
  { effectArm :: !Text,
    effectId :: !Text,
    effectAttempt :: !Int64,
    effectStartedAt :: !UTCTime,
    effectCompletedAt :: !UTCTime,
    effectReadDelay :: !(Maybe Double)
  }

effectRows :: Pool -> Text -> IO [(Text, Int64, Maybe Double)]
effectRows pool arm = do
  let statement =
        Statement.preparable
          "select message_id, attempt, read_delay_seconds from kenshou_shibuya_effects where arm = $1"
          (Encoders.param (Encoders.nonNullable Encoders.text))
          (Decoders.rowList ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nullable Decoders.float8)))
  result <- Pool.use pool (Session.statement arm statement)
  either (ioError . userError . show) pure result

queuePayloads :: PgmqFixture -> IO [Value]
queuePayloads fixture = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement = Statement.preparable ("select message from " <> table <> " order by msg_id") Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.jsonb)))
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result

dlqRowsWithReason :: PgmqFixture -> Text -> IO Int64
dlqRowsWithReason fixture reason = do
  let table = "pgmq.q_" <> queueNameToText fixture.queue
      statement =
        Statement.preparable
          ("select count(*) from " <> table <> " where message->>'dead_letter_reason_code' = $1")
          (Encoders.param (Encoders.nonNullable Encoders.text))
          (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  result <- Pool.use fixture.pool (Session.statement reason statement)
  either (ioError . userError . show) pure result

activeLongPolls :: PgmqFixture -> IO Int64
activeLongPolls fixture = do
  let statement =
        Statement.preparable
          "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and application_name = 'kenshou-shibuya-pgmq' and state = 'active' and query like '%pgmq.read_with_poll%'"
          Encoders.noParams
          (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
  result <- Pool.use fixture.pool (Session.statement () statement)
  either (ioError . userError . show) pure result
