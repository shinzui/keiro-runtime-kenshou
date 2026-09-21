module Kenshou.Diagnose.Postgres
  ( ActivityRow (..),
    LockRow (..),
    StatementRate (..),
    PostgresSnapshot (..),
    AdvisoryKeySpec (..),
    AdvisoryLabel (..),
    captureActivity,
    captureLocks,
    captureStatementRate,
    captureSettings,
    capturePostgres,
    reconstructAdvisoryKey,
    keiroWorkflowStepLock,
    keiroWorkflowLifecycleLock,
    kirokuConsumerGroupGuard,
    pgmqQueueLock,
    pgmqFifoKeyLock,
    pgMigrateLedgerLock,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Bits (shiftL, (.|.))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word32, Word64)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement

data ActivityRow = ActivityRow
  { pid :: !Int,
    applicationName :: !Text,
    state :: !Text,
    waitEventType :: !(Maybe Text),
    waitEvent :: !(Maybe Text),
    transactionAgeSeconds :: !(Maybe Double),
    queryAgeSeconds :: !(Maybe Double),
    blockedBy :: ![Int],
    query :: !Text
  }
  deriving stock (Eq, Show)

data LockRow = LockRow
  { pid :: !(Maybe Int),
    lockType :: !Text,
    mode :: !Text,
    granted :: !Bool,
    relation :: !(Maybe Text),
    transactionId :: !(Maybe Text),
    classId :: !(Maybe Word32),
    objectId :: !(Maybe Word32),
    objectSubId :: !(Maybe Int),
    waitAgeSeconds :: !(Maybe Double)
  }
  deriving stock (Eq, Show)

data StatementRate = StatementRate {source :: !Text, callsPerSecond :: !Double}
  deriving stock (Eq, Show)

data PostgresSnapshot = PostgresSnapshot
  { available :: !Bool,
    error :: !(Maybe Text),
    activity :: ![ActivityRow],
    locks :: ![LockRow],
    statementRate :: !(Maybe StatementRate),
    settings :: !Value
  }
  deriving stock (Eq, Show)

data AdvisoryKeySpec = HashTextExtended !Text | HashText !Text | LiteralKey !Int64
  deriving stock (Eq, Show)

data AdvisoryLabel = AdvisoryLabel {label :: !Text, key :: !AdvisoryKeySpec}
  deriving stock (Eq, Show)

captureActivity :: Connection.Connection -> IO (Either Text [ActivityRow])
captureActivity connection = captureJson connection activitySql

captureLocks :: Connection.Connection -> IO (Either Text [LockRow])
captureLocks connection = captureJson connection locksSql

captureSettings :: Connection.Connection -> IO (Either Text Value)
captureSettings connection = captureJson connection settingsSql

captureStatementRate :: Connection.Connection -> Double -> IO (Either Text StatementRate)
captureStatementRate connection seconds = do
  first <- captureCounter connection statementsCounterSql
  case first of
    Left _ -> fallback
    Right left -> do
      threadDelay interval
      second <- captureCounter connection statementsCounterSql
      case second of
        Right right -> pure (Right (StatementRate "pg_stat_statements" ((right - left) / max 0.001 seconds)))
        Left _ -> fallback
  where
    interval = max 1 (floor (seconds * 1_000_000))
    fallback = do
      fallbackFirst <- captureCounter connection databaseCounterSql
      threadDelay interval
      fallbackSecond <- captureCounter connection databaseCounterSql
      pure $ StatementRate "pg_stat_database" . (/ max 0.001 seconds) <$> ((-) <$> fallbackSecond <*> fallbackFirst)

capturePostgres :: Connection.Connection -> Double -> IO PostgresSnapshot
capturePostgres connection spinSeconds = do
  activity <- captureActivity connection
  locks <- captureLocks connection
  rate <- captureStatementRate connection spinSeconds
  settings <- captureSettings connection
  pure case (activity, locks, settings) of
    (Right activityRows, Right lockRows, Right settingValue) -> PostgresSnapshot True Nothing activityRows lockRows (either (const Nothing) Just rate) settingValue
    _ -> PostgresSnapshot False (Just (Text.intercalate "; " (lefts [void activity, void locks, void settings]))) (either (const []) id activity) (either (const []) id locks) (either (const Nothing) Just rate) (either (const Null) id settings)
  where
    void = fmap (const ())
    lefts = foldr (\value rest -> either (: rest) (const rest) value) []

captureJson :: (FromJSON value) => Connection.Connection -> Text -> IO (Either Text value)
captureJson connection sql = do
  result <- Connection.use connection (Session.statement () (textStatement sql))
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right encoded -> case eitherDecodeStrict' (Text.encodeUtf8 encoded) of Left err -> Left (Text.pack err); Right value -> Right value

captureCounter :: Connection.Connection -> Text -> IO (Either Text Double)
captureCounter connection sql = do
  result <- Connection.use connection (Session.statement () (textStatement sql))
  pure case result of Left err -> Left (Text.pack (show err)); Right value -> maybe (Left ("invalid counter: " <> value)) Right (readDouble value)

readDouble :: Text -> Maybe Double
readDouble value = case reads (Text.unpack value) of [(number, "")] -> Just number; _ -> Nothing

textStatement :: Text -> Statement.Statement () Text
textStatement sql = Statement.unpreparable sql Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

