module Kenshou.Suite.Kiroku.Bench.Subscription (scenarios) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Aeson (object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set (Set)
import Data.Set qualified as Set
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
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Info (os)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [catchUp]

catchUp :: Scenario
catchUp =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/benchmark/catch-up"),
      revision = 1,
      summary = "Times cold subscriptions from start through CaughtUp after prepopulation.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> loadKnobs (defaultLoadDefaults {workers = 1}) <> measureKnobs Benchmark <> [intKnob "workload.prepopulate" 100000 100 1000000, intKnob "kiroku.subscription.batch-size" 100 1 1000, intKnob "kiroku.consumer-group.size" 0 0 8, choice "kiroku.subscription.target" "all" ["category"]],
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
      run = runCatchUp
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    choice key value others = KnobSpec (name key) key KnobText (VText value) (OneOf (VText value :| fmap VText others)) (fmap VText (value : others))

runCatchUp :: RunContext -> IO ScenarioReport
runCatchUp context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right (ClosedLoop closed), Right measureConfig) -> do
    active <- newIORef Nothing :: IO (IORef (Maybe (SubscriptionName, IORef (Set Int), MVar ())))
    nextName <- newIORef (0 :: Int)
    let name = either (error . show) id . mkKnobName
        knob key = fromIntegral (knobInt context.knobs (name key)) :: Int
        prepopulate = knob "workload.prepopulate"
        batch = knob "kiroku.subscription.batch-size"
        groupSize = knob "kiroku.consumer-group.size"
        targetName = knobText context.knobs (name "kiroku.subscription.target")
        target = if targetName == "category" then Category (CategoryName "catchup") else AllStreams
        members = if groupSize == 0 then [Nothing] else [Just member | member <- [0 .. groupSize - 1]]
        tap event = case event of
          KirokuEventSubscriptionCaughtUp subscription _ group ->
            readIORef active >>= \case
              Just (expected, seen, done) | subscription == expected -> do
                let member = case group of NonGroup -> -1; GroupMember index _ -> fromIntegral index
                count <- atomicModifyIORef' seen (\current -> let next = Set.insert member current in (next, Set.size next))
                if count >= length members then void (tryPutMVar done ()) else pure ()
              _ -> pure ()
          _ -> pure ()
    withKirokuStoreWithTap context (Just tap) \store -> do
      let stream = StreamName "catchup-bench"
          event = EventData Nothing (EventType "CatchUp") (object []) Nothing Nothing Nothing
          batches = [min 1000 (prepopulate - offset) | offset <- [0, 1000 .. prepopulate - 1]]
      forM_ (zip [0 :: Int ..] batches) \(index, count) -> do
        result <- runStoreIO store (appendToStream stream (if index == 0 then NoStream else AnyVersion) (replicate count event))
        case result of Right _ -> pure (); Left err -> fail ("catch-up prepopulation failed: " <> show err)
      walSync <- Pool.use store.pool (Session.statement () walSyncMethodStatement)
      (_, report) <- withMeasurement context measureConfig \measurement -> do
        let operation _ _ = do
              ordinal <- atomicModifyIORef' nextName (\current -> (current + 1, current))
              let subscription = SubscriptionName ("catchup-bench-" <> Text.pack (show ordinal))
              done <- newEmptyMVar
              seen <- newIORef Set.empty
              delivered <- newIORef (0 :: Int)
              writeIORef active (Just (subscription, seen, done))
              let handler _ = atomicModifyIORef' delivered (\count -> (count + 1, ())) >> pure Continue
                  config member = (defaultSubscriptionConfig subscription target handler) {batchSize = fromIntegral batch, consumerGroup = fmap (\index -> ConsumerGroup (fromIntegral index) (fromIntegral groupSize)) member}
                  withMembers [] action = action
                  withMembers (member : rest) action = withSubscription store (config member) (\_ -> withMembers rest action)
              caughtUp <- try @SomeException (withMembers members (timeout 60000000 (takeMVar done)))
              writeIORef active Nothing
              count <- readIORef delivered
              pure case caughtUp of
                Right (Just ()) | count == prepopulate -> OpOk count
                Right (Just ()) -> OpFailed (ErrorCause ("catch-up-count=" <> Text.pack (show count)))
                Right Nothing -> OpFailed (ErrorCause "caught-up-timeout")
                Left err -> OpFailed (ErrorCause (Text.pack (show err)))
        runLoad measurement (ClosedLoop (closed {workers = 1})) (Operation (OpName "catch-up") operation)
      let completed = sum [load.completed | load <- report.loads]
          failed = sum [load.failed | load <- report.loads]
          base = if completed > 0 && failed == 0 then passed else failedWith ["catch-up-errors-or-no-work"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed))
          walMethod = either (const Nothing) Just walSync
          reasons = (["local-placement" | context.environmentSpec.placement /= RunOnCell] <> ["wal-sync-method-unavailable" | walMethod == Nothing] <> ["macos-fsync-does-not-flush" | os == "darwin" && walMethod /= Just "fsync_writethrough"]) :: [Text]
      putSummary context Measurements "methodology" (object ["authoritative" .= null reasons, "reasons" .= reasons, "walSyncMethod" .= walMethod, "poolSize" .= (storeOptionsFromKnobs context "scenario").poolSize, "prepopulate" .= prepopulate, "batchSize" .= batch, "target" .= targetName, "groupSize" .= groupSize, "trialsRequired" .= (3 :: Int)])
      putSummary context Verdicts "catch-up" (object ["completed" .= completed, "failed" .= failed])
      pure (if failed > 0 then base else base {outcome = measuredOutcome report base.outcome})
  (Right _, Right _) -> pure (failedWith ["unsupported-load-mode"] "catch-up repeats one cold subscription at a time and requires closed-loop load")

walSyncMethodStatement :: Statement.Statement () Text
walSyncMethodStatement = Statement.preparable "show wal_sync_method" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
