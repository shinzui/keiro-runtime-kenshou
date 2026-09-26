module Kenshou.Suite.Shibuya.Concurrency.KirokuGroupAcquisition (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM, when)
import Data.Aeson (object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, liftIO, runEff, (:>))
import GHC.Conc (listThreads)
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, renderRunId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kiroku.Store (RecordedEvent, defaultConnectionSettings, withStore)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (ConsumerGroup (..), KirokuAdapterConfig (..), KirokuConsumerGroupConfig, SubscriptionName (..), SubscriptionTarget (..), defaultConsumerGroupConfig, defaultKirokuAdapterConfig, kirokuAdapter, kirokuConsumerGroupProcessorsWith)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/group-acquisition-failure-strands-nothing"),
      revision = 1,
      summary = "Checks partial eight-member acquisition, cleanup failures, 200 cancellation boundaries, and real subscription workers.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect =
        Just
          KnownDefect
            { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-13",
              summary = "REV-13-F1: group acquisition can leave earlier members open when a later cleanup throws",
              expectedFailures = ["group-acquisition-release-skipped", "group-acquisition-primary-replaced", "group-acquisition-thread-growth", "group-acquisition-real-thread-growth", "group-acquisition-real-primary-replaced", "group-acquisition-backend-thread-growth", "group-acquisition-backend-primary-replaced"],
              appliesTo = OnlyWhen (VersionBelow "shibuya-kiroku-adapter" "0.5.1.3" :| [])
            },
      run = runAcquisition
    }

data ArmEvidence = ArmEvidence
  { acquired :: ![Int32],
    released :: ![Int32],
    exceptionText :: !Text
  }

data RealEvidence = RealEvidence
  { baselineThreads :: !Int,
    finalThreads :: !Int,
    baselineBackends :: !Int,
    finalBackends :: !Int,
    exceptionText :: !Text,
    backendVictims :: !Int
  }

