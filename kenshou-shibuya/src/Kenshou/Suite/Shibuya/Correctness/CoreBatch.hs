module Kenshou.Suite.Shibuya.Correctness.CoreBatch (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerEvent (..), BrokerStats (..), SyntheticBroker, brokerEvents, brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (QueueProcessor (..), defaultAppConfig, mkBatchProcessor, runApp, stopApp, waitApp)
import Shibuya.Batch (BatchAck, BatchConfig (..), BatchHandler, BatchInfo (..), BatchKey (..), BatchTrigger (..), ackAllOk, defaultBatchConfig, withFallback)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [conservationTriggersDecisions]

conservationTriggersDecisions :: Scenario
conservationTriggersDecisions =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-batch/correctness/conservation-triggers-and-decisions"),
      revision = 1,
      summary = "Size, timeout and flush triggers conserve deliveries while fallback, exceptions and keyed concurrency preserve acknowledgements.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runConservation
    }

data BatchFact = BatchFact
  { info :: !BatchInfo,
    ids :: ![MessageId],
    startedAt :: !UTCTime
  }

runConservation :: RunContext -> IO ScenarioReport
runConservation context = do
  sizeFailures <- runSizeArm
  timeoutFailures <- runTimeoutArm
  flushFailures <- runFlushArm
  fallbackFailures <- runFallbackArm
  exceptionFailures <- runExceptionArm
  keyedFailures <- runKeyedArm
  let arms =
        [ ("size", sizeFailures),
          ("timeout", timeoutFailures),
          ("flush", flushFailures),
          ("fallback", fallbackFailures),
          ("exception", exceptionFailures),
          ("keyed", keyedFailures)
        ]
      failures = concatMap snd arms
  putSummary context Verdicts "batch-conservation" $
    object ["arms" .= object ["size" .= sizeFailures, "timeout" .= timeoutFailures, "flush" .= flushFailures, "fallback" .= fallbackFailures, "exception" .= exceptionFailures, "keyed" .= keyedFailures]]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

recordingHandler :: (IOE :> es) => IORef [BatchFact] -> BatchInfo -> NonEmpty (Message es ByteString.ByteString) -> Eff es BatchAck
recordingHandler facts info messages = do
  startedAt <- liftIO getCurrentTime
  liftIO $ modifyIORef' facts (BatchFact info (map (\message -> message.envelope.messageId) (toList messages)) startedAt :)
  pure ackAllOk

runSizeArm :: IO [Text]
runSizeArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  ids <- mapM (\number -> publish broker Nothing (ByteString.pack (show number))) [1 .. 10 :: Int]
  closeInput broker
  facts <- newIORef []
  completed <- runFinite broker defaultBatchConfig {batchSize = 5, batchTimeout = 10} (recordingHandler facts)
  recorded <- reverse <$> readIORef facts
  stats <- brokerStats broker
  events <- brokerEvents broker
  pure $
    ["size-arm-timeout" | not completed]
      <> ["size-trigger-or-shape" | length recorded /= 2 || any (\fact -> fact.info.trigger /= TriggerSize || fact.info.size /= 5) recorded]
      <> ["size-order" | concatMap (.ids) recorded /= ids]
      <> conservationFailures "size" 10 stats events

