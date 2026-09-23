module Kenshou.Suite.Kiroku.Bench.Append (scenarios) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStore)
import Kenshou.Suite.Kiroku.Fixture.Workload (payloadOf)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Info (os)

scenarios :: [Scenario]
scenarios = [appendOnly]

appendOnly :: Scenario
appendOnly =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/benchmark/append-only"),
      revision = 1,
      summary = "Measures closed or open loop append throughput with one stream per writer.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 32}) <> measureKnobs Benchmark <> [intKnob "kiroku.append.writers" 32 1 128, intKnob "kiroku.append.batch-size" 1 1 100, intKnob "kiroku.append.payload-bytes" 256 64 65536],
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
      run = runAppendOnly
    }

runAppendOnly :: RunContext -> IO ScenarioReport
runAppendOnly context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right measureConfig) -> withKirokuStore context \store -> do
    let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
        writers = knob "kiroku.append.writers"
        batchSize = knob "kiroku.append.batch-size"
        payloadBytes = knob "kiroku.append.payload-bytes"
        configuredModel = case loadModel of
          ClosedLoop closed -> ClosedLoop (closed {workers = writers})
          other -> other
        append worker sequenceNumber = do
          let stream = StreamName ("bench-" <> Text.pack (show (worker `mod` writers)))
              events = [EventData Nothing (EventType "Bench") (payloadOf context.seed worker (fromIntegral sequenceNumber * fromIntegral batchSize + fromIntegral ordinal) payloadBytes) Nothing Nothing Nothing | ordinal <- [0 .. batchSize - 1]]
          result <- runStoreIO store (appendToStream stream AnyVersion events)
          pure case result of
            Right _ -> OpOk batchSize
            Left err -> OpFailed (ErrorCause (Text.pack (show err)))
        operation = Operation (OpName "append") append
    walSyncMethod <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
    (_, report) <- withMeasurement context measureConfig (\measurement -> runLoad measurement configuredModel operation)
    let failures = sum [load.failed | load <- report.loads]
        completions = sum [load.completed | load <- report.loads]
        base = if failures == 0 && completions > 0 then passed else failedWith ["append-errors-or-no-work"] ("failed=" <> Text.pack (show failures) <> ", completed=" <> Text.pack (show completions))
        cell = context.environmentSpec.placement == RunOnCell
        walMethod = either (const Nothing) Just walSyncMethod
        reasons = (["local-placement" | not cell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
        methodology = object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "writers" .= writers, "batchSize" .= batchSize, "payloadBytes" .= payloadBytes, "trialsRequired" .= (3 :: Int)]
    putSummary context Measurements "methodology" methodology
    putSummary context Verdicts "append-only" (object ["completed" .= completions, "failed" .= failures])
    pure (base {outcome = measuredOutcome report base.outcome})

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (either (error . show) id (mkKnobName key)) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []
