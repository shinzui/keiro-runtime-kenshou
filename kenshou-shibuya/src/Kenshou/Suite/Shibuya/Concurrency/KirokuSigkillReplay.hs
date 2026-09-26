module Kenshou.Suite.Shibuya.Concurrency.KirokuSigkillReplay (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless, when)
import Data.Aeson (object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (EffectRow (..), KirokuFixture (..), appendEvents, appendMoreEvents, checkpointOf, effectsOf, ensureEffectsTable, eventPositions, subscriptionFor, withKirokuFixture)
import Kiroku.Store (CategoryName (..))
import Shibuya.Adapter.Kiroku (SubscriptionName (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/sigkill-replay-window"),
      revision = 1,
      summary = "Kills Kiroku consumers after durable effects and verifies bounded replay, position order and checkpoint monotonicity.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (name "crash.kills") "Number of effect-gated worker kills" KnobInt (VInt 20) (IntRange 1 20) [],
          KnobSpec (name "crash.mode") "Kill after a durable effect gate or at seeded offsets" KnobText (VText "gated") (OneOf (VText "gated" :| [VText "random"])) [],
          KnobSpec (name "kiroku-adapter.batch-size") "Subscription fetch batch size" KnobInt (VInt 10) (OneOf (VInt 1 :| [VInt 10, VInt 100])) [],
          KnobSpec (name "kiroku-adapter.target") "Subscription target" KnobText (VText "category") (OneOf (VText "category" :| [VText "all-streams"])) [],
          KnobSpec (name "kiroku-adapter.phase") "Events present at startup or appended while live" KnobText (VText "catch-up") (OneOf (VText "catch-up" :| [VText "live"])) []
        ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runReplay
    }
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

data Evidence = Evidence
  { positions :: ![Int64],
    effects :: ![EffectRow],
    checkpoints :: ![Maybe Int64],
    killCheckpoints :: ![Maybe Int64],
    killPositions :: ![Maybe Int64],
    finalCheckpoint :: !(Maybe Int64),
    replacementExit :: !ExitCode
  }

runReplay :: RunContext -> IO ScenarioReport
runReplay context = do
  let kills = fromIntegral (knobInt context.knobs (name "crash.kills"))
      batchSize = fromIntegral (knobInt context.knobs (name "kiroku-adapter.batch-size"))
      target = knobText context.knobs (name "kiroku-adapter.target")
      phase = knobText context.knobs (name "kiroku-adapter.phase")
      mode = knobText context.knobs (name "crash.mode")
  outcome <- try @SomeException $ timeout 300000000 $ withKirokuFixture context (runFixture context kills batchSize target phase mode)
  case outcome of
    Left err -> pure (failedWith ["kiroku-sigkill-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-sigkill-timeout"] "Kiroku crash-window run exceeded five minutes")
    Right (Just evidence) -> do
      let expected = Set.fromList evidence.positions
          actual = Set.fromList [row.position | row <- evidence.effects]
          byProcess = Map.fromListWith (<>) [(row.process, [row.position]) | row <- reverse evidence.effects]
          processSets = Map.map Set.fromList byProcess
          nonEmptyRuns = [observed | worker <- [0 .. fromIntegral kills], let observed = Map.findWithDefault [] worker byProcess, not (null observed)]
          crossRunGaps =
            [ (priorEnd, followingStart)
            | (prior, following) <- zip nonEmptyRuns (drop 1 nonEmptyRuns),
              Just priorEnd <- [maximumMaybe prior],
              Just followingStart <- [listToMaybe following],
              followingStart > priorEnd + 1
            ]
          replaySizes =
            [ Set.size (Set.intersection (Map.findWithDefault Set.empty worker processSets) (Map.findWithDefault Set.empty (worker + 1) processSets))
            | worker <- [0 .. fromIntegral kills - 1]
            ]
          duplicatePositions = Set.fromList [position | (position, count) <- Map.toList (Map.fromListWith (+) [(row.position, 1 :: Int) | row <- evidence.effects]), count > 1]
          killCheckpointByProcess = Map.fromList (zip [0 ..] (map (maybe 0 id) evidence.killCheckpoints))
          killedPositions = Set.fromList [row.position | row <- evidence.effects, row.process < fromIntegral kills, row.position > Map.findWithDefault 0 row.process killCheckpointByProcess]
          checkpointValues = [value | Just value <- evidence.checkpoints]
          replayBound = if phase == "live" && target == "all-streams" then 1000 else batchSize
          failures =
            ["missing-event" | actual /= expected]
              <> ["out-of-order" | any (\observed -> observed /= sort observed) (Map.elems byProcess)]
              <> ["cross-run-gap" | not (null crossRunGaps)]
              <> ["duplicate-outside-kill-window" | not (duplicatePositions `Set.isSubsetOf` killedPositions)]
              <> ["replay-exceeded-bound" | any (> replayBound) replaySizes]
              <> ["checkpoint-decreased" | checkpointValues /= sort checkpointValues]
              <> ["checkpoint-behind" | evidence.finalCheckpoint /= Just (maximum evidence.positions)]
              <> ["kill-count" | length evidence.killPositions /= kills]
              <> ["gate-count" | mode == "gated" && any (== Nothing) evidence.killPositions]
              <> ["random-kills-missed-work" | mode == "random" && all (== Nothing) evidence.killPositions]
              <> ["replacement-exit" | evidence.replacementExit /= ExitSuccess]
      putSummary context Verdicts "kiroku-sigkill-replay" $
        object
          [ "kills" .= kills,
            "batchSize" .= batchSize,
            "target" .= target,
            "phase" .= phase,
            "mode" .= mode,
            "events" .= Set.size expected,
            "effects" .= length evidence.effects,
            "duplicatePositions" .= Set.size duplicatePositions,
            "killPositions" .= evidence.killPositions,
            "checkpointSamples" .= evidence.checkpoints,
            "killCheckpoints" .= evidence.killCheckpoints,
            "maxReplayAfterKill" .= maximum (0 : replaySizes),
            "crossRunGaps" .= crossRunGaps,
            "replayBound" .= replayBound,
            "finalCheckpoint" .= evidence.finalCheckpoint,
            "replacementExit" .= show evidence.replacementExit
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

runFixture :: RunContext -> Int -> Int -> Text -> Text -> Text -> KirokuFixture -> IO Evidence
runFixture context kills batchSize target phase mode fixture = do
  ensureEffectsTable fixture.pool
  when (phase == "catch-up") (appendEvents fixture 100)
  startAppender <- newEmptyMVar
  let subscription@(SubscriptionName subscriptionName) = subscriptionFor fixture "sigkill-replay"
      CategoryName categoryName = fixture.category
      arm = "sigkill-replay"
      args processIndex gate =
        object
          [ "subscription" .= subscriptionName,
            "category" .= categoryName,
            "arm" .= arm,
            "member" .= (0 :: Int32),
            "groupSize" .= (0 :: Int32),
            "processIndex" .= processIndex,
            "batchSize" .= batchSize,
            "target" .= target,
            "delayAfterEffectMicros" .= (if mode == "random" then 3000 :: Int else 0),
            "gateOnPosition" .= gate
          ]
  checkpointSamples <- newIORef []
  (killPositions, killCheckpoints, replacementExit) <-
    withAsync (appendContinuously fixture phase startAppender) $ \appender ->
      withAsync (sampleCheckpoints fixture subscription checkpointSamples) $ \_ ->
        withCheck context $ \check -> withSupervisor check $ \supervisor -> do
          samples <- traverse (killOne check supervisor args subscription startAppender) [0 .. kills - 1]
          wait appender
          expected <- eventPositions fixture
          spec <- roleProcess check "shibuya/kiroku-consumer" kills (args kills (Nothing :: Maybe Int64))
          replacement <- spawn supervisor spec
          awaitReady replacement 5000
          sendCommand replacement CtlStart
          awaitMark replacement "running" 10000
          waitForPositions fixture.pool arm (Set.fromList expected)
          waitForCheckpoint fixture subscription (maximum expected)
          replacementExit <- stopGracefully supervisor replacement 5000
          pure (map fst samples, map snd samples, replacementExit)
  positions <- eventPositions fixture
  effects <- effectsOf fixture.pool arm
  finalCheckpoint <- checkpointOf fixture subscription 0
  checkpoints <- reverse <$> readIORef checkpointSamples
  pure (Evidence positions effects (checkpoints <> [finalCheckpoint]) killCheckpoints killPositions finalCheckpoint replacementExit)
  where
    killOne check supervisor args subscription startAppender iteration = do
      gate <- if mode == "random" then pure Nothing else if iteration == 0 && phase == "live" then pure (Just (-1)) else Just <$> waitForPosition fixture iteration
      spec <- roleProcess check "shibuya/kiroku-consumer" iteration (args iteration gate)
      worker <- spawn supervisor spec
      awaitReady worker 5000
      sendCommand worker CtlStart
      awaitMark worker "running" 10000
      when (iteration == 0) (putMVar startAppender ())
      if mode == "gated"
        then awaitMark worker "effect-gate" 15000
        else do
          let delayMicros = 1000 + fromIntegral ((unSeed context.seed + fromIntegral iteration * 7919) `mod` 30000)
          threadDelay delayMicros
      observed <- effectsOf fixture.pool "sigkill-replay"
      let workerPositions = [row.position | row <- observed, row.process == fromIntegral iteration]
          killPosition = if mode == "gated" && gate /= Just (-1) then gate else maximumMaybe workerPositions
      when (mode == "gated" && maybe True (`notElem` workerPositions) killPosition) (fail "worker did not persist its gated effect")
      checkpoint <- checkpointOf fixture subscription 0
      killChild supervisor worker
      pure (killPosition, checkpoint)

maximumMaybe :: [Int64] -> Maybe Int64
maximumMaybe [] = Nothing
maximumMaybe values = Just (maximum values)

waitForPosition :: KirokuFixture -> Int -> IO Int64
waitForPosition fixture index = do
  positions <- eventPositions fixture
  maybe (threadDelay 20000 >> waitForPosition fixture index) pure (listToMaybe (drop index positions))

appendContinuously :: KirokuFixture -> Text -> MVar () -> IO ()
appendContinuously fixture phase start = do
  _ <- takeMVar start
  when (phase == "live") (appendEvents fixture 10)
  let first = if phase == "live" then 11 else 101
      lastStart = if phase == "live" then 91 else 191
  mapM_ (\number -> threadDelay 50000 >> appendMoreEvents fixture number 10) [first, first + 10 .. lastStart]

waitForPositions :: Pool -> Text -> Set Int64 -> IO ()
waitForPositions pool arm expected = do
  effects <- effectsOf pool arm
  unless (expected `Set.isSubsetOf` Set.fromList [row.position | row <- effects]) $ threadDelay 20000 >> waitForPositions pool arm expected

waitForCheckpoint :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForCheckpoint fixture subscription expected = do
  value <- checkpointOf fixture subscription 0
  unless (maybe False (>= expected) value) $ threadDelay 20000 >> waitForCheckpoint fixture subscription expected

sampleCheckpoints :: KirokuFixture -> SubscriptionName -> IORef [Maybe Int64] -> IO ()
sampleCheckpoints fixture subscription samples = do
  value <- checkpointOf fixture subscription 0
  atomicModifyIORef' samples (\previous -> (value : previous, ()))
  threadDelay 200000
  sampleCheckpoints fixture subscription samples