runTimeoutArm :: IO [Text]
runTimeoutArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  _ <- mapM (\number -> publish broker Nothing (ByteString.pack (show number))) [1 .. 3 :: Int]
  facts <- newIORef []
  startedAt <- getCurrentTime
  completed <- timeout 2000000 $ runEff $ runTracingNoop $ do
    let config = defaultBatchConfig {batchSize = 10, batchTimeout = 0.05, tickInterval = Just 0.01}
    started <- runApp defaultAppConfig [(ProcessorId "timeout-batch", mkBatchProcessor (syntheticAdapter broker) (recordingHandler facts) config)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ awaitFinalized broker 3
        liftIO $ closeInput broker
        waitApp handle
        stopApp handle
  recorded <- reverse <$> readIORef facts
  stats <- brokerStats broker
  events <- brokerEvents broker
  let withinDeadline = case recorded of
        [fact] -> realToFrac (diffUTCTime fact.startedAt startedAt) <= (0.16 :: Double)
        _ -> False
  pure $
    ["timeout-arm-timeout" | completed == Nothing]
      <> ["timeout-trigger-or-shape" | length recorded /= 1 || any (\fact -> fact.info.trigger /= TriggerTimeout || fact.info.size /= 3) recorded]
      <> ["timeout-emission-late" | not withinDeadline]
      <> conservationFailures "timeout" 3 stats events

runFlushArm :: IO [Text]
runFlushArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  ids <- mapM (\number -> publish broker Nothing (ByteString.pack (show number))) [1 .. 3 :: Int]
  closeInput broker
  facts <- newIORef []
  completed <- timeout 3000000 $ runEff $ runTracingNoop $ do
    let adapter = syntheticAdapter broker
        config = defaultBatchConfig {batchSize = 10, batchTimeout = 10}
    started <- runApp defaultAppConfig [(ProcessorId "flush-batch", mkBatchProcessor adapter (recordingHandler facts) config)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ awaitYields broker 3
        adapter.shutdown
        waitApp handle
        stopApp handle
  recorded <- reverse <$> readIORef facts
  stats <- brokerStats broker
  events <- brokerEvents broker
  pure $
    ["flush-arm-timeout" | completed == Nothing]
      <> ["flush-trigger-or-shape" | length recorded /= 1 || any (\fact -> fact.info.trigger /= TriggerFlush || fact.info.size /= 3) recorded]
      <> ["flush-order" | concatMap (.ids) recorded /= ids]
      <> conservationFailures "flush" 3 stats events

runFallbackArm :: IO [Text]
runFallbackArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  ids <- mapM (\number -> publish broker Nothing (ByteString.pack (show number))) [1 .. 3 :: Int]
  closeInput broker
  let handler _ _ = pure $ withFallback (AckDeadLetter (PoisonPill "fallback")) [(head ids, AckOk)]
  completed <- runFinite broker defaultBatchConfig {batchSize = 3} handler
  stats <- brokerStats broker
  events <- brokerEvents broker
  let actual = [(identifier, decision) | Finalized identifier _ decision <- events]
      expected = (head ids, AckOk) : [(identifier, AckDeadLetter (PoisonPill "fallback")) | identifier <- tail ids]
  pure $
    ["fallback-arm-timeout" | not completed]
      <> ["fallback-decisions" | actual /= expected || stats.finalizedOk /= 1 || stats.deadLettered /= 2]
      <> ["fallback-duplicate-finalization" | any (\case DuplicateFinalize _ _ -> True; _ -> False) events]

runExceptionArm :: IO [Text]
runExceptionArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  _ <- mapM (\number -> publish broker Nothing (ByteString.pack (show number))) [1 .. 3 :: Int]
  closeInput broker
  calls <- newIORef (0 :: Int)
  let handler _ _ = do
        number <- liftIO $ atomicModifyIORef' calls (\old -> let new = old + 1 in (new, new))
        if number == 1 then liftIO $ throwIO (userError "scripted batch fault") else pure ackAllOk
  completed <- runFinite broker defaultBatchConfig {batchSize = 3} handler
  stats <- brokerStats broker
  events <- brokerEvents broker
  pure $
    ["exception-arm-timeout" | not completed]
      <> ["exception-did-not-retry-all" | stats.retried /= 3 || stats.redeliveries /= 3 || stats.finalizedOk /= 3]
      <> ["exception-duplicate-finalization" | any (\case DuplicateFinalize _ _ -> True; _ -> False) events]

data KeyedFact = KeyedFact !BatchKey ![MessageId] !UTCTime !UTCTime

runKeyedArm :: IO [Text]
runKeyedArm = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  published <- mapM (\number -> let key = if odd number then "a" else "b" in (key,) <$> publish broker (Just key) (ByteString.pack (show number))) [1 .. 16 :: Int]
  closeInput broker
  facts <- newIORef []
  let config = defaultBatchConfig {batchSize = 2, batchTimeout = 10, batchKey = \envelope -> BatchKey (maybe "missing" id envelope.partition)}
      handler info messages = do
        startedAt <- liftIO getCurrentTime
        liftIO $ threadDelay 10000
        endedAt <- liftIO getCurrentTime
        liftIO $ modifyIORef' facts (KeyedFact info.batchKey (map (\message -> message.envelope.messageId) (toList messages)) startedAt endedAt :)
        pure ackAllOk
  completed <- timeout 3000000 $ runEff $ runTracingNoop $ do
    let processor = (mkBatchProcessor (syntheticAdapter broker) handler config) {concurrency = Async 4}
    started <- runApp defaultAppConfig [(ProcessorId "keyed-batch", processor)]
    case started of
      Left err -> error (show err)
      Right handle -> waitApp handle >> stopApp handle
  recorded <- reverse <$> readIORef facts
  stats <- brokerStats broker
  events <- brokerEvents broker
  let forKey key = sortOn (\(KeyedFact _ _ start _) -> start) [fact | fact@(KeyedFact factKey _ _ _) <- recorded, factKey == BatchKey key]
      observedIds key = concat [ids | KeyedFact _ ids _ _ <- forKey key]
      expectedIds key = [identifier | (actualKey, identifier) <- published, actualKey == key]
      nonoverlap key = and $ zipWith (\(KeyedFact _ _ _ ended) (KeyedFact _ _ started _) -> ended <= started) (forKey key) (drop 1 (forKey key))
  pure $
    ["keyed-arm-timeout" | completed == Nothing]
      <> ["keyed-batch-order" | any (\key -> observedIds key /= expectedIds key) ["a", "b"]]
      <> ["keyed-batch-overlap" | any (not . nonoverlap) ["a", "b"]]
      <> ["keyed-batch-count" | length recorded /= 8]
      <> conservationFailures "keyed" 16 stats events

runFinite :: SyntheticBroker -> BatchConfig '[Tracing, IOE] ByteString.ByteString -> BatchHandler '[Tracing, IOE] ByteString.ByteString -> IO Bool
runFinite broker config handler = do
  completed <- timeout 3000000 $ runEff $ runTracingNoop $ do
    started <- runApp defaultAppConfig [(ProcessorId "batch-arm", mkBatchProcessor (syntheticAdapter broker) handler config)]
    case started of
      Left err -> error (show err)
      Right handle -> waitApp handle >> stopApp handle
  pure (completed /= Nothing)

awaitFinalized :: SyntheticBroker -> Int -> IO ()
awaitFinalized broker count = do
  stats <- brokerStats broker
  if stats.finalizedOk >= count then pure () else threadDelay 1000 >> awaitFinalized broker count

awaitYields :: SyntheticBroker -> Int -> IO ()
awaitYields broker count = do
  stats <- brokerStats broker
  if stats.yielded >= count then pure () else threadDelay 1000 >> awaitYields broker count

conservationFailures :: Text -> Int -> BrokerStats -> [BrokerEvent] -> [Text]
conservationFailures arm count stats events =
  let effective = length [() | Finalized _ _ _ <- events]
   in [arm <> "-conservation" | stats.finalizedOk /= count || stats.leasedUnfinalized /= 0 || effective /= count]
        <> [arm <> "-duplicate-finalization" | any (\case DuplicateFinalize _ _ -> True; _ -> False) events]
