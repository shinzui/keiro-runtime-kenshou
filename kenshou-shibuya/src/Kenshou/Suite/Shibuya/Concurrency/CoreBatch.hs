module Kenshou.Suite.Shibuya.Concurrency.CoreBatch (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar)
import Data.Aeson (Value, object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerStats (..), brokerStats, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Shibuya.App (ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkBatchProcessor, runApp, stopAppGracefully)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchTrigger (..), ackAllOk, defaultBatchConfig)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [shutdownWithPartialBatches]

shutdownWithPartialBatches :: Scenario
shutdownWithPartialBatches =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-batch/concurrency/shutdown-with-partial-batches"),
      revision = 1,
      summary = "A graceful stop flushes partial batches; a forced stop cannot finalize after returning.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runPartialBatchShutdown
    }

runPartialBatchShutdown :: RunContext -> IO ScenarioReport
runPartialBatchShutdown context = do
  graceful <- runArm False
  forced <- runArm True
  let failures =
        case (graceful, forced) of
          (Just (drained, _, atStop, afterStop, triggers), Just (forcedDrain, _, forcedAtStop, forcedAfterStop, forcedTriggers)) ->
            ["partial-batch-not-flushed" | not drained || atStop.finalizedOk /= 10 || TriggerFlush `notElem` triggers]
              <> ["graceful-late-finalization" | atStop.finalizedOk /= afterStop.finalizedOk]
              <> ["forced-stop-reported-drained" | forcedDrain]
              <> ["forced-stop-finalized-late" | forcedAtStop.finalizedOk /= forcedAfterStop.finalizedOk]
              <> ["forced-arm-never-flushed" | TriggerFlush `notElem` forcedTriggers]
          _ -> ["batch-stop-timeout"]
  putSummary context Verdicts "partial-batch-shutdown" $
    object
      [ "graceful" .= summarizeArm graceful,
        "forced" .= summarizeArm forced
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

summarizeArm :: Maybe (Bool, Bool, BrokerStats, BrokerStats, [BatchTrigger]) -> Maybe Value
summarizeArm = fmap $ \(drained, repeated, atStop, afterStop, triggers) ->
  object
    [ "cleanDrain" .= drained,
      "secondStopCleanDrain" .= repeated,
      "finalizedAtStop" .= atStop.finalizedOk,
      "finalizedAfterSecondStop" .= afterStop.finalizedOk,
      "triggers" .= map (Text.pack . show) triggers
    ]

runArm :: Bool -> IO (Maybe (Bool, Bool, BrokerStats, BrokerStats, [BatchTrigger]))
runArm force = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 10 :: Int]
  triggers <- newIORef []
  gate <- newTVarIO (not force)
  let batchConfig = defaultBatchConfig {batchSize = 100, batchTimeout = 10, tickInterval = Just 10}
      handler info _ = do
        liftIO $ modifyIORef' triggers (info.trigger :)
        liftIO $ atomically $ readTVar gate >>= check
        pure ackAllOk
      awaitYields = do
        stats <- brokerStats broker
        if stats.yielded >= 10 then pure () else threadDelay 1000 >> awaitYields
  timeout 8000000 $ runEff $ runTracingNoop $ do
    started <- runApp defaultAppConfig [(ProcessorId "partial-batch", mkBatchProcessor (syntheticAdapter broker) handler batchConfig)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO awaitYields
        let shutdownConfig = defaultShutdownConfig {drainTimeout = if force then 0.02 else 3}
        drained <- stopAppGracefully shutdownConfig handle
        atStop <- liftIO $ brokerStats broker
        liftIO $ threadDelay 100000
        repeated <- stopAppGracefully shutdownConfig handle
        liftIO $ threadDelay 100000
        afterStop <- liftIO $ brokerStats broker
        seen <- liftIO $ reverse <$> readIORef triggers
        pure (drained, repeated, atStop, afterStop, seen)
