module Kenshou.Suite.Shibuya.Correctness.CoreRunner (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, liftIO, runEff)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (KnownDefect (..), Placement (..), Scenario (..), Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Cohort (knownOnReleasedCore, rev)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerStats (..), brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), QueueProcessor (..), defaultAppConfig, mkBatchProcessor, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Batch (BatchConfig (..), BatchHandler, ackAll, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ coreScenario
      "shibuya/core-runner/correctness/every-delivery-is-finalized-exactly-once"
      "Conserves a finite source and finalizes each delivery once with a bounded inbox."
      Nothing
      everyDeliveryFinalized,
    coreScenario
      "shibuya/core-runner/correctness/invalid-config-rejected-before-effects"
      "Rejects invalid inbox and ordering policies before pulling a source or shutting down an adapter."
      Nothing
      invalidConfiguration,
    coreScenario
      "shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected"
      "Rejects duplicate processor identities before either source is pulled."
      (knownOnReleasedCore (rev 3 "REV-3-F2"))
      duplicateProcessorIds,
    coreScenario
      "shibuya/core-runner/correctness/nonpositive-concurrency-is-rejected"
      "Rejects zero and negative concurrency bounds or runs at most one handler."
      (knownOnReleasedCore (rev 6 "REV-6-F1"))
      nonpositiveConcurrency
  ]

coreScenario :: Text -> Text -> Maybe KnownDefect -> IO [Text] -> Scenario
coreScenario identifier description defect action =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId identifier),
      revision = 1,
      summary = description,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = defect,
      run = \_ -> do
        failures <- action
        pure $ if null failures then passed else failedWith (maybe failures (.expectedFailures) defect) (Text.intercalate "; " failures)
    }

invalidConfiguration :: IO [Text]
invalidConfiguration = do
  inbox <- checkRejected "inbox-size-zero" $ \adapter ->
    (defaultAppConfig {inboxSize = 0}, [(ProcessorId "invalid-inbox", mkProcessor adapter alwaysAckOk)])
  strictAsync <- checkRejected "strict-async" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-policy", (mkProcessor adapter alwaysAckOk) {ordering = StrictInOrder, concurrency = Async 2})])
  partitionedBatch <- checkRejected "partitioned-batch" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-batch-policy", (mkBatchProcessor adapter alwaysBatchAck defaultBatchConfig) {ordering = PartitionedInOrder, concurrency = Ahead 2})])
  batchSize <- checkRejected "batch-size-zero" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-batch-size", mkBatchProcessor adapter alwaysBatchAck defaultBatchConfig {batchSize = 0})])
  batchTimeout <- checkRejected "batch-timeout-zero" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-batch-timeout", mkBatchProcessor adapter alwaysBatchAck defaultBatchConfig {batchTimeout = 0})])
  batchTick <- checkRejected "batch-tick-zero" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-batch-tick", mkBatchProcessor adapter alwaysBatchAck defaultBatchConfig {tickInterval = Just 0})])
  pure (inbox <> strictAsync <> partitionedBatch <> batchSize <> batchTimeout <> batchTick)

duplicateProcessorIds :: IO [Text]
duplicateProcessorIds =
  checkRejected "duplicate-processor-id" $ \adapter ->
    ( defaultAppConfig,
      [ (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk),
        (ProcessorId "duplicate", mkBatchProcessor adapter alwaysBatchAck defaultBatchConfig)
      ]
    )

