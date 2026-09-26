module Kenshou.Suite.Shibuya.Concurrency.KirokuRetryRestart (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (DeadLetterRow (..), EffectRow (..), KirokuFixture (..), appendEvents, checkpointOf, deadLettersOf, effectsOf, ensureEffectsTable, eventPositions, subscriptionFor, withKirokuFixture)
import Kiroku.Store (CategoryName (..))
import Shibuya.Adapter.Kiroku (SubscriptionName (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/retry-budget-resets-on-restart"),
      revision = 1,
      summary = "Kills a Kiroku consumer after its third retry delivery and verifies restart resets attempts before one dead letter.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runRestart
    }

data Evidence = Evidence
  { position :: !Int64,
    effects :: ![EffectRow],
    letters :: ![DeadLetterRow],
    checkpoint :: !(Maybe Int64),
    replacementExit :: !ExitCode
  }

runRestart :: RunContext -> IO ScenarioReport
runRestart context = do
  outcome <- try @SomeException $ timeout 60000000 $ withKirokuFixture context (runFixture context)
  case outcome of
    Left err -> pure (failedWith ["kiroku-retry-restart-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-retry-restart-timeout"] "Kiroku retry restart did not finish within 60 seconds")
    Right (Just evidence) -> do
      let firstAttempts = [row.attempt | row <- evidence.effects, row.process == 0]
          replacementAttempts = [row.attempt | row <- evidence.effects, row.process == 1]
          failures =
            ["prekill-attempts" | firstAttempts /= [0, 1, 2]]
              <> ["restart-did-not-reset-attempt" | replacementAttempts /= [0 .. 4]]
              <> ["delivery-budget-exceeded" | length evidence.effects > 10]
              <> ["dead-letter-count" | length evidence.letters /= 1]
              <> ["dead-letter-position" | any ((/= evidence.position) . (.position)) evidence.letters]
              <> ["dead-letter-attempt-count" | any ((/= 5) . (.attempts)) evidence.letters]
              <> ["dead-letter-reason" | any ((/= object ["kind" .= ("max_attempts_exceeded" :: Text), "attempts" .= (5 :: Int)]) . (.reason)) evidence.letters]
              <> ["dead-letter-event-id" | any (\letter -> not (all ((== letter.eventId) . (.eventId)) evidence.effects)) evidence.letters]
              <> ["checkpoint-not-past-poison" | evidence.checkpoint /= Just evidence.position]
              <> ["replacement-exit" | evidence.replacementExit /= ExitSuccess]
      putSummary context Verdicts "kiroku-retry-budget-restart" $
        object
          [ "position" .= evidence.position,
            "firstProcessAttempts" .= firstAttempts,
            "replacementAttempts" .= replacementAttempts,
            "totalDeliveries" .= length evidence.effects,
            "deadLetters" .= [object ["position" .= row.position, "eventId" .= row.eventId, "reason" .= row.reason, "attempts" .= row.attempts] | row <- evidence.letters],
            "checkpoint" .= evidence.checkpoint,
            "replacementExit" .= show evidence.replacementExit
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: RunContext -> KirokuFixture -> IO Evidence
runFixture context fixture = do
  ensureEffectsTable fixture.pool
  appendEvents fixture 1
  positions <- eventPositions fixture
  position <- case positions of
    [value] -> pure value
    _ -> fail "fixture did not append one event"
  let subscription@(SubscriptionName subscriptionName) = subscriptionFor fixture "retry-restart"
      CategoryName categoryName = fixture.category
      arm = "retry-restart"
      args processIndex gateAfterAttemptTwo =
        object
          [ "subscription" .= subscriptionName,
            "category" .= categoryName,
            "arm" .= arm,
            "member" .= (0 :: Int32),
            "groupSize" .= (0 :: Int32),
            "processIndex" .= processIndex,
            "retryAlways" .= True,
            "gateAfterAttemptTwo" .= gateAfterAttemptTwo
          ]
  replacementExit <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
    firstSpec <- roleProcess check "shibuya/kiroku-consumer" 0 (args (0 :: Int32) True)
    first <- spawn supervisor firstSpec
    awaitReady first 5000
    sendCommand first CtlStart
    awaitMark first "running" 10000
    awaitMark first "retry-gate" 15000
    beforeKill <- effectsOf fixture.pool arm
    unless ([row.attempt | row <- beforeKill] == [0, 1, 2]) (fail "retry gate did not hold exactly three deliveries")
    killChild supervisor first

    replacementSpec <- roleProcess check "shibuya/kiroku-consumer" 1 (args (1 :: Int32) False)
    replacement <- spawn supervisor replacementSpec
    awaitReady replacement 5000
    sendCommand replacement CtlStart
    awaitMark replacement "running" 10000
    waitForDeadLetter fixture subscription position
    stopGracefully supervisor replacement 5000
  effects <- effectsOf fixture.pool arm
  letters <- deadLettersOf fixture subscription 0
  checkpoint <- checkpointOf fixture subscription 0
  pure (Evidence position effects letters checkpoint replacementExit)

waitForDeadLetter :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForDeadLetter fixture subscription position = do
  letters <- deadLettersOf fixture subscription 0
  checkpoint <- checkpointOf fixture subscription 0
  unless (length letters == 1 && checkpoint == Just position) $ threadDelay 10000 >> waitForDeadLetter fixture subscription position
