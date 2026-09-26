module Kenshou.Suite.Shibuya.Fixture.Pgmq
  ( PgmqFixture (..),
    withPgmqFixture,
    withPgmqConnectionPool,
    runPgmqStack,
    queueRows,
    archiveRows,
    queueReadState,
    queueLeaseRows,
    queuePayloads,
    dlqRowsWithReason,
    activeLongPolls,
  )
where

import Control.Exception (bracket, finally)
import Data.Aeson (Value)
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
