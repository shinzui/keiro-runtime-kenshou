module Kenshou.Suite.Kiroku.Bench.Transaction (scenarios) where

import Control.Monad (replicateM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobDouble, knobInt, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..), newWorkerRecorder, recordDuration, registerOp)
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, measurementRecorder, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStore)
import Kenshou.Suite.Kiroku.Fixture.Workload (payloadOf)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Info (os)

scenarios :: [Scenario]
scenarios = [lockHoldContention]

lockHoldContention :: Scenario
lockHoldContention =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/transaction/benchmark/lock-hold-contention"),
      revision = 1,
      summary = "Measures plain-append tail latency while transaction continuations hold the global lock.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 32}) <> measureKnobs Benchmark <> [KnobSpec (name "kiroku.tx.fraction") "Fraction of transactional appends" KnobDouble (VDouble 0.2) (DoubleRange 0 1) [VDouble 0.2], intKnob "kiroku.tx.continuation-statements" 1 0 20, intKnob "kiroku.append.writers" 32 1 128, intKnob "kiroku.append.payload-bytes" 256 64 65536],
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
      run = runLockHold
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []

runLockHold :: RunContext -> IO ScenarioReport
runLockHold context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right measureConfig) -> withKirokuStore context \store -> do
    let name = either (error . show) id . mkKnobName
        knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
        writers = knob "kiroku.append.writers"
        payloadBytes = knob "kiroku.append.payload-bytes"
        statements = knob "kiroku.tx.continuation-statements"
        fraction = knobDouble context.knobs (name "kiroku.tx.fraction")
        configuredModel = case loadModel of ClosedLoop closed -> ClosedLoop (closed {workers = writers}); other -> other
        makeEvent worker sequenceNumber = EventData Nothing (EventType "BenchTransaction") (payloadOf context.seed worker sequenceNumber payloadBytes) Nothing Nothing Nothing
        isTransaction sequenceNumber = fromIntegral (sequenceNumber `mod` 1000) < fraction * 1000
    schema <- runStoreIO store (runTransaction (Tx.sql "create schema if not exists kenshou_kiroku; create table if not exists kenshou_kiroku.tx_bench_probe (value int not null)"))
    case schema of
      Left err -> pure (failedWith ["probe-schema-failed"] (Text.pack (show err)))
      Right () -> do
        walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
        (_, report) <- withMeasurement context measureConfig \measurement -> do
          plainHandle <- registerOp (measurementRecorder measurement) (OpName "plain-append")
          transactionHandle <- registerOp (measurementRecorder measurement) (OpName "transaction-append")
          plainWorkers <- traverse (newWorkerRecorder plainHandle) [0 .. writers - 1]
          transactionWorkers <- traverse (newWorkerRecorder transactionHandle) [0 .. writers - 1]
          let operation worker sequenceNumber = do
                let slot = worker `mod` writers
                    stream = StreamName ("tx-bench-" <> Text.pack (show slot))
                    event = makeEvent slot (fromIntegral sequenceNumber)
                    transactional = isTransaction sequenceNumber
                started <- getMonotonicTimeNSec
                result <-
                  if transactional
                    then runStoreIO store (runTransactionAppending stream AnyVersion [event] (\_ -> replicateM_ statements (Tx.sql "insert into kenshou_kiroku.tx_bench_probe (value) values (1)")))
                    else fmap (fmap (Right . const ())) (runStoreIO store (appendToStream stream AnyVersion [event]))
                ended <- getMonotonicTimeNSec
                let outcome = case result of Right (Right _) -> OpOk 1; Right (Left err) -> OpFailed (ErrorCause (Text.pack (show err))); Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                    recorder = if transactional then transactionWorkers !! slot else plainWorkers !! slot
                recordDuration recorder ended (ended - started) outcome
                pure outcome
          runLoad measurement configuredModel (Operation (OpName "append-attempt") operation)
        let completed = sum [load.completed | load <- report.loads]
            failed = sum [load.failed | load <- report.loads]
            base = if completed > 0 && failed == 0 then passed else failedWith ["append-errors-or-no-work"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed))
            walMethod = either (const Nothing) Just walSync
            reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
        putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "writers" .= writers, "payloadBytes" .= payloadBytes, "transactionFraction" .= fraction, "continuationStatements" .= statements, "trialsRequired" .= (3 :: Int)])
        putSummary context Verdicts "lock-hold-contention" (object ["completed" .= completed, "failed" .= failed])
        pure (base {outcome = measuredOutcome report base.outcome})

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
