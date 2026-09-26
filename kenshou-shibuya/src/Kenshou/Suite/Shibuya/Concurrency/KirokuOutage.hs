module Kenshou.Suite.Shibuya.Concurrency.KirokuOutage (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (SomeException, displayException, onException, try)
import Control.Monad (unless, void)
import Data.Aeson (Value, object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (Limit (..), Persistence (..), UnliftStrategy (..), liftIO, runEff, withEffToIO)
import Hasql.Pool (Pool)
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (EffectRow (..), KirokuFixture (..), appendEvents, appendMoreEvents, checkpointOf, effectsOf, ensureEffectsTable, eventPositions, insertEffect, subscriptionFor, withKirokuConnectionPool, withKirokuFixture)
import Kiroku.Store (CategoryName (..), GlobalPosition (..), KirokuStore, RecordedEvent (..), StreamName (..), defaultConnectionSettings, withStore)
import Shibuya.Adapter.Kiroku (SubscriptionName (..), SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.IO (hFlush, hPutStrLn, stderr)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/postgres-outage-and-reconnect"),
      revision = 1,
      summary = "Terminates subscription backends and restarts the postmaster while a Kiroku consumer and appender continue.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [KnobSpec observeKnob "Seconds to observe automatic checkpoint recovery before replacement" KnobInt (VInt 60) (IntRange 30 120) []],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] True)},
      knownDefect = Nothing,
      run = runOutage
    }
  where
    observeKnob = either (error . Text.unpack) id (mkKnobName "kiroku-adapter.observe-seconds")

data ArmEvidence = ArmEvidence
  { expected :: ![Int64],
    effects :: ![EffectRow],
    checkpoints :: ![Int64],
    finalCheckpoint :: !(Maybe Int64),
    checkpointBeforeManualRestart :: !(Maybe Int64),
    faultVictims :: !Int,
    producerAttempts :: !Int,
    appExits :: ![Text],
    recovered :: !Bool,
    manualRestartRecovered :: !Bool,
    consumerStopped :: !Bool
  }

runOutage :: RunContext -> IO ScenarioReport
runOutage context = do
  let observeSeconds = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kiroku-adapter.observe-seconds")))
  outcome <- try @SomeException $ timeout 240000000 $ withKirokuFixture context $ \fixture -> do
    backend <- runArm context fixture "backend" False observeSeconds
    postmaster <- runArm context fixture "postmaster" True observeSeconds
    pure (backend, postmaster)
  case outcome of
    Left err -> pure (failedWith ["kiroku-outage-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-outage-timeout"] "Kiroku outage exceeded four minutes")
    Right (Just (backend, postmaster)) -> do
      let failures = checkArm "backend" backend <> checkArm "postmaster" postmaster
      putSummary context Verdicts "kiroku-outage-reconnect" $
        object
          [ "backendTermination" .= armValue backend,
            "postmasterRestart" .= armValue postmaster,
            "observeSeconds" .= observeSeconds,
            "implementationFindings" .= (["backend-checkpoint-stalled-until-restart" | not backend.recovered] :: [Text])
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runArm :: RunContext -> KirokuFixture -> Text -> Bool -> Int -> IO ArmEvidence
runArm context fixture arm postmaster observeSeconds = do
  let postgres = requirePostgres context
      CategoryName baseCategory = fixture.category
      category = CategoryName (baseCategory <> if postmaster then "p" else "b")
      CategoryName categoryName = category
      stream = StreamName (categoryName <> "-1")
      source = fixture {category, stream}
      subscription = subscriptionFor fixture ("outage-" <> arm)
      connection = postgres.connectionString
      applicationName = "kenshou-shibuya-kiroku-outage-" <> arm
  ensureEffectsTable fixture.pool
  appendEvents source 40
  traceStage arm "seeded"
  initial <- eventPositions source
  stopRequested <- newEmptyMVar
  exits <- newIORef []
  producerAttempts <- newIORef 0
  samples <- newIORef []
  consumer <- async (consumerLoop connection applicationName category subscription arm 0 stopRequested exits)
  do
    requireWithin "initial effects" 20000000 (waitForEffects connection arm (Set.fromList initial))
    requireWithin "initial checkpoint" 20000000 (waitForCheckpoint connection source subscription (maximum initial))
    traceStage arm "initial delivered"
    sampler <- async (sampleCheckpoints connection source subscription samples)
    do
      (victims, extra) <-
        if postmaster
          then doPostmasterFault postgres applicationName (appendWithRetry connection source 41 40 producerAttempts)
          else do
            victims <- doBackendFault postgres applicationName
            extra <- appendWithRetry connection source 41 40 producerAttempts
            pure (victims, extra)
      traceStage arm "fault and append complete"
      let expected = initial <> extra
      recovered <- maybe False (const True) <$> timeout (observeSeconds * 1000000) (waitForEffects connection arm (Set.fromList expected) >> waitForCheckpoint connection source subscription (maximum extra))
      traceStage arm (if recovered then "recovered" else "recovery timed out")
      void (tryPutMVar stopRequested ())
      stopped <- maybe False (const True) <$> timeout 10000000 (waitCatch consumer)
      unless stopped $ void (timeout 2000000 (cancel consumer))
      void (timeout 2000000 (cancel sampler))
      checkpointBeforeManualRestart <- withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool ->
        checkpointOf (source {pool}) subscription 0
      manualRestartRecovered <-
        if recovered
          then pure True
          else do
            traceStage arm "starting replacement"
            replacementStop <- newEmptyMVar
            replacement <- async (consumerLoop connection applicationName category subscription arm 100 replacementStop exits)
            resumed <- maybe False (const True) <$> timeout 20000000 (waitForCheckpoint connection source subscription (maximum extra))
            void (tryPutMVar replacementStop ())
            replacementStopped <- maybe False (const True) <$> timeout 10000000 (waitCatch replacement)
            unless replacementStopped $ void (timeout 2000000 (cancel replacement))
            traceStage arm (if resumed then "replacement checkpointed" else "replacement stalled")
            pure resumed
      withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool -> do
        let finalSource = source {pool}
        effects <- effectsOf pool arm
        finalCheckpoint <- checkpointOf finalSource subscription 0
        checkpoints <- reverse <$> readIORef samples
        appExits <- reverse <$> readIORef exits
        attempts <- readIORef producerAttempts
        pure (ArmEvidence expected effects checkpoints finalCheckpoint checkpointBeforeManualRestart victims attempts appExits recovered manualRestartRecovered stopped)

requireWithin :: String -> Int -> IO a -> IO a
requireWithin label micros action = do
  result <- timeout micros action
  maybe (fail ("Kiroku outage timed out waiting for " <> label)) pure result

traceStage :: Text -> String -> IO ()
traceStage arm message = hPutStrLn stderr ("kiroku-outage " <> Text.unpack arm <> ": " <> message) >> hFlush stderr

doBackendFault :: PostgresEnv -> Text -> IO Int
doBackendFault postgres applicationName = do
  backends <- listBackends postgres
  let victims = [backend | backend <- backends, backend.applicationName == applicationName]
  _ <- (terminateBackends postgres (ByApplicationName applicationName)).inject
  pure (length victims)

doPostmasterFault :: PostgresEnv -> Text -> IO [Int64] -> IO (Int, [Int64])
doPostmasterFault postgres applicationName append =
  case postgres.control of
    Nothing -> fail "postmaster control unavailable"
    Just control -> do
      backends <- listBackends postgres
      let victims = length [backend | backend <- backends, backend.applicationName == applicationName]
      control.stopServer StopImmediate
      ( withAsync append $ \producer -> do
          threadDelay 10000000
          control.startServer
          extra <- wait producer
          pure (victims, extra)
        )
        `onException` control.startServer

appendWithRetry :: Text -> KirokuFixture -> Int -> Int -> IORef Int -> IO [Int64]
appendWithRetry connection source first count attempts = go (0 :: Int)
  where
    go failures
      | failures >= 100 = fail "Kiroku appender could not resume after outage"
      | otherwise = do
          atomicModifyIORef' attempts (\number -> (number + 1, ()))
          result <- try @SomeException $ withStore (defaultConnectionSettings connection) $ \store ->
            appendMoreEvents (source {store}) first count
          case result of
            Left _ -> threadDelay 200000 >> go (failures + 1)
            Right () -> withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool -> do
              positions <- eventPositions (source {pool})
              pure (drop (length positions - count) positions)

consumerLoop :: Text -> Text -> CategoryName -> SubscriptionName -> Text -> Int -> MVar () -> IORef [Text] -> IO ()
consumerLoop connection applicationName category subscription arm processOffset stopRequested exits = go (0 :: Int)
  where
    go attempts
      | attempts >= 100 = fail "Kiroku consumer exhausted restart loop"
      | otherwise = do
          stopped <- not <$> isEmptyMVar stopRequested
          unless stopped $ do
            result <- try @SomeException $ withStore (defaultConnectionSettings (connection <> " application_name=" <> applicationName)) $ \store ->
              withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-effects" $ \pool ->
                runInstance store pool category subscription arm (processOffset + attempts) stopRequested
            let end = either (Text.pack . displayException) id result
            traceStage arm ("consumer exit " <> Text.unpack end)
            atomicModifyIORef' exits (\values -> (end : values, ()))
            threadDelay 200000
            go (attempts + 1)

runInstance :: KirokuStore -> Pool -> CategoryName -> SubscriptionName -> Text -> Int -> MVar () -> IO Text
runInstance store pool category subscription arm processIndex stopRequested = runEff $ runTracingNoop $ do
  let handler message = do
        let GlobalPosition position = message.envelope.payload.globalPosition
            MessageId eventId = message.envelope.messageId
            attempt = maybe (-1) (\(Attempt number) -> fromIntegral number) message.envelope.attempt
        at <- liftIO getCurrentTime
        liftIO $ insertEffect pool arm (EffectRow position eventId 0 (fromIntegral processIndex) attempt at)
        pure AckOk
  adapter <- kirokuAdapter store (defaultKirokuAdapterConfig subscription (Category category))
  started <- runApp defaultAppConfig [(ProcessorId ("kiroku-outage-" <> arm), mkProcessor adapter handler)]
  case started of
    Left err -> error (show err)
    Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $ do
      outcome <- race (try @SomeException (runInIO (waitApp handle))) (readMVar stopRequested)
      _ <- timeout 5000000 (try @SomeException (runInIO (stopAppGracefully defaultShutdownConfig handle)))
      pure $ case outcome of
        Left (Left err) -> "wait: " <> Text.pack (displayException err)
        Left (Right ()) -> "wait: returned"
        Right () -> "stopped"

waitForEffects :: Text -> Text -> Set.Set Int64 -> IO ()
waitForEffects connection arm expected = do
  effects <- withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool -> effectsOf pool arm
  unless (expected `Set.isSubsetOf` Set.fromList [row.position | row <- effects]) $ threadDelay 100000 >> waitForEffects connection arm expected

waitForCheckpoint :: Text -> KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForCheckpoint connection source subscription expected = do
  value <- withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool -> checkpointOf (source {pool}) subscription 0
  unless (maybe False (>= expected) value) $ threadDelay 100000 >> waitForCheckpoint connection source subscription expected

sampleCheckpoints :: Text -> KirokuFixture -> SubscriptionName -> IORef [Int64] -> IO ()
sampleCheckpoints connection source subscription samples = do
  result <- try @SomeException $ withKirokuConnectionPool connection "kenshou-shibuya-kiroku-outage-oracle" $ \pool ->
    checkpointOf (source {pool}) subscription 0
  case result of
    Right (Just value) -> atomicModifyIORef' samples (\values -> (value : values, ()))
    _ -> pure ()
  threadDelay 200000
  sampleCheckpoints connection source subscription samples

checkArm :: Text -> ArmEvidence -> [Text]
checkArm name evidence =
  let expected = Set.fromList evidence.expected
      observed = Set.fromList [row.position | row <- evidence.effects]
      positionsByProcess = Map.fromListWith (<>) [(row.process, [row.position]) | row <- reverse evidence.effects]
   in [name <> ": missing-event" | not (expected `Set.isSubsetOf` observed)]
        <> [name <> ": unexpected-event" | not (observed `Set.isSubsetOf` expected)]
        <> [name <> ": out-of-order" | any (\positions -> positions /= sort positions) (Map.elems positionsByProcess)]
        <> [name <> ": checkpoint-decreased" | evidence.checkpoints /= sort evidence.checkpoints]
        <> [name <> ": checkpoint-behind" | maybe True (< maximum evidence.expected) evidence.finalCheckpoint]
        <> [name <> ": manual-restart-failed" | not evidence.manualRestartRecovered]
        <> [name <> ": fault-missed" | evidence.faultVictims == 0]
        <> [name <> ": appender-did-not-run" | evidence.producerAttempts == 0]
        <> [name <> ": consumer-did-not-stop" | not evidence.consumerStopped]

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "expectedEvents" .= length evidence.expected,
      "effects" .= length evidence.effects,
      "duplicateEffects" .= (length evidence.effects - Set.size (Set.fromList [row.position | row <- evidence.effects])),
      "checkpointSampleCount" .= length evidence.checkpoints,
      "checkpointFirst" .= listToMaybe evidence.checkpoints,
      "checkpointLast" .= listToMaybe (reverse evidence.checkpoints),
      "checkpointBeforeManualRestart" .= evidence.checkpointBeforeManualRestart,
      "finalCheckpoint" .= evidence.finalCheckpoint,
      "faultVictims" .= evidence.faultVictims,
      "producerAttempts" .= evidence.producerAttempts,
      "applicationExits" .= evidence.appExits,
      "recovered" .= evidence.recovered,
      "manualRestartRecovered" .= evidence.manualRestartRecovered,
      "consumerStopped" .= evidence.consumerStopped
    ]
