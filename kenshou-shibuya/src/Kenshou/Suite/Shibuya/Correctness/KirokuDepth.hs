module Kenshou.Suite.Shibuya.Correctness.KirokuDepth (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (KirokuFixture (..), appendEvents, checkpointOf, eventPositions, subscriptionFor, withKirokuFixture)
import Shibuya.Adapter.Kiroku (SubscriptionName, SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/correctness/in-flight-depth-is-one"),
      revision = 1,
      summary = "Proves ack-coupled Kiroku delivery stays at depth one even with eight asynchronous Shibuya handlers.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runDepth
    }

runDepth :: RunContext -> IO ScenarioReport
runDepth context = do
  outcome <- try @SomeException $ timeout 30000000 $ withKirokuFixture context runFixture
  case outcome of
    Left err -> pure (failedWith ["kiroku-depth-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-depth-timeout"] "Kiroku adapter did not finish within 30 seconds")
    Right (Just (activeAtGate, deliveredAtGate, delivered, highWater, finalCheckpoint, finalPosition, drained)) -> do
      let failures =
            ["first-delivery-not-gated" | activeAtGate /= 1 || deliveredAtGate /= 1]
              <> ["in-flight-depth-exceeded-one" | highWater /= 1]
              <> ["delivery-count" | delivered /= 24]
              <> ["checkpoint-not-at-last-event" | finalCheckpoint /= Just finalPosition]
              <> ["adapter-did-not-drain" | not drained]
      putSummary context Verdicts "kiroku-in-flight-depth" $
        object
          [ "activeAtGate" .= activeAtGate,
            "deliveredAtGate" .= deliveredAtGate,
            "delivered" .= delivered,
            "handlerHighWater" .= highWater,
            "checkpoint" .= finalCheckpoint,
            "lastEventPosition" .= finalPosition,
            "drained" .= drained
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: KirokuFixture -> IO (Int, Int, Int, Int, Maybe Int64, Int64, Bool)
runFixture fixture = do
  appendEvents fixture 24
  positions <- eventPositions fixture
  finalPosition <- case reverse positions of
    position : _ | length positions == 24 -> pure position
    _ -> ioError (userError "fixture did not append 24 events")
  let subscription = subscriptionFor fixture "depth"
  delivered <- newIORef (0 :: Int)
  active <- newIORef (0 :: Int)
  highWater <- newIORef (0 :: Int)
  entered <- newEmptyMVar
  release <- newEmptyMVar
  (activeAtGate, deliveredAtGate, drained) <- runEff $ runTracingNoop $ do
    adapter <- kirokuAdapter fixture.store (defaultKirokuAdapterConfig subscription (Category fixture.category))
    let handler _ = do
          current <- liftIO $ atomicModifyIORef' active (\count -> (count + 1, count + 1))
          liftIO $ atomicModifyIORef' highWater (\value -> (max value current, ()))
          ordinal <- liftIO $ atomicModifyIORef' delivered (\count -> (count + 1, count + 1))
          when (ordinal == 1) $ liftIO (putMVar entered () >> takeMVar release)
          liftIO $ threadDelay 10000
          liftIO $ atomicModifyIORef' active (\count -> (count - 1, ()))
          pure AckOk
        processor = (mkProcessor adapter handler) {ordering = Unordered, concurrency = Async 8}
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-depth", processor)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ takeMVar entered
        liftIO $ threadDelay 150000
        gateActive <- liftIO $ readIORef active
        gateDelivered <- liftIO $ readIORef delivered
        liftIO $ putMVar release ()
        liftIO $ waitForCheckpoint fixture subscription finalPosition
        drained <- stopAppGracefully defaultShutdownConfig handle
        waitApp handle
        pure (gateActive, gateDelivered, drained)
  totalDelivered <- readIORef delivered
  peak <- readIORef highWater
  checkpoint <- checkpointOf fixture subscription 0
  pure (activeAtGate, deliveredAtGate, totalDelivered, peak, checkpoint, finalPosition, drained)

waitForCheckpoint :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForCheckpoint fixture subscription finalPosition = do
  checkpoint <- checkpointOf fixture subscription 0
  when (checkpoint /= Just finalPosition) $ threadDelay 10000 >> waitForCheckpoint fixture subscription finalPosition
