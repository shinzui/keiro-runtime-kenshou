module Kenshou.Suite.Shibuya.Concurrency.CoreRunner (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, mapConcurrently, waitCatch)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException, try)
import Control.Exception qualified as Exception
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
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
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerEvent (..), BrokerStats (..), FinalizerOutcome (..), ShutdownBehaviour (..), SyntheticConfig (..), brokerEvents, brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, reopenSource, syntheticAdapter)
import Kenshou.Suite.Shibuya.Knobs (coreKnobs, parseConcurrency, parseOrdering)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), QueueProcessor (..), ShutdownConfig (..), SupervisionStrategy (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopApp, stopAppGracefully, waitApp)
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
scenarios = [haltWakesIdleIntake, leasedButUnfinalizedUpperBound, haltStrandsLeases, finalizationFailure, adapterShutdownFailure, blockingAdapterShutdown, forcedShutdownConserves]

finalizationFailure :: Scenario
finalizationFailure =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/finalization-failure-is-a-failure-not-a-halt"),
      revision = 1,
      summary = "Transient finalizer faults preserve the decision, and an exhausted retry budget triggers supervision.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = knownOnReleasedCore (rev 4 "REV-4-F2"),
      run = runFinalizationFailure
    }

runFinalizationFailure :: RunContext -> IO ScenarioReport
runFinalizationFailure context = do
  transientArms <- mapM runTransientFinalizer [1 .. 3]
  (linkedFailure, siblingStopped, permanentAttempts, permanentFinalized) <- runPermanentFinalizer
  let transient = concatMap fst transientArms
      supervisionFailed = not linkedFailure || not siblingStopped
      failures =
        transient
          <> ["permanent-finalizer-attempts" | permanentAttempts /= 4]
          <> ["permanent-finalizer-was-effective" | permanentFinalized]
          <> ["REV-4-F2" | supervisionFailed]
  putSummary context Verdicts "finalization-failure" $
    object
      [ "transientFailures" .= transient,
        "transientRetryGapsSeconds" .= map snd transientArms,
        "permanentAttempts" .= permanentAttempts,
        "permanentFinalized" .= permanentFinalized,
        "linkedFailureDelivered" .= linkedFailure,
        "siblingStopped" .= siblingStopped
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runTransientFinalizer :: Int -> IO ([Text], [Double])
runTransientFinalizer faultCount = do
  broker <- newSyntheticBroker defaultSyntheticConfig {finalizerScript = \_ attempt -> if attempt <= faultCount then FinalizeThrows "transient finalizer fault" else FinalizeSucceeds}
  _ <- publish broker Nothing "transient"
  closeInput broker
  completed <- timeout 3000000 $ runEff $ runTracingNoop $ do
    started <- runApp defaultAppConfig [(ProcessorId "transient-finalizer", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case started of
      Left err -> error (show err)
      Right handle -> waitApp handle >> stopApp handle
  stats <- brokerStats broker
  events <- brokerEvents broker
  let attempts = [(number, decision, at) | FinalizeAttempt _ number decision at <- events]
      gaps = zipWith (\(_, _, earlier) (_, _, later) -> realToFrac (diffUTCTime later earlier) :: Double) attempts (drop 1 attempts)
      expectedGaps = take faultCount [0.01, 0.05, 0.25 :: Double]
      label = "transient-" <> Text.pack (show faultCount)
  pure
    ( [label <> "-timeout" | completed == Nothing]
        <> [label <> "-retry-count" | length attempts /= faultCount + 1]
        <> [label <> "-decision-changed" | any (\(_, decision, _) -> decision /= AckOk) attempts]
        <> [label <> "-retry-too-fast" | or (zipWith (\actual expected -> actual < expected - 0.001) gaps expectedGaps)]
        <> [label <> "-finalization-not-effective-once" | stats.finalizedOk /= 1 || stats.leasedUnfinalized /= 0 || length [() | Finalized _ _ AckOk <- events] /= 1],
      gaps
    )

runPermanentFinalizer :: IO (Bool, Bool, Int, Bool)
runPermanentFinalizer = do
  failing <- newSyntheticBroker defaultSyntheticConfig {finalizerScript = \_ _ -> FinalizeThrows "permanent finalizer fault"}
  sibling <- newSyntheticBroker defaultSyntheticConfig
  _ <- publish failing Nothing "permanent"
  closeInput failing
  worker <- async $ runEff $ runTracingNoop $ do
    let processors =
          [ (ProcessorId "permanent-finalizer", mkProcessor (syntheticAdapter failing) (\_ -> pure AckOk)),
            (ProcessorId "idle-sibling", mkProcessor (syntheticAdapter sibling) (\_ -> pure AckOk))
          ]
    started <- runApp defaultAppConfig {strategy = StopAllOnFailure} processors
    case started of
      Left err -> error (show err)
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
        liftIO $ Exception.finally (runInIO (waitApp handle)) (runInIO (stopApp handle))
  let awaitFourth = do
        events <- brokerEvents failing
        if length [() | FinalizeAttempt _ _ _ _ <- events] >= 4
          then pure ()
          else threadDelay 1000 >> awaitFourth
  _ <- timeout 2000000 awaitFourth
  result <- timeout 2000000 (waitCatch worker)
  before <- brokerStats sibling
  threadDelay 100000
  after <- brokerStats sibling
  case result of
    Nothing -> do
      _ <- timeout 3000000 (cancel worker)
      pure ()
    Just _ -> pure ()
  events <- brokerEvents failing
  let attempts = length [() | FinalizeAttempt _ _ _ _ <- events]
      effective = any (\case Finalized _ _ _ -> True; _ -> False) events
      linked = case result of
        Just (Left err) -> "ExceptionInLinkedThread" `Text.isInfixOf` Text.pack (show err)
        _ -> False
      stopped = before.idlePolls > 0 && before.idlePolls == after.idlePolls
  pure (linked, stopped, attempts, effective)

haltStrandsLeases :: Scenario
haltStrandsLeases =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/halt-strands-leased-messages"),
      revision = 1,
      summary = "A processor halt may strand bounded leases until expiry, but a replacement consumes the whole queue.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runHaltStrandsLeases
    }

runHaltStrandsLeases :: RunContext -> IO ScenarioReport
runHaltStrandsLeases context = do
  broker <- newSyntheticBroker defaultSyntheticConfig {leaseSeconds = Just 5}
  mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 1000 :: Int]
  closeInput broker
  handled <- newIORef (0 :: Int)
  observed <- timeout 20000000 $ runEff $ runTracingNoop $ do
    let haltOnTenth _ = do
          number <- liftIO $ atomicModifyIORef' handled (\old -> let new = old + 1 in (new, new))
          pure $ if number == 10 then AckHalt (HaltFatal "tenth delivery") else AckOk
    first <- runApp defaultAppConfig {inboxSize = 100} [(ProcessorId "halt-first", mkProcessor (syntheticAdapter broker) haltOnTenth)]
    case first of
      Left err -> error (show err)
      Right firstHandle -> do
        waitApp firstHandle
        atHalt <- liftIO $ brokerStats broker
        stopApp firstHandle
        liftIO $ reopenSource broker
        replacement <- runApp defaultAppConfig [(ProcessorId "halt-replacement", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
        case replacement of
          Left err -> error (show err)
          Right replacementHandle -> do
            waitApp replacementHandle
            stopApp replacementHandle
            afterRestart <- liftIO $ brokerStats broker
            pure (atHalt, afterRestart)
  case observed of
    Nothing -> pure $ failedWith ["halt-restart-timeout"] "halt or replacement did not finish within twenty seconds"
    Just (atHalt, afterRestart) -> do
      let bound = 100 + 3 * 1 + 2
          stranded = atHalt.leasedUnfinalized
          finalized = afterRestart.finalizedOk + afterRestart.halted
          failures =
            ["halt-not-on-tenth" | atHalt.finalizedOk /= 9 || atHalt.halted /= 1]
              <> ["stranded-bound-exceeded" | stranded > bound]
              <> ["halt-did-not-strand-leases" | stranded == 0]
              <> ["messages-lost-after-halt" | finalized /= 1000]
              <> ["leases-remain-after-halt-restart" | afterRestart.leasedUnfinalized /= 0]
      putSummary context Verdicts "halt-stranded-leases" $
        object
          [ "strandedAtHalt" .= stranded,
            "strandedBound" .= bound,
            "finalizedAfterRestart" .= finalized,
            "redeliveries" .= afterRestart.redeliveries
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

blockingAdapterShutdown :: Scenario
blockingAdapterShutdown =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/blocking-adapter-shutdown-is-bounded"),
      revision = 1,
      summary = "A permanently blocked adapter shutdown respects the application's total shutdown deadline.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = knownOnReleasedCore (rev 2 "REV-2-A1"),
      run = runBlockingAdapterShutdown
    }

runBlockingAdapterShutdown :: RunContext -> IO ScenarioReport
runBlockingAdapterShutdown context = do
  broker <- newSyntheticBroker defaultSyntheticConfig {shutdownBehaviour = ShutdownBlocksForever}
  startedAt <- getCurrentTime
  -- The common API has no total-deadline field on the historical release.
  -- Its default is 60 seconds on remediated cores, so allow five seconds of
  -- scheduling slack and keep a separate 70-second watchdog for the old core.
  observed <- timeout 70000000 $ runEff $ runTracingNoop $ do
    started <- runApp defaultAppConfig [(ProcessorId "blocking-shutdown", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
    case started of
      Left err -> error (show err)
      Right handle -> stopAppGracefully defaultShutdownConfig handle
  endedAt <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime endedAt startedAt) :: Double
  stats <- brokerStats broker
  let bounded = maybe False (const (elapsed <= (65 :: Double))) observed
      failures =
        ["REV-2-A1" | not bounded]
          <> ["blocked-shutdown-reported-clean-drain" | observed == Just True]
          <> ["shutdown-not-entered-once" | stats.shutdownCalls /= 1]
  putSummary context Verdicts "blocking-adapter-shutdown" $
    object
      [ "stopReturned" .= maybe False (const True) observed,
        "cleanDrain" .= observed,
        "elapsedSeconds" .= (elapsed :: Double),
        "shutdownCalls" .= stats.shutdownCalls,
        "deadlineSeconds" .= (65 :: Int)
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

forcedShutdownConserves :: Scenario
forcedShutdownConserves =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses"),
      revision = 1,
      summary = "A forced stop leaves leases for redelivery, and a replacement application eventually finalizes every message.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runForcedShutdown
    }

runForcedShutdown :: RunContext -> IO ScenarioReport
runForcedShutdown context = do
  broker <- newSyntheticBroker defaultSyntheticConfig {leaseSeconds = Just 3}
  mapM_ (\number -> publish broker Nothing (ByteString.pack ("message-" <> show number))) [1 .. 30 :: Int]
  closeInput broker
  gate <- newTVarIO False
  probe <- newHandlerProbe defaultHandlerScript {gate = Just gate}
  observed <- timeout 12000000 $ runEff $ runTracingNoop $ do
    let firstProcessor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {concurrency = Async 4}
    first <- runApp defaultAppConfig {inboxSize = 5} [(ProcessorId "forced-first", firstProcessor)]
    case first of
      Left err -> error (show err)
      Right firstHandle -> do
        -- Ensure cancellation interrupts active handlers rather than an idle app.
        liftIO $
          let awaitHandlers = do
                stats <- handlerStats probe
                if stats.started >= 4 then pure () else threadDelay 1000 >> awaitHandlers
           in awaitHandlers
        drained <- stopAppGracefully defaultShutdownConfig {drainTimeout = 1} firstHandle
        atStop <- liftIO $ brokerStats broker
        liftIO $ threadDelay 100000
        afterStop <- liftIO $ brokerStats broker
        liftIO $ atomically $ writeTVar gate True
        liftIO $ reopenSource broker
        second <- runApp defaultAppConfig [(ProcessorId "forced-replacement", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
        case second of
          Left err -> error (show err)
          Right secondHandle -> do
            waitApp secondHandle
            stopApp secondHandle
            finalStats <- liftIO $ brokerStats broker
            pure (drained, atStop, afterStop, finalStats)
  case observed of
    Nothing -> pure $ failedWith ["forced-stop-timeout"] "forced stop or replacement exceeded twelve seconds"
    Just (drained, atStop, afterStop, finalStats) -> do
      let failures =
            ["forced-stop-reported-clean-drain" | drained]
              <> ["finalized-after-stop" | atStop.finalizedOk /= afterStop.finalizedOk]
              <> ["messages-lost-after-restart" | finalStats.finalizedOk /= 30]
              <> ["leases-remain-after-restart" | finalStats.leasedUnfinalized /= 0]
      putSummary context Verdicts "forced-shutdown-conservation" $
        object
          [ "cleanDrain" .= drained,
            "finalizedAtStop" .= atStop.finalizedOk,
            "finalizedAfterStop" .= afterStop.finalizedOk,
            "finalizedAfterRestart" .= finalStats.finalizedOk,
            "redeliveries" .= finalStats.redeliveries
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

adapterShutdownFailure :: Scenario
adapterShutdownFailure =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings"),
      revision = 1,
      summary = "A throwing adapter shutdown still shuts down sibling adapters and reports the exception to every stopper.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = knownOnReleasedCore (rev 3 "sibling-shutdown-skipped"),
      run = runAdapterShutdownFailure
    }

runAdapterShutdownFailure :: RunContext -> IO ScenarioReport
runAdapterShutdownFailure context = do
  failing <- newSyntheticBroker defaultSyntheticConfig {shutdownBehaviour = ShutdownThrows "scripted shutdown fault"}
  siblingA <- newSyntheticBroker defaultSyntheticConfig
  siblingB <- newSyntheticBroker defaultSyntheticConfig
  let brokers = [failing, siblingA, siblingB]
  result <- timeout 5000000 $ runEff $ runTracingNoop $ do
    let processors =
          zipWith
            (\number broker -> (ProcessorId ("shutdown-" <> Text.pack (show number)), mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk)))
            [1 :: Int ..]
            brokers
    started <- runApp defaultAppConfig processors
    case started of
      Left err -> error (show err)
      Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $ do
        answers <- mapConcurrently (\_ -> try @SomeException (runInIO (stopAppGracefully defaultShutdownConfig handle))) [1 .. 8 :: Int]
        before <- mapM brokerStats brokers
        threadDelay 1000000
        after <- mapM brokerStats brokers
        pure (answers, before, after)
  case result of
    Nothing -> pure $ failedWith ["shutdown-timeout"] "concurrent shutdown calls exceeded five seconds"
    Just (answers, before, after) -> do
      let thrown = length [() | Left err <- answers, "scripted shutdown fault" `Text.isInfixOf` Text.pack (show err)]
          calls = map (.shutdownCalls) after
          stablePulls = and $ zipWith (\x y -> x.sourcePulls == y.sourcePulls) before after
          failures =
            ["shutdown-exception-not-broadcast" | thrown /= 8]
              <> ["sibling-shutdown-skipped" | any (< 1) calls]
              <> ["source-kept-pulling" | not stablePulls]
      putSummary context Verdicts "adapter-shutdown-failure" $
        object ["exceptionCallers" .= thrown, "shutdownCalls" .= calls, "sourcePullsStopped" .= stablePulls]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

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
