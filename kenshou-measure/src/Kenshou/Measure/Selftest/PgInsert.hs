module Kenshou.Measure.Selftest.PgInsert (pgInsertScenario) where

import Control.Exception (bracket)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Word (Word64)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (Benchmark), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as Core
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs
import Kenshou.Measure.Load
import Kenshou.Measure.Recorder
import Kenshou.Measure.Sampler.Postgres
import Kenshou.Measure.Session
import System.Directory (doesFileExist)
import System.FilePath ((</>))

pgInsertScenario :: Scenario
pgInsertScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/measure/benchmark/pg-insert"),
      revision = 1,
      summary = "Verifies runtime, process, host, and PostgreSQL measurement series.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = loadKnobs (defaultLoadDefaults {model = "closed", workers = 8}) <> measureKnobs Benchmark <> [payloadKnob],
      dimensions = postgresDimensions (PgDurable :| []) (Pg17 :| [Pg18]) telemetryOff,
      phases = Core.PhasePlan 3 15 2,
      requires = pgRequirements,
      knownDefect = Nothing,
      run = runPgInsert
    }

runPgInsert :: RunContext -> IO ScenarioReport
runPgInsert context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left message, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, Left message) -> pure (failedWith ["invalid-measure-config"] message)
  (Right loadModel, Right baseConfig) -> do
    let environment = requirePostgres context
        workers = case loadModel of ClosedLoop closed -> closed.workers; OpenLoop open -> open.executors
        payloadBytes = knobInt context.knobs (name "pg-insert.payload-bytes")
        settings = Settings.connectionString environment.connectionString <> Settings.applicationName "kenshou-selftest-writer"
        config = watchInserts baseConfig
    acquired <- acquireMany workers settings
    case acquired of
      Left message -> pure (infrastructureFailureBecause message)
      Right [] -> pure (infrastructureFailureBecause "load.workers produced no PostgreSQL connections")
      Right connections@(firstConnection : _) -> bracket (pure connections) (mapM_ Connection.release) \openConnections -> do
        setup <- Connection.use firstConnection setupSession
        case setup of
          Left err -> pure (infrastructureFailureBecause (Text.pack (show err)))
          Right () -> do
            let operation = Operation (OpName "insert") (insertOne openConnections payloadBytes)
            (_, report) <- withMeasurement context config (\measurement -> runLoad measurement loadModel operation)
            counted <- Connection.use firstConnection (Session.statement () countRows)
            assess context report counted

insertOne :: [Connection.Connection] -> Int64 -> Int -> Word64 -> IO OpResult
insertOne connections payloadBytes worker sequenceNumber = do
  let connection = connections !! (worker `mod` length connections)
      parameter = Text.intercalate "," [Text.pack (show worker), Text.pack (show sequenceNumber), Text.pack (show payloadBytes)]
  result <- Connection.use connection (Session.statement parameter insertRow)
  pure (either (const (OpFailed (ErrorCause "postgres"))) (const (OpOk 1)) result)

assess :: RunContext -> MeasurementReport -> Either error Int64 -> IO ScenarioReport
assess context report counted = do
  seriesOk <- and <$> traverse hasRows expectedSeries
  let successful = case report.recorder.operations of
        operation : _ -> sum [successes | (successes, _, _) <- Map.elems operation.phaseCounts]
        [] -> 0
      rowCount = either (const Nothing) (Just . fromIntegral) counted
      failures = ["row-count" | rowCount /= Just successful] <> ["series-rows" | not seriesOk]
  pure (if null failures then passed else failedWith failures ("row count=" <> showText rowCount <> ", recorded successes=" <> showText successful))
  where
    expectedSeries = ["sampler.csv", "rts.csv", "proc.csv", "load.csv", "pg-activity.csv", "pg-checkpointer.csv", "pg-wal.csv", "pg-database.csv", "pg-relations.csv", "pg-statements.csv"]
    hasRows file = do
      let path = context.outDir </> "series" </> file
      exists <- doesFileExist path
      if not exists then pure False else (> 2) . length . Text.lines <$> Text.readFile path

acquireMany :: Int -> Settings.Settings -> IO (Either Text [Connection.Connection])
acquireMany count settings = go count []
  where
    go 0 acquired = pure (Right (reverse acquired))
    go remaining acquired = do
      result <- Connection.acquire settings
      case result of
        Left err -> mapM_ Connection.release acquired >> pure (Left (Text.pack (show err)))
        Right connection -> go (remaining - 1) (connection : acquired)

setupSession :: Session.Session ()
setupSession = do
  Session.statement () (unitStatement "CREATE SCHEMA IF NOT EXISTS kenshou_selftest")
  Session.statement () (unitStatement "CREATE TABLE IF NOT EXISTS kenshou_selftest.inserts (id bigserial PRIMARY KEY, worker int NOT NULL, seq bigint NOT NULL, payload bytea NOT NULL)")
  Session.statement () (unitStatement "TRUNCATE kenshou_selftest.inserts")

unitStatement :: Text -> Statement.Statement () ()
unitStatement sql = Statement.unpreparable sql Encoders.noParams Decoders.noResult

insertRow :: Statement.Statement Text ()
insertRow =
  Statement.unpreparable
    "INSERT INTO kenshou_selftest.inserts(worker,seq,payload) VALUES (split_part($1,',',1)::int, split_part($1,',',2)::bigint, decode(repeat('00',split_part($1,',',3)::int),'hex'))"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

countRows :: Statement.Statement () Int64
countRows = Statement.unpreparable "SELECT count(*)::bigint FROM kenshou_selftest.inserts" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

payloadKnob :: KnobSpec
payloadKnob = KnobSpec (name "pg-insert.payload-bytes") "Inserted payload size" KnobInt (VInt 256) (IntRange 1 65_536) []

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable

pgRequirements :: EnvRequirements
pgRequirements = EnvRequirements (Just (PostgresRequirement [] [("shared_preload_libraries", "'pg_stat_statements'")] False)) [] False

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

showText :: (Show value) => value -> Text
showText = Text.pack . show

watchInserts :: MeasureConfig -> MeasureConfig
watchInserts (MeasureConfig phases histogram rawSamples sampleInterval intervalSeconds postgres extraSamplers) =
  MeasureConfig phases histogram rawSamples sampleInterval intervalSeconds (fmap addRelation postgres) extraSamplers
  where
    addRelation :: PgSamplerConfig -> PgSamplerConfig
    addRelation pg = pg {relations = ["kenshou_selftest.inserts"]}