activitySql :: Text
activitySql = "SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text FROM (SELECT pid, coalesce(application_name,'') AS \"applicationName\", coalesce(state,'') AS state, wait_event_type AS \"waitEventType\", wait_event AS \"waitEvent\", extract(epoch FROM clock_timestamp()-xact_start) AS \"transactionAgeSeconds\", extract(epoch FROM clock_timestamp()-query_start) AS \"queryAgeSeconds\", pg_blocking_pids(pid) AS \"blockedBy\", left(query,2000) AS query FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()) t"

locksSql :: Text
locksSql = "SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text FROM (SELECT pid, locktype AS \"lockType\", mode, granted, relation::regclass::text AS relation, transactionid::text AS \"transactionId\", classid AS \"classId\", objid AS \"objectId\", objsubid AS \"objectSubId\", extract(epoch FROM clock_timestamp()-waitstart) AS \"waitAgeSeconds\" FROM pg_locks) t"

settingsSql :: Text
settingsSql = "SELECT jsonb_build_object('maxConnections', current_setting('max_connections')::int, 'deadlockTimeout', current_setting('deadlock_timeout'), 'statementTimeout', current_setting('statement_timeout'))::text"

statementsCounterSql, databaseCounterSql :: Text
statementsCounterSql = "SELECT coalesce(sum(calls),0)::text FROM pg_stat_statements(false) WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database())"
databaseCounterSql = "SELECT (xact_commit+xact_rollback)::text FROM pg_stat_database WHERE datname=current_database()"

reconstructAdvisoryKey :: Word32 -> Word32 -> Int64
reconstructAdvisoryKey high low = fromIntegral (((fromIntegral high :: Word64) `shiftL` 32) .|. fromIntegral low)

keiroWorkflowStepLock :: Text -> Text -> Int -> Text -> AdvisoryLabel
keiroWorkflowStepLock workflowId workflowName generation step = AdvisoryLabel ("keiro workflow step " <> step) (HashTextExtended (Text.intercalate "/" [workflowId, workflowName, Text.pack (show generation), step]))

keiroWorkflowLifecycleLock :: Text -> Text -> Int -> AdvisoryLabel
keiroWorkflowLifecycleLock workflowId workflowName generation = keiroWorkflowStepLock workflowId workflowName generation "__keiro_lifecycle__"

kirokuConsumerGroupGuard :: Text -> Int32 -> AdvisoryLabel
kirokuConsumerGroupGuard subscription member = AdvisoryLabel "kiroku consumer-group guard" (HashTextExtended (subscription <> ":" <> Text.pack (show member)))

pgmqQueueLock :: Text -> AdvisoryLabel
pgmqQueueLock queue = AdvisoryLabel "pgmq queue creation" (HashText ("pgmq.queue_" <> queue))

pgmqFifoKeyLock :: Text -> AdvisoryLabel
pgmqFifoKeyLock key = AdvisoryLabel "pgmq fifo key" (HashTextExtended key)

pgMigrateLedgerLock :: AdvisoryLabel
pgMigrateLedgerLock = AdvisoryLabel "pg-migrate ledger" (LiteralKey 0x70675F6D69677261)

instance ToJSON ActivityRow where
  toJSON row = object ["pid" .= row.pid, "applicationName" .= row.applicationName, "state" .= row.state, "waitEventType" .= row.waitEventType, "waitEvent" .= row.waitEvent, "transactionAgeSeconds" .= row.transactionAgeSeconds, "queryAgeSeconds" .= row.queryAgeSeconds, "blockedBy" .= row.blockedBy, "query" .= row.query]

instance FromJSON ActivityRow where
  parseJSON = withObject "ActivityRow" \value -> ActivityRow <$> value .: "pid" <*> value .:? "applicationName" .!= "" <*> value .:? "state" .!= "" <*> value .:? "waitEventType" <*> value .:? "waitEvent" <*> value .:? "transactionAgeSeconds" <*> value .:? "queryAgeSeconds" <*> value .:? "blockedBy" .!= [] <*> value .:? "query" .!= ""

instance ToJSON LockRow where
  toJSON row = object ["pid" .= row.pid, "lockType" .= row.lockType, "mode" .= row.mode, "granted" .= row.granted, "relation" .= row.relation, "transactionId" .= row.transactionId, "classId" .= row.classId, "objectId" .= row.objectId, "objectSubId" .= row.objectSubId, "waitAgeSeconds" .= row.waitAgeSeconds]

instance FromJSON LockRow where
  parseJSON = withObject "LockRow" \value -> LockRow <$> value .:? "pid" <*> value .:? "lockType" .!= "" <*> value .:? "mode" .!= "" <*> value .:? "granted" .!= False <*> value .:? "relation" <*> value .:? "transactionId" <*> value .:? "classId" <*> value .:? "objectId" <*> value .:? "objectSubId" <*> value .:? "waitAgeSeconds"

instance ToJSON StatementRate where toJSON rate = object ["source" .= rate.source, "callsPerSecond" .= rate.callsPerSecond]

instance FromJSON StatementRate where parseJSON = withObject "StatementRate" \value -> StatementRate <$> value .: "source" <*> value .: "callsPerSecond"

instance ToJSON PostgresSnapshot where toJSON snapshot = object ["available" .= snapshot.available, "error" .= snapshot.error, "activity" .= snapshot.activity, "locks" .= snapshot.locks, "statementRate" .= snapshot.statementRate, "settings" .= snapshot.settings]

instance FromJSON PostgresSnapshot where parseJSON = withObject "PostgresSnapshot" \value -> PostgresSnapshot <$> value .: "available" <*> value .:? "error" <*> value .:? "activity" .!= [] <*> value .:? "locks" .!= [] <*> value .:? "statementRate" <*> value .:? "settings" .!= Null
