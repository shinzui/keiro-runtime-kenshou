module Kenshou.Suite.Kiroku.Bench.Ladder (scenarios) where

import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs)
import Kenshou.Suite.Kiroku.Fixture.Workload (payloadOf)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import Kiroku.Store.SQL qualified as SQL
import System.Info (os)

scenarios :: [Scenario]
scenarios = [layerLadder]

layerLadder :: Scenario
layerLadder =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/benchmark/layer-ladder"),
      revision = 1,
      summary = "Measures raw SQL, a SQL function, kiroku's append statement, and the store API.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 32}) <> measureKnobs Benchmark <> [choice, intKnob "kiroku.append.writers" 32 1 128, intKnob "kiroku.append.payload-bytes" 256 64 65536, intKnob "kiroku.ladder.pool-size" 0 0 256],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = PhasePlan 30 120 15,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runLadder
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    choice = KnobSpec (name "kiroku.ladder.rung") "Ladder rung" KnobText (VText "store-api") (OneOf (VText "store-api" :| fmap VText ["raw-insert", "sql-function", "append-cte"])) (fmap VText ["raw-insert", "sql-function", "append-cte", "store-api"])

runLadder :: RunContext -> IO ScenarioReport
runLadder context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right measureConfig) -> do
    let name = either (error . show) id . mkKnobName
        knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
        writers = knob "kiroku.append.writers"
        payloadBytes = knob "kiroku.append.payload-bytes"
        rung = knobText context.knobs (name "kiroku.ladder.rung")
        configuredPool = knob "kiroku.ladder.pool-size"
        poolSize = if configuredPool > 0 then configuredPool else if rung == "raw-insert" || rung == "sql-function" then writers + 4 else 10
        configuredModel = case loadModel of ClosedLoop closed -> ClosedLoop (closed {workers = writers}); other -> other
        options = storeOptionsFromKnobs context "ladder"
        connection = (requirePostgres context).connectionString <> " application_name=" <> options.applicationName
        settings = ((defaultConnectionSettings connection) :: ConnectionSettings) {poolSize = poolSize, statementTimeout = options.statementTimeout, idleInTransactionTimeout = options.idleInTransactionTimeout}
        bytes = ByteString.replicate payloadBytes 97
    withStore settings \store -> do
      schema <- runStoreIO store (runTransaction (Tx.sql "create schema if not exists kenshou_kiroku; create table if not exists kenshou_kiroku.bench_raw_events (id bigserial primary key, data bytea not null, created_at timestamptz not null); create or replace function kenshou_kiroku.bench_hasql_append(payload bytea) returns bigint language plpgsql as $$ declare inserted_id bigint; begin insert into kenshou_kiroku.bench_raw_events (data, created_at) values (payload, now()) returning id into inserted_id; return inserted_id; end $$"))
      case schema of
        Left err -> pure (failedWith ["ladder-schema-failed"] (Text.pack (show err)))
        Right () -> do
          walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
          let operation worker sequenceNumber = do
                let streamName = "ladder-" <> Text.pack (show (worker `mod` writers))
                    event = EventData Nothing (EventType "Ladder") (payloadOf context.seed worker (fromIntegral sequenceNumber) payloadBytes) Nothing Nothing Nothing
                outcome <- case rung of
                  "raw-insert" -> Pool.use store.pool (Session.statement bytes rawInsertStatement) >>= pure . either (OpFailed . ErrorCause . Text.pack . show) (const (OpOk 1))
                  "sql-function" -> Pool.use store.pool (Session.statement bytes sqlFunctionStatement) >>= pure . either (OpFailed . ErrorCause . Text.pack . show) (const (OpOk 1))
                  "append-cte" -> do
                    prepared <- prepareEventsIO [event]
                    now <- getCurrentTime
                    let params = buildAppendParams streamName now prepared
                    result <- Pool.use store.pool (Session.statement params SQL.appendAnyVersion)
                    pure case result of Right (Just _) -> OpOk 1; Right Nothing -> OpFailed (ErrorCause "no-append-result"); Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                  _ -> do
                    result <- runStoreIO store (appendToStream (StreamName streamName) AnyVersion [event])
                    pure case result of Right _ -> OpOk 1; Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                pure outcome
          (_, report) <- withMeasurement context measureConfig (\measurement -> runLoad measurement configuredModel (Operation (OpName "append") operation))
          let completed = sum [load.completed | load <- report.loads]
              failed = sum [load.failed | load <- report.loads]
              base = if completed > 0 && failed == 0 then passed else failedWith ["ladder-errors-or-no-work"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed))
              walMethod = either (const Nothing) Just walSync
              reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
          putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= poolSize, "poolRule" .= (if configuredPool > 0 then ("explicit" :: Text) else "rung-default"), "writers" .= writers, "payloadBytes" .= payloadBytes, "rung" .= rung, "trialsRequired" .= (3 :: Int)])
          putSummary context Verdicts "layer-ladder" (object ["completed" .= completed, "failed" .= failed])
          pure (base {outcome = measuredOutcome report base.outcome})

rawInsertStatement :: Statement.Statement ByteString.ByteString ()
rawInsertStatement = Statement.preparable "insert into kenshou_kiroku.bench_raw_events (data, created_at) values ($1, now())" (Encoders.param (Encoders.nonNullable Encoders.bytea)) Decoders.noResult

sqlFunctionStatement :: Statement.Statement ByteString.ByteString Int64
sqlFunctionStatement = Statement.preparable "select kenshou_kiroku.bench_hasql_append($1)" (Encoders.param (Encoders.nonNullable Encoders.bytea)) (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