everyDeliveryFinalized :: IO [Text]
everyDeliveryFinalized = do
  results <- mapM runArm [(Serial, 1, 0), (Async 4, 1, 10), (Ahead 4, 4, 0)]
  pure (concat results)
  where
    runArm (mode, inbox, failuresToInject) = do
      broker <- newSyntheticBroker defaultSyntheticConfig
      mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 100 :: Int]
      closeInput broker
      remaining <- newIORef failuresToInject
      completed <- timeout 5000000 $ runEff $ runTracingNoop $ do
        let handler _ = do
              shouldThrow <- liftIO $ atomicModifyIORef' remaining (\count -> if count > 0 then (count - 1, True) else (0, False))
              if shouldThrow then liftIO (throwIO (userError "scripted handler fault")) else pure AckOk
            processor = (mkProcessor (syntheticAdapter broker) handler) {concurrency = mode}
        result <- runApp defaultAppConfig {inboxSize = inbox} [(ProcessorId "conservation", processor)]
        case result of
          Left err -> error (show err)
          Right handle -> waitApp handle >> stopApp handle
      stats <- brokerStats broker
      let label = Text.pack (show mode) <> "/inbox=" <> Text.pack (show inbox)
      pure $
        [label <> ": waitApp timed out" | completed == Nothing]
          <> [label <> ": delivery count differs from publication and retries" | stats.yielded /= 100 + failuresToInject]
          <> [label <> ": effective finalization count differs from publication" | stats.finalizedOk /= 100]
          <> [label <> ": handler faults did not become retries" | stats.retried /= failuresToInject || stats.redeliveries /= failuresToInject]
          <> [label <> ": outstanding leases remain" | stats.leasedUnfinalized /= 0]

nonpositiveConcurrency :: IO [Text]
nonpositiveConcurrency = concat <$> mapM runArm [Async 0, Async (-1), Ahead 0]
  where
    runArm mode = do
      broker <- newSyntheticBroker defaultSyntheticConfig
      mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 40 :: Int]
      closeInput broker
      running <- newIORef (0 :: Int)
      highWater <- newIORef (0 :: Int)
      rejected <- timeout 15000000 $ runEff $ runTracingNoop $ do
        let handler _ = do
              active <- liftIO $ atomicModifyIORef' running (\old -> let new = old + 1 in (new, new))
              liftIO $ modifyIORef' highWater (max active)
              liftIO $ threadDelay 200000
              liftIO $ modifyIORef' running (subtract 1)
              pure AckOk
            processor = (mkProcessor (syntheticAdapter broker) handler) {concurrency = mode}
        result <- runApp defaultAppConfig [(ProcessorId "nonpositive", processor)]
        case result of
          Left _ -> pure True
          Right handle -> waitApp handle >> stopApp handle >> pure False
      stats <- brokerStats broker
      peak <- readIORef highWater
      let label = Text.pack (show mode)
      pure $
        [label <> ": application timed out" | rejected == Nothing]
          <> [label <> ": rejected policy pulled the source" | rejected == Just True && stats.sourcePulls /= 0]
          <> [label <> ": accepted policy ran concurrent handlers" | rejected == Just False && peak > 1]
          <> [label <> ": accepted policy did not complete all messages" | rejected == Just False && stats.finalizedOk /= 40]

-- A rejected configuration must not touch the adapter, even on a failing cohort.
checkRejected :: Text -> (Adapter '[Tracing, IOE] Text -> (AppConfig, [(ProcessorId, QueueProcessor '[Tracing, IOE])])) -> IO [Text]
checkRejected label configure = do
  pulls <- newIORef (0 :: Int)
  shutdowns <- newIORef (0 :: Int)
  rejected <- runEff $ runTracingNoop $ do
    let delivery = mkIngested (mkEnvelope (MessageId "configuration-probe") ("probe" :: Text)) (AckHandle (\_ -> pure ()))
        adapter =
          Adapter
            { adapterName = "kenshou:configuration-probe",
              source = Stream.mapM (\message -> liftIO (modifyIORef' pulls (+ 1)) >> pure message) (Stream.fromList [delivery]),
              shutdown = liftIO (modifyIORef' shutdowns (+ 1))
            }
        (config, processors) = configure adapter
    result <- runApp config processors
    case result of
      Left _ -> pure True
      Right handle -> stopApp handle >> pure False
  pulled <- readIORef pulls
  stopped <- readIORef shutdowns
  pure $
    [label <> ": runApp accepted invalid configuration" | not rejected]
      <> [label <> ": source was pulled before validation" | pulled /= 0]
      <> [label <> ": shutdown ran before validation" | stopped /= 0 && rejected]

alwaysAckOk :: Handler es Text
alwaysAckOk _ = pure AckOk

alwaysBatchAck :: BatchHandler es Text
alwaysBatchAck _ _ = pure (ackAll AckOk)
