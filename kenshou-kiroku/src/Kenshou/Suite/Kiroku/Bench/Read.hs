module Kenshou.Suite.Kiroku.Bench.Read (scenarios) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import Streamly.Data.Stream qualified as Stream
import System.Info (os)

scenarios :: [Scenario]
scenarios = [readTargets]

readTargets :: Scenario
readTargets =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/read/benchmark/read-targets"),
      revision = 1,
      summary = "Measures paged reads by target and direction after prepopulation.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 8}) <> measureKnobs Benchmark <> [intKnob "kiroku.read.prepopulate" 100000 100 1000000, intKnob "kiroku.read.page-size" 256 1 1000, intKnob "kiroku.read.category-cardinality" 8 1 64, intKnob "kiroku.read.stream-count" 16 1 128, intKnob "kiroku.read.readers" 8 1 64, choice "kiroku.read.target" "single" ["all", "category"], choice "kiroku.read.api" "paged" ["streamly"], choice "kiroku.read.direction" "forward" ["backward"]],
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
      run = runReadTargets
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    choice key value others = KnobSpec (name key) key KnobText (VText value) (OneOf (VText value :| fmap VText others)) (fmap VText (value : others))

runReadTargets :: RunContext -> IO ScenarioReport
runReadTargets context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right measureConfig) -> withKirokuStore context \store -> do
    let name = either (error . show) id . mkKnobName
        knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
        prepopulate = knob "kiroku.read.prepopulate"
        pageSize = knob "kiroku.read.page-size"
        cardinality = knob "kiroku.read.category-cardinality"
        streamCount = knob "kiroku.read.stream-count"
        readers = knob "kiroku.read.readers"
        target = knobText context.knobs (name "kiroku.read.target")
        api = knobText context.knobs (name "kiroku.read.api")
        direction = knobText context.knobs (name "kiroku.read.direction")
        streamName index = StreamName ("read" <> Text.pack (show (index `mod` cardinality)) <> "-s" <> Text.pack (show index))
        event = EventData Nothing (EventType "BenchRead") (object []) Nothing Nothing Nothing
        configuredModel = case loadModel of ClosedLoop closed -> ClosedLoop (closed {workers = readers}); other -> other
        streamEvents index = prepopulate `div` streamCount + if index < prepopulate `mod` streamCount then 1 else 0
        readOperation worker sequenceNumber = do
          let streamIndex = worker `mod` streamCount
              stream = streamName streamIndex
              streamSize = streamEvents streamIndex
              globalCursor = fromIntegral ((sequenceNumber * fromIntegral pageSize) `mod` fromIntegral (max 1 (prepopulate - pageSize)))
              streamCursor = fromIntegral ((sequenceNumber * fromIntegral pageSize) `mod` fromIntegral (max 1 (streamSize - pageSize)))
              forwardGlobal = GlobalPosition globalCursor
              backwardGlobal = if globalCursor == 0 then GlobalPosition 0 else GlobalPosition (globalCursor + 1)
              forwardStream = StreamVersion streamCursor
              backwardStream = if streamCursor == 0 then StreamVersion 0 else StreamVersion (streamCursor + 1)
              page = fromIntegral pageSize
              action = case (api, target, direction) of
                ("streamly", "single", "forward") -> Just (fmap (fmap length) (runStoreIO store (Stream.toList (Stream.take pageSize (readStreamForwardStream stream forwardStream page)))))
                (_, "single", "forward") -> Just (fmap (fmap Vector.length) (runStoreIO store (readStreamForward stream forwardStream page)))
                (_, "single", "backward") -> Just (fmap (fmap Vector.length) (runStoreIO store (readStreamBackward stream backwardStream page)))
                (_, "all", "forward") -> Just (fmap (fmap Vector.length) (runStoreIO store (readAllForward forwardGlobal page)))
                (_, "all", "backward") -> Just (fmap (fmap Vector.length) (runStoreIO store (readAllBackward backwardGlobal page)))
                (_, "category", "forward") -> Just (fmap (fmap Vector.length) (runStoreIO store (readCategory (CategoryName ("read" <> Text.pack (show (worker `mod` cardinality)))) forwardGlobal page)))
                _ -> Nothing
          case action of
            Nothing -> pure (OpFailed (ErrorCause "unsupported-read-combination"))
            Just readPage -> do
              result <- readPage
              pure case result of Right count -> OpOk count; Left err -> OpFailed (ErrorCause (Text.pack (show err)))
    if streamCount > prepopulate || cardinality > streamCount
      then pure (failedWith ["invalid-read-shape"] "Prepopulation must cover every stream and category")
      else
        if (api == "streamly" && (target /= "single" || direction /= "forward")) || (target == "category" && direction == "backward")
          then pure (failedWith ["unsupported-read-combination"] "The released store has Streamly only for single-stream forward reads and no backward category read")
          else do
            forM_ [0 .. streamCount - 1] \index -> do
              let total = streamEvents index
                  batches = [min 1000 (total - offset) | offset <- [0, 1000 .. total - 1]]
              forM_ (zip [0 :: Int ..] batches) \(batchIndex, count) -> do
                let expected = if batchIndex == 0 then NoStream else AnyVersion
                result <- runStoreIO store (appendToStream (streamName index) expected (replicate count event))
                case result of Right _ -> pure (); Left err -> fail ("read prepopulation failed: " <> show err)
            walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
            (_, report) <- withMeasurement context measureConfig (\measurement -> runLoad measurement configuredModel (Operation (OpName "read") readOperation))
            let completed = sum [load.completed | load <- report.loads]
                failed = sum [load.failed | load <- report.loads]
                base = if completed > 0 && failed == 0 then passed else failedWith ["read-errors-or-no-work"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed))
                walMethod = either (const Nothing) Just walSync
                reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
            putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "readers" .= readers, "target" .= target, "api" .= api, "direction" .= direction, "pageSize" .= pageSize, "prepopulate" .= prepopulate, "streamCount" .= streamCount, "categoryCardinality" .= cardinality, "trialsRequired" .= (3 :: Int)])
            putSummary context Verdicts "read-targets" (object ["completed" .= completed, "failed" .= failed])
            pure (base {outcome = measuredOutcome report base.outcome})

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
