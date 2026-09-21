module Kenshou.Measure.Sampler.Postgres
  ( PgStatementsMode (..),
    PgSamplerConfig (..),
    PostgresSampler,
    openPostgresSampler,
    samplePostgres,
    closePostgresSampler,
    postgresHasStatements,
    postgresPeriodic,
    postgresArtifactNames,
  )
where

import Control.Exception (finally)
import Control.Monad (forM_, when)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Measure.Sampler.Csv

data PgStatementsMode = PgStatementsOff | PgStatementsSnapshots | PgStatementsPeriodic
  deriving stock (Eq, Show)

data PgSamplerConfig = PgSamplerConfig
  { connectionString :: Text,
    relations :: [Text],
    statements :: PgStatementsMode,
    serverVersionNum :: Int
  }
  deriving stock (Eq, Show)

data PostgresSampler = PostgresSampler
  { connection :: Connection.Connection,
    activity :: CsvWriter,
    checkpointer :: CsvWriter,
    wal :: CsvWriter,
    database :: CsvWriter,
    relations :: CsvWriter,
    statements :: Maybe CsvWriter,
    watchedRelations :: [Text],
    versionNumber :: Int,
    statementsMode :: PgStatementsMode,
    logLine :: Text -> IO ()
  }

postgresArtifactNames :: Bool -> [FilePath]
postgresArtifactNames hasStatements =
  ["pg-activity.csv", "pg-checkpointer.csv", "pg-wal.csv", "pg-database.csv", "pg-relations.csv"]
    <> ["pg-statements.csv" | hasStatements]

openPostgresSampler :: FilePath -> PgSamplerConfig -> (Text -> IO ()) -> IO (Either Text PostgresSampler)
openPostgresSampler seriesDir config logger = do
  acquired <- Connection.acquire (Settings.connectionString config.connectionString <> Settings.applicationName "kenshou-sampler")
  case acquired of
    Left err -> pure (Left (Text.pack (show err)))
    Right connection -> do
      activity <- openCsv (seriesDir <> "/pg-activity.csv") (base <> ["application_name", "state", "wait_event_type", "wait_event", "connections"])
      checkpointer <- openCsv (seriesDir <> "/pg-checkpointer.csv") (base <> ["num_timed", "num_requested", "write_time_ms", "sync_time_ms", "buffers_written", "checkpoint_lsn", "checkpoint_time_unix", "num_done"])
      wal <- openCsv (seriesDir <> "/pg-wal.csv") (base <> ["current_wal_bytes", "wal_records", "wal_fpi", "wal_bytes", "wal_buffers_full"])
      database <- openCsv (seriesDir <> "/pg-database.csv") (base <> ["xact_commit", "xact_rollback", "blks_read", "blks_hit", "tup_inserted", "tup_updated", "tup_deleted", "deadlocks", "temp_bytes"])
      relations <- openCsv (seriesDir <> "/pg-relations.csv") (base <> ["relation", "relation_bytes", "indexes_bytes", "total_bytes", "n_live_tup", "n_dead_tup", "n_tup_ins", "n_tup_upd", "n_tup_del", "autovacuum_count"])
      statements <-
        if config.statements == PgStatementsOff
          then pure Nothing
          else do
            created <- Connection.use connection (Session.statement () createStatements)
            probed <- case created of Left err -> pure (Left err); Right () -> Connection.use connection (Session.statement () probeStatements)
            case probed of
              Left err -> logger ("pg_stat_statements unavailable: " <> Text.pack (show err)) >> pure Nothing
              Right () -> Just <$> openCsv (seriesDir <> "/pg-statements.csv") (base <> ["queryid", "calls", "total_exec_time_ms", "rows", "shared_blks_hit", "shared_blks_read", "wal_bytes"])
      pure (Right PostgresSampler {connection, activity, checkpointer, wal, database, relations, statements, watchedRelations = config.relations, versionNumber = config.serverVersionNum, statementsMode = config.statements, logLine = logger})
  where
    base = ["t_mono_ns", "t_wall_ms", "phase"]

samplePostgres :: PostgresSampler -> [Text] -> Bool -> IO ()
samplePostgres sampler prefix includeStatements = do
  writeRows sampler sampler.activity prefix activityQuery
  writeRows sampler sampler.checkpointer prefix (if sampler.versionNumber >= 180000 then checkpointer18Query else checkpointer17Query)
  writeRows sampler sampler.wal prefix walQuery
  writeRows sampler sampler.database prefix databaseQuery
  forM_ sampler.watchedRelations \relation -> writeParamRows sampler sampler.relations prefix relation relationQuery
  when includeStatements $ forM_ sampler.statements \writer -> writeRows sampler writer prefix statementsQuery

closePostgresSampler :: PostgresSampler -> IO ()
closePostgresSampler sampler =
  let writers = [sampler.activity, sampler.checkpointer, sampler.wal, sampler.database, sampler.relations] <> maybe [] pure sampler.statements
   in mapM_ closeCsv writers `finally` Connection.release sampler.connection

postgresHasStatements :: PostgresSampler -> Bool
postgresHasStatements = maybe False (const True) . (.statements)

postgresPeriodic :: PostgresSampler -> Bool
postgresPeriodic sampler = sampler.statementsMode == PgStatementsPeriodic

writeRows :: PostgresSampler -> CsvWriter -> [Text] -> Statement.Statement () [Text] -> IO ()
writeRows sampler writer prefix statement = do
  result <- Connection.use sampler.connection (Session.statement () statement)
  case result of
    Left err -> sampler.logLine ("PostgreSQL sampler query failed: " <> Text.pack (show err))
    Right rows -> forM_ rows (appendCsv writer . (prefix <>) . Text.splitOn separator)

writeParamRows :: PostgresSampler -> CsvWriter -> [Text] -> Text -> Statement.Statement Text [Text] -> IO ()
writeParamRows sampler writer prefix parameter statement = do
  result <- Connection.use sampler.connection (Session.statement parameter statement)
  case result of
    Left err -> sampler.logLine ("PostgreSQL relation sampler query failed: " <> Text.pack (show err))
    Right rows -> forM_ rows (appendCsv writer . (prefix <>) . Text.splitOn separator)

separator :: Text
separator = Text.singleton '\x1f'

textRows :: Text -> Statement.Statement () [Text]
textRows sql = Statement.unpreparable sql Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

createStatements, probeStatements :: Statement.Statement () ()
createStatements = Statement.unpreparable "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" Encoders.noParams Decoders.noResult
probeStatements = Statement.unpreparable "SELECT 1 FROM pg_stat_statements(false) LIMIT 0" Encoders.noParams Decoders.noResult

activityQuery, checkpointer17Query, checkpointer18Query, walQuery, databaseQuery, statementsQuery :: Statement.Statement () [Text]
activityQuery = textRows "SELECT concat_ws(chr(31), coalesce(application_name,''), coalesce(state,''), coalesce(wait_event_type,''), coalesce(wait_event,''), count(*)::text) FROM pg_stat_activity WHERE backend_type='client backend' AND application_name <> 'kenshou-sampler' GROUP BY application_name,state,wait_event_type,wait_event ORDER BY application_name,state,wait_event_type,wait_event"
checkpointer17Query = textRows "SELECT concat_ws(chr(31), c.num_timed::text, c.num_requested::text, c.write_time::text, c.sync_time::text, c.buffers_written::text, (pg_control_checkpoint()).checkpoint_lsn::text, extract(epoch FROM (pg_control_checkpoint()).checkpoint_time)::bigint::text, '') FROM pg_stat_checkpointer c"
checkpointer18Query = textRows "SELECT concat_ws(chr(31), c.num_timed::text, c.num_requested::text, c.write_time::text, c.sync_time::text, c.buffers_written::text, (pg_control_checkpoint()).checkpoint_lsn::text, extract(epoch FROM (pg_control_checkpoint()).checkpoint_time)::bigint::text, c.num_done::text) FROM pg_stat_checkpointer c"
walQuery = textRows "SELECT concat_ws(chr(31), pg_wal_lsn_diff(pg_current_wal_lsn(),'0/0')::bigint::text, w.wal_records::text, w.wal_fpi::text, w.wal_bytes::bigint::text, w.wal_buffers_full::text) FROM pg_stat_wal w"
databaseQuery = textRows "SELECT concat_ws(chr(31), xact_commit::text, xact_rollback::text, blks_read::text, blks_hit::text, tup_inserted::text, tup_updated::text, tup_deleted::text, deadlocks::text, temp_bytes::text) FROM pg_stat_database WHERE datname=current_database()"
statementsQuery = textRows "SELECT concat_ws(chr(31), queryid::text, calls::text, total_exec_time::text, rows::text, shared_blks_hit::text, shared_blks_read::text, wal_bytes::bigint::text) FROM pg_stat_statements(false) WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) ORDER BY queryid"

relationQuery :: Statement.Statement Text [Text]
relationQuery =
  Statement.unpreparable
    "SELECT concat_ws(chr(31), $1::text, pg_relation_size($1::regclass)::text, pg_indexes_size($1::regclass)::text, pg_total_relation_size($1::regclass)::text, s.n_live_tup::text, s.n_dead_tup::text, s.n_tup_ins::text, s.n_tup_upd::text, s.n_tup_del::text, s.autovacuum_count::text) FROM pg_stat_all_tables s WHERE s.relid=$1::regclass"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
