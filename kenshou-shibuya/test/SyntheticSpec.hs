module SyntheticSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "synthetic broker" $ do
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
    length [() | FinalizeAttempt _ _ _ <- events] `shouldBe` 2
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
