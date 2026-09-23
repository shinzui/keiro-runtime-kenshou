module Kenshou.Suite.Shibuya.Concurrency.CoreRunner (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, writeTVar)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, runEff, withEffToIO, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName, renderKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Cohort (knownOnReleasedCore, rev)
import Kenshou.Suite.Shibuya.Fixture.Handlers (HandlerScript (..), HandlerStats (..), defaultHandlerScript, handlerStats, newHandlerProbe, scriptedHandler)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerStats (..), brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Kenshou.Suite.Shibuya.Knobs (coreKnobs, parseConcurrency, parseOrdering)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Policy (Concurrency (..), OrderingPolicy)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [haltWakesIdleIntake, leasedButUnfinalizedUpperBound]

leasedButUnfinalizedUpperBound :: Scenario
leasedButUnfinalizedUpperBound =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/leased-but-unfinalized-upper-bound"),
      revision = 1,
      summary = "Bounds outstanding leases while every handler waits on a gate.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runLeasedBound
    }

runLeasedBound :: RunContext -> IO ScenarioReport
runLeasedBound context = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 1000 :: Int]
  closeInput broker
  gate <- newTVarIO False
  probe <- newHandlerProbe defaultHandlerScript {gate = Just gate}
  observed <- timeout 10000000 $ runEff $ runTracingNoop $ do
    let processor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {concurrency = Async 4}
    result <- runApp defaultAppConfig {inboxSize = 100} [(ProcessorId "leased-bound", processor)]
    case result of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ threadDelay 1000000
        brokerAtGate <- liftIO $ brokerStats broker
        handlersAtGate <- liftIO $ handlerStats probe
        liftIO $ atomically $ writeTVar gate True
        waitApp handle
        stopApp handle
        finalStats <- liftIO $ brokerStats broker
        pure (brokerAtGate, handlersAtGate, finalStats)
  case observed of
    Nothing -> pure $ failedWith ["bound-timeout"] "application did not finish after opening the handler gate"
    Just (atGate, handlers, finalStats) -> do
      let bound = 100 + 3 * 4 + 2
          failures =
            ["bound-exceeded" | atGate.leasedUnfinalizedHighWater > bound]
              <> ["gate-not-saturated" | handlers.highWater < 4]
              <> ["messages-not-conserved" | finalStats.finalizedOk /= 1000 || finalStats.leasedUnfinalized /= 0]
      putSummary context Verdicts "leased-but-unfinalized-upper-bound" $
        object
          [ "leasedUnfinalizedHighWater" .= atGate.leasedUnfinalizedHighWater,
            "bound" .= bound,
            "handlerHighWater" .= handlers.highWater,
            "finalized" .= finalStats.finalizedOk
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

haltWakesIdleIntake :: Scenario
haltWakesIdleIntake =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/halt-wakes-idle-intake"),
      revision = 1,
      summary = "A halt decision wakes an idle source and lets waitApp finish within the deadline.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = filter (\spec -> renderKnobName spec.name `elem` ["shibuya.concurrency", "shibuya.ordering"]) coreKnobs <> [deadlineSpec],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = knownOnReleasedCore (rev 4 "REV-4-F1"),
      run = runHalt
    }

deadlineSpec :: KnobSpec
deadlineSpec = KnobSpec (knobName "shibuya.halt-deadline-ms") "Deadline for waitApp after AckHalt, in milliseconds" KnobInt (VInt 2000) (IntRange 100 30000) []

knobName :: Text -> KnobName
knobName raw = either (error . Text.unpack) id (mkKnobName raw)

runHalt :: RunContext -> IO ScenarioReport
runHalt context = do
  let concurrencyText = knobText context.knobs (knobName "shibuya.concurrency")
      orderingText = knobText context.knobs (knobName "shibuya.ordering")
      deadline = fromIntegral (knobInt context.knobs (knobName "shibuya.halt-deadline-ms")) * 1000
  case (parseConcurrency concurrencyText, parseOrdering orderingText) of
    (Right concurrency, Right ordering) -> do
      (waited, idleReached, acknowledged, stopped) <- exerciseHalt concurrency ordering deadline
      putSummary context Verdicts "halt-wakes-idle-intake" $
        object
          [ "concurrency" .= concurrencyText,
            "ordering" .= orderingText,
            "waitAppCompleted" .= waited,
            "idleSourceReached" .= idleReached,
            "finalized" .= acknowledged,
            "cleanupCompleted" .= stopped
          ]
      let failures =
            ["REV-4-F1" | not waited]
              <> ["fixture-idle-not-reached" | concurrency /= Serial && not idleReached]
              <> ["finalize-missing" | acknowledged /= 1]
              <> ["cleanup-timeout" | not stopped]
      pure $ if null failures then passed else failedWith failures ("waitApp completed=" <> Text.pack (show waited) <> "; idle reached=" <> Text.pack (show idleReached) <> "; finalized=" <> Text.pack (show acknowledged) <> "; cleanup completed=" <> Text.pack (show stopped))
    (Left err, _) -> pure $ failedWith ["invalid-concurrency"] err
    (_, Left err) -> pure $ failedWith ["invalid-ordering"] err

exerciseHalt :: Concurrency -> OrderingPolicy -> Int -> IO (Bool, Bool, Int, Bool)
exerciseHalt concurrency ordering deadline = do
  closed <- newTVarIO False
  idleEntered <- newTVarIO False
  acknowledgements <- newIORef (0 :: Int)
  runEff $ runTracingNoop $ do
    let adapter = oneThenIdle closed idleEntered acknowledgements
        handler _ = do
          case concurrency of
            Serial -> pure ()
            _ -> liftIO $ do
              atomically $ readTVar idleEntered >>= check
              threadDelay 100000
          pure (AckHalt (HaltFatal "kenshou"))
        processor = (mkProcessor adapter handler) {concurrency, ordering}
    result <- runApp defaultAppConfig [(ProcessorId "halt-probe", processor)]
    case result of
      Left _ -> pure (False, False, 0, False)
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
        waited <- liftIO $ timeout deadline (runInIO (waitApp handle))
        stopped <- liftIO $ timeout 3000000 (runInIO (stopApp handle))
        count <- liftIO $ readIORef acknowledgements
        idleReached <- liftIO $ atomically $ readTVar idleEntered
        pure (maybe False (const True) waited, idleReached, count, maybe False (const True) stopped)

oneThenIdle :: (IOE :> es) => TVar Bool -> TVar Bool -> IORef Int -> Adapter es Text
oneThenIdle closed idleEntered acknowledgements =
  Adapter
    { adapterName = "kenshou:halt-probe",
      source = Stream.unfoldrM step False,
      shutdown = liftIO $ atomically $ writeTVar closed True
    }
  where
    step False = do
      let delivery = mkIngested (mkEnvelope (MessageId "halt-probe-message") ("probe" :: Text)) (AckHandle (\_ -> liftIO $ modifyIORef' acknowledgements (+ 1)))
      pure (Just (delivery, True))
    step True = do
      liftIO $ atomically $ writeTVar idleEntered True
      liftIO $ atomically $ readTVar closed >>= check
      pure Nothing
