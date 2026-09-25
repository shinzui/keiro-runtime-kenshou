module SyntheticSpec (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (newTVarIO, readTVar)
import Control.Exception (SomeException, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine)
import Kenshou.Suite.Shibuya.Concurrency.CoreRunner (startupCancellationFailures)
import Kenshou.Suite.Shibuya.Fixture.Handlers
import Kenshou.Suite.Shibuya.Fixture.RestartLoop (RestartPolicy (..), runWithRestartLoop)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "synthetic broker" $ do
  it "stops source polling after startup cancellation and rapid stop cycles" $ do
    (failures, attempted, _, baseline, finalThreads) <- startupCancellationFailures 4 8
    attempted `shouldSatisfy` (> 0)
    case coreLine of
      CoreReleased0903 -> failures `shouldSatisfy` all (`elem` ["startup-cancel-timeout", "startup-worker-not-terminated", "startup-source-still-active", "startup-thread-count-growth"])
      CoreLifecycleRemediated -> do
        failures `shouldBe` []
        finalThreads `shouldSatisfy` (<= baseline + 8)

  it "redelivers a retry with an incremented attempt and conserves the message" $ do
    broker <- newSyntheticBroker defaultSyntheticConfig
    _ <- publish broker Nothing "payload"
    closeInput broker
    deliveries <- newIORef (0 :: Int)
    completed <- timeout 2000000 $ runEff $ runTracingNoop $ do
      let handler _ = do
            count <- liftIO $ atomicModifyIORef' deliveries (\old -> let new = old + 1 in (new, new))
            pure $ if count == 1 then AckRetry (RetryDelay 0) else AckOk
      result <- runApp defaultAppConfig [(ProcessorId "retry", mkProcessor (syntheticAdapter broker) handler)]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    completed `shouldBe` Just ()
    readIORef deliveries `shouldReturn` 2
    stats <- brokerStats broker
    stats.published `shouldBe` 1
    stats.yielded `shouldBe` 2
    stats.retried `shouldBe` 1
    stats.redeliveries `shouldBe` 1
    stats.finalizedOk `shouldBe` 1
    stats.leasedUnfinalized `shouldBe` 0

  it "redelivers an expired lease and rejects its stale finalization" $ do
    let config = defaultSyntheticConfig {leaseSeconds = Just 0.02}
    broker <- newSyntheticBroker config
    _ <- publish broker (Just "partition") "payload"
    closeInput broker
    deliveries <- newIORef (0 :: Int)
    completed <- timeout 2000000 $ runEff $ runTracingNoop $ do
      let handler _ = do
            count <- liftIO $ atomicModifyIORef' deliveries (\old -> let new = old + 1 in (new, new))
            liftIO $ if count == 1 then threadDelay 100000 else pure ()
            pure AckOk
      result <- runApp defaultAppConfig [(ProcessorId "lease", mkProcessor (syntheticAdapter broker) handler)]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    completed `shouldBe` Just ()
    deliveryCount <- readIORef deliveries
    deliveryCount `shouldSatisfy` (>= 2)
    stats <- brokerStats broker
    stats.redeliveries `shouldBe` deliveryCount - 1
    stats.leasedUnfinalized `shouldBe` 0
    events <- brokerEvents broker
    length [() | LeaseExpired _ _ <- events] `shouldBe` stats.redeliveries
    length [() | DuplicateFinalize _ _ <- events] `shouldSatisfy` (>= 1)

  it "runs a scripted finalizer fault on the correct attempt" $ do
    let config = defaultSyntheticConfig {finalizerScript = \_ attempt -> if attempt == 1 then FinalizeThrows ("transient" :: Text) else FinalizeSucceeds}
    broker <- newSyntheticBroker config
    _ <- publish broker Nothing "payload"
    closeInput broker
    completed <- timeout 2000000 $ runEff $ runTracingNoop $ do
      result <- runApp defaultAppConfig [(ProcessorId "finalizer", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    completed `shouldBe` Just ()
    events <- brokerEvents broker
    length [() | FinalizeAttempt _ _ _ _ <- events] `shouldBe` 2
    stats <- brokerStats broker
    stats.finalizedOk `shouldBe` 1

  it "makes throwing and blocking shutdowns observable" $ do
    throwing <- newSyntheticBroker defaultSyntheticConfig {shutdownBehaviour = ShutdownThrows "shutdown fault"}
    thrown <- try @SomeException $ runEff $ (syntheticAdapter throwing).shutdown
    case thrown of
      Left _ -> pure ()
      Right () -> expectationFailure "shutdown fault was swallowed"
    throwStats <- brokerStats throwing
    throwStats.shutdownCalls `shouldBe` 1

    blocking <- newSyntheticBroker defaultSyntheticConfig {shutdownBehaviour = ShutdownBlocksForever}
    blocked <- timeout 50000 $ runEff $ (syntheticAdapter blocking).shutdown
    blocked `shouldBe` Nothing
    blockStats <- brokerStats blocking
    blockStats.shutdownCalls `shouldBe` 1

  it "lets a replacement adapter resume after a one-shot source fault" $ do
    broker <- newSyntheticBroker defaultSyntheticConfig {sourceFault = Just (1, "source fault")}
    _ <- publish broker Nothing "first"
    _ <- publish broker Nothing "second"
    closeInput broker
    first <- timeout 2000000 $ runEff $ runTracingNoop $ do
      result <- runApp defaultAppConfig [(ProcessorId "first", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    first `shouldBe` Just ()
    firstStats <- brokerStats broker
    firstStats.finalizedOk `shouldBe` 1
    reopenSource broker
    second <- timeout 2000000 $ runEff $ runTracingNoop $ do
      result <- runApp defaultAppConfig [(ProcessorId "second", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    second `shouldBe` Just ()
    finalStats <- brokerStats broker
    finalStats.finalizedOk `shouldBe` 2

  it "restarts an ended application according to the restart policy" $ do
    broker <- newSyntheticBroker defaultSyntheticConfig {sourceFault = Just (1, "source fault")}
    _ <- publish broker Nothing "first"
    _ <- publish broker Nothing "second"
    closeInput broker
    stopRequested <- newTVarIO False
    let policy = RestartPolicy 0 0 (Just 1)
    restarts <-
      timeout 2000000 $
        runEff $
          runTracingNoop $
            runWithRestartLoop
              policy
              (readTVar stopRequested)
              ( \number -> do
                  liftIO $ if number > 0 then reopenSource broker else pure ()
                  pure [(ProcessorId "restartable", mkProcessor (syntheticAdapter broker) (\_ -> pure AckOk))]
              )
              defaultAppConfig
    restarts `shouldBe` Just 1
    stats <- brokerStats broker
    stats.finalizedOk `shouldBe` 2
    stats.shutdownCalls `shouldBe` 2

  it "records handler intervals and concurrent high-water mark" $ do
    broker <- newSyntheticBroker defaultSyntheticConfig
    mapM_ (\_ -> publish broker Nothing "payload") [1 .. 8 :: Int]
    closeInput broker
    probe <- newHandlerProbe defaultHandlerScript {delayFor = \_ _ -> 50000}
    completed <- timeout 2000000 $ runEff $ runTracingNoop $ do
      let processor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {concurrency = Async 4}
      result <- runApp defaultAppConfig [(ProcessorId "tracked", processor)]
      case result of
        Left err -> error (show err)
        Right app -> waitApp app >> stopApp app
    completed `shouldBe` Just ()
    stats <- handlerStats probe
    stats.started `shouldBe` 8
    stats.ended `shouldBe` 8
    stats.active `shouldBe` 0
    stats.highWater `shouldBe` 4
    events <- handlerEvents probe
    length events `shouldBe` 16

  it "closes a handler interval when the handler is cancelled" $ do
    gate <- newTVarIO False
    probe <- newHandlerProbe defaultHandlerScript {gate = Just gate}
    thread <- forkIO $ do
      _ <- try @SomeException $ runEff $ scriptedHandler probe (Message (mkEnvelope (MessageId "cancelled") ()) Nothing)
      pure ()
    let awaitStart = do
          stats <- handlerStats probe
          if stats.started == 1 then pure () else threadDelay 1000 >> awaitStart
    started <- timeout 1000000 awaitStart
    started `shouldBe` Just ()
    killThread thread
    let awaitEnd = do
          stats <- handlerStats probe
          if stats.ended == 1 then pure stats else threadDelay 1000 >> awaitEnd
    final <- timeout 1000000 awaitEnd
    fmap (.active) final `shouldBe` Just 0
