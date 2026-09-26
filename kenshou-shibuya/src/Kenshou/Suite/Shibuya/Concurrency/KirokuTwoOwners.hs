module Kenshou.Suite.Shibuya.Concurrency.KirokuTwoOwners (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.Foldable (traverse_)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Process (awaitMark, awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (EffectRow (..), KirokuFixture (..), appendEvents, checkpointOf, effectsOf, ensureEffectsTable, eventPositions, subscriptionFor, withKirokuFixture)
import Kiroku.Store (CategoryName (..))
import Shibuya.Adapter.Kiroku (SubscriptionName (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/two-processes-one-member"),
      revision = 1,
      summary = "Two Kiroku adapter processes sharing one member preserve events while reporting duplicate handler effects.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runTwoOwners
    }

data Evidence = Evidence
  { positions :: ![Int64],
    effects :: ![EffectRow],
    checkpoints :: ![Int64],
    finalCheckpoint :: !(Maybe Int64),
    workerExits :: ![ExitCode]
  }

runTwoOwners :: RunContext -> IO ScenarioReport
runTwoOwners context = do
  outcome <- try @SomeException $ timeout 60000000 $ withKirokuFixture context (runFixture context)
  case outcome of
    Left err -> pure (failedWith ["kiroku-two-owners-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-two-owners-timeout"] "Two Kiroku consumers did not converge within 60 seconds")
    Right (Just evidence) -> do
      let expected = Set.fromList evidence.positions
          actual = Set.fromList [row.position | row <- evidence.effects]
          counts = Map.fromListWith (+) [(row.position, 1 :: Int) | row <- evidence.effects]
          ids = Map.fromListWith Set.union [(row.position, Set.singleton row.eventId) | row <- evidence.effects]
          perProcess = Map.fromListWith (+) [(row.process, 1 :: Int) | row <- evidence.effects]
          duplicateCount = length evidence.effects - Set.size actual
          duplicateFactor = fromIntegral (length evidence.effects) / fromIntegral (length evidence.positions) :: Double
          failures =
            ["missing-handler-effect" | expected /= actual]
              <> ["event-id-mismatch-at-position" | any ((/= 1) . Set.size) (Map.elems ids)]
              <> ["one-owner-never-consumed" | any (\index -> Map.findWithDefault 0 index perProcess == 0) [0, 1]]
              <> ["checkpoint-decreased" | evidence.checkpoints /= sort evidence.checkpoints]
              <> ["checkpoint-not-at-head" | evidence.finalCheckpoint /= Just (last evidence.positions)]
              <> ["worker-exit" | any (/= ExitSuccess) evidence.workerExits]
      putSummary context Verdicts "kiroku-two-processes-one-member" $
        object
          [ "events" .= length evidence.positions,
            "effects" .= length evidence.effects,
            "duplicateEffects" .= duplicateCount,
            "duplicateFactor" .= duplicateFactor,
            "maxCopiesPerEvent" .= maximum (Map.elems counts),
            "perProcessEffects" .= Map.toList perProcess,
            "checkpointSamples" .= evidence.checkpoints,
            "finalCheckpoint" .= evidence.finalCheckpoint,
            "workerExits" .= map show evidence.workerExits
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: RunContext -> KirokuFixture -> IO Evidence
runFixture context fixture = do
  ensureEffectsTable fixture.pool
  let subscription@(SubscriptionName subscriptionName) = subscriptionFor fixture "two-owners"
      arm = "two-owners"
      CategoryName categoryName = fixture.category
      args index =
        object
          [ "subscription" .= subscriptionName,
            "category" .= categoryName,
            "arm" .= arm,
            "member" .= (0 :: Int32),
            "groupSize" .= (0 :: Int32),
            "processIndex" .= index
          ]
  (positions, checkpoints, workerExits) <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
    specs <- traverse (\index -> roleProcess check "shibuya/kiroku-consumer" (fromIntegral index) (args index)) ([0, 1] :: [Int32])
    workers <- traverse (spawn supervisor) specs
    traverse_ (`awaitReady` 5000) workers
    traverse_ (`sendCommand` CtlStart) workers
    traverse_ (\worker -> awaitMark worker "running" 10000) workers
    threadDelay 100000
    initial <- checkpointOf fixture subscription 0
    appendEvents fixture 40
    positions <- eventPositions fixture
    unless (length positions == 40) (fail "fixture did not append forty events")
    samples <- waitForEffects fixture subscription arm positions [maybe 0 id initial]
    threadDelay 250000
    workerExits <- traverse (\worker -> stopGracefully supervisor worker 5000) workers
    pure (positions, samples, workerExits)
  effects <- effectsOf fixture.pool arm
  finalCheckpoint <- checkpointOf fixture subscription 0
  pure (Evidence positions effects checkpoints finalCheckpoint workerExits)

waitForEffects :: KirokuFixture -> SubscriptionName -> Text -> [Int64] -> [Int64] -> IO [Int64]
waitForEffects fixture subscription arm positions samples = do
  checkpoint <- checkpointOf fixture subscription 0
  effects <- effectsOf fixture.pool arm
  let nextSamples = samples <> [maybe 0 id checkpoint]
      complete = checkpoint == Just (last positions) && Set.fromList [row.position | row <- effects] == Set.fromList positions
  if complete then pure nextSamples else threadDelay 50000 >> waitForEffects fixture subscription arm positions nextSamples