runAcquisition :: RunContext -> IO ScenarioReport
runAcquisition context = do
  outcome <- try @SomeException $ timeout 120000000 $ do
    performMajorGC
    baseline <- length <$> listThreads
    failure <- failureArm
    cancellation <- forM [0 .. 199] cancellationArm
    real <- realArm context False
    backend <- realArm context True
    threadDelay 1000000
    performMajorGC
    finalThreads <- length <$> listThreads
    pure (baseline, failure, cancellation, real, backend, finalThreads)
  case outcome of
    Left err -> pure (failedWith ["group-acquisition-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["group-acquisition-timeout"] "Group acquisition check exceeded 120 seconds")
    Right (Just (baseline, failure, cancellation, real, backend, finalThreads)) -> do
      let cancellationsWithLeaks = length [() | arm <- cancellation, arm.released /= reverse arm.acquired]
          cancellationsWithoutException = length [() | arm <- cancellation, not ("cancel" `Text.isInfixOf` Text.toCaseFold arm.exceptionText)]
          failures =
            ["group-acquisition-release-skipped" | failure.released /= reverse failure.acquired]
              <> ["group-acquisition-primary-replaced" | not ("planned-factory-failure" `Text.isInfixOf` failure.exceptionText)]
              <> ["group-acquisition-cancel-leak" | cancellationsWithLeaks /= 0]
              <> ["group-acquisition-cancel-not-observed" | cancellationsWithoutException /= 0]
              <> ["group-acquisition-thread-growth" | finalThreads > baseline + 8]
              <> ["group-acquisition-real-thread-growth" | real.finalThreads > real.baselineThreads + 3]
              <> ["group-acquisition-real-primary-replaced" | not ("planned-real-factory-failure" `Text.isInfixOf` real.exceptionText)]
              <> ["group-acquisition-backend-thread-growth" | backend.finalThreads > backend.baselineThreads + 3]
              <> ["group-acquisition-backend-primary-replaced" | not ("planned-real-factory-failure" `Text.isInfixOf` backend.exceptionText)]
              <> ["group-acquisition-backend-fault-missed" | backend.backendVictims == 0]
      putSummary context Verdicts "kiroku-group-acquisition" $
        object
          [ "failureAcquired" .= failure.acquired,
            "failureReleased" .= failure.released,
            "failureException" .= failure.exceptionText,
            "cancelIterations" .= length cancellation,
            "cancelLeaks" .= cancellationsWithLeaks,
            "cancelMissingExceptions" .= cancellationsWithoutException,
            "baselineThreads" .= baseline,
            "finalThreads" .= finalThreads,
            "realBaselineThreads" .= real.baselineThreads,
            "realFinalThreads" .= real.finalThreads,
            "realBaselineBackends" .= real.baselineBackends,
            "realFinalBackends" .= real.finalBackends,
            "realException" .= real.exceptionText,
            "backendBaselineThreads" .= backend.baselineThreads,
            "backendFinalThreads" .= backend.finalThreads,
            "backendBaselineBackends" .= backend.baselineBackends,
            "backendFinalBackends" .= backend.finalBackends,
            "backendFaultVictims" .= backend.backendVictims,
            "backendException" .= backend.exceptionText
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

failureArm :: IO ArmEvidence
failureArm = do
  acquired <- newIORef []
  released <- newIORef []
  result <-
    try @SomeException $
      runEff $
        runTracingNoop $
          kirokuConsumerGroupProcessorsWith
            ( \member -> do
                when (member == 4) $ liftIO (throwIO (userError "planned-factory-failure"))
                liftIO (remember acquired member)
                pure (trackedAdapter released member (member == 3))
            )
            groupConfig
            (\_ -> pure AckOk)
  acquiredMembers <- reverse <$> readIORef acquired
  releasedMembers <- reverse <$> readIORef released
  pure (ArmEvidence acquiredMembers releasedMembers (either (Text.pack . displayException) (const "no exception") result))

cancellationArm :: Int -> IO ArmEvidence
cancellationArm iteration = do
  acquired <- newIORef []
  released <- newIORef []
  reached <- newEmptyMVar
  blocked <- newEmptyMVar
  let target = fromIntegral (1 + iteration `mod` 7) :: Int32
      build =
        runEff $
          runTracingNoop $
            kirokuConsumerGroupProcessorsWith
              ( \member -> do
                  when (member == target) $ liftIO (putMVar reached () >> takeMVar blocked)
                  liftIO (remember acquired member)
                  pure (trackedAdapter released member False)
              )
              groupConfig
              (\_ -> pure AckOk)
  result <- withAsync build $ \worker -> do
    observed <- timeout 5000000 (takeMVar reached)
    case observed of
      Nothing -> pure "factory gate timeout"
      Just () -> do
        cancel worker
        ended <- waitCatch worker
        pure (either (Text.pack . displayException) (const "no exception") ended)
  acquiredMembers <- reverse <$> readIORef acquired
  releasedMembers <- reverse <$> readIORef released
  pure (ArmEvidence acquiredMembers releasedMembers result)

trackedAdapter :: (IOE :> es) => IORef [Int32] -> Int32 -> Bool -> Adapter es RecordedEvent
trackedAdapter releases member throwOnShutdown =
  Adapter
    { adapterName = "kiroku-group-acquisition-probe",
      source = Stream.nil,
      shutdown = liftIO $ do
        remember releases member
        when throwOnShutdown (throwIO (userError "planned-shutdown-failure"))
    }

remember :: IORef [Int32] -> Int32 -> IO ()
remember reference member = atomicModifyIORef' reference (\members -> (member : members, ()))

groupConfig :: KirokuConsumerGroupConfig
groupConfig = defaultConsumerGroupConfig (SubscriptionName "kenshou-group-acquisition") AllStreams 8

realArm :: RunContext -> Bool -> IO RealEvidence
realArm context killBackends = do
  let postgres = requirePostgres context
      connection = postgres.connectionString <> " application_name=kenshou-kiroku-acquisition"
      name = SubscriptionName ("kenshou-acquisition-" <> renderRunId context.runId <> if killBackends then "-backend" else "-failure")
      config = defaultConsumerGroupConfig name AllStreams 8
      matching = filter ((== "kenshou-kiroku-acquisition") . (.applicationName))
  backendVictimsRef <- newIORef 0
  withStore (defaultConnectionSettings connection) $ \store -> do
    performMajorGC
    baselineThreads <- length <$> listThreads
    baselineBackends <- length . matching <$> listBackends postgres
    result <-
      try @SomeException $
        runEff $
          runTracingNoop $
            kirokuConsumerGroupProcessorsWith
              ( \member -> do
                  when (member == 4) $ liftIO $ do
                    when killBackends $ do
                      victims <- length . matching <$> listBackends postgres
                      atomicModifyIORef' backendVictimsRef (const (victims, ()))
                      _ <- (terminateBackends postgres (ByApplicationName "kenshou-kiroku-acquisition")).inject
                      pure ()
                    throwIO (userError "planned-real-factory-failure")
                  adapter <- kirokuAdapter store (defaultKirokuAdapterConfig name AllStreams) {consumerGroup = Just (ConsumerGroup member 8)}
                  pure adapter {shutdown = adapter.shutdown >> when (member == 3) (liftIO (throwIO (userError "planned-real-shutdown-failure")))}
              )
              config
              (\_ -> pure AckOk)
    threadDelay 5000000
    performMajorGC
    finalThreads <- length <$> listThreads
    finalBackends <- length . matching <$> listBackends postgres
    backendVictims <- readIORef backendVictimsRef
    pure (RealEvidence baselineThreads finalThreads baselineBackends finalBackends (either (Text.pack . displayException) (const "no exception") result) backendVictims)
