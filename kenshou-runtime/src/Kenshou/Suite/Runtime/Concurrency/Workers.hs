module Kenshou.Suite.Runtime.Concurrency.Workers (scenarios) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM)
import Data.Aeson (object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Id (deriveGen)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario, faultText)
import Kenshou.Suite.Runtime.Knobs (runtimeKnobName)
import Kenshou.Suite.Runtime.Roles (longRunningRoles)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..), Timeouts (..), timeoutsFor)
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), killAndRestart, pauseProcess, stopAndRestart)
import System.Random.SplitMix (nextInt)

scenarios :: [Scenario]
scenarios = [sigkillRole, sigkillStorm, pausedLeaseHolder, rollingRestart]

-- | A seeded schedule kills a random process of a random role, the driver
-- included, every period for ten minutes of traffic.
sigkillStorm :: Scenario
sigkillStorm =
  faultScenario
    FaultPlan
      { component = "workers",
        name = "sigkill-storm",
        summary = "Kills a seeded random process of a random role every 15 seconds for eight minutes while orders flow, and judges I1 to I6.",
        tier = TierExtended,
        placement = PlaceEither,
        overrides = [("runtime.duration-seconds", VInt 600), ("fault.period-seconds", VInt 15), ("fault.count", VInt 32)],
        extraKnobs = [],
        inject = \context system -> do
          let processes = max 1 system.config.processesPerRole
              picks = take (faultInt context.knobs "fault.count") (schedule (deriveGen context.seed "sigkill-storm"))
              schedule gen =
                let (roleDraw, gen') = nextInt gen
                    (indexDraw, gen'') = nextInt gen'
                 in (longRunningRoles !! (roleDraw `mod` length longRunningRoles), indexDraw `mod` processes) : schedule gen''
          restarts <- forM picks \(role, index) -> do
            threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
            killAndRestart system role index
          let applied = catMaybes restarts
          pure (FaultEvidence (length applied) (object ["schedule" .= [object ["role" .= role, "index" .= index] | (role, index) <- picks], "restarts" .= toJSON applied])),
        knownDefect = Nothing,
        databaseProxies = False
      }

-- | Freezes a shop shard owner and a warehouse resume worker for twice the
-- workflow lease, so other processes take over their leases, then resumes
-- them. The resumed zombies may repeat deliveries, but only inside the
-- pause window extended by the lease.
pausedLeaseHolder :: Scenario
pausedLeaseHolder =
  faultScenario
    FaultPlan
      { component = "workers",
        name = "paused-lease-holder",
        summary = "Pauses a shard owner and a resume worker with SIGSTOP for twice the lease, resumes them, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.count", VInt 3), ("fault.period-seconds", VInt 30)],
        extraKnobs = [],
        inject = \context system -> do
          let pause = round (2 * (timeoutsFor system.config.ttlProfile).workflowLeaseSeconds * 1000000) :: Int
          paused <- forM [1 .. faultInt context.knobs "fault.count"] \n -> do
            threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
            -- The two pauses overlap: each runs on its own thread.
            done <- newEmptyMVar
            _ <- forkIO (pauseProcess system "b-resume" (n `mod` 2) pause >>= putMVar done)
            shard <- pauseProcess system "a-dispatch" (n `mod` 2) pause
            resume <- takeMVar done
            pure (length (filter id [shard, resume]))
          pure (FaultEvidence (sum paused) (object ["pauseMicros" .= pause, "pausedPerRound" .= paused])),
        knownDefect = Nothing,
        databaseProxies = False
      }

-- | Stops every process of every role gracefully, one at a time, and starts
-- its replacement. A graceful stop relinquishes leases, so takeover need
-- not wait for lease expiry.
rollingRestart :: Scenario
rollingRestart =
  faultScenario
    FaultPlan
      { component = "workers",
        name = "rolling-restart",
        summary = "Stops each role process gracefully in turn and starts its replacement while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.period-seconds", VInt 5)],
        extraKnobs = [],
        inject = \context system -> do
          let processes = max 1 system.config.processesPerRole
          restarts <- forM [(role, index) | role <- longRunningRoles, index <- [0 .. processes - 1]] \(role, index) -> do
            threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
            stopAndRestart system role index
          let applied = catMaybes restarts
          pure (FaultEvidence (length applied) (object ["restarts" .= toJSON applied])),
        knownDefect = Nothing,
        databaseProxies = False
      }

-- | One process of the victim role is killed every period and replaced,
-- alternating between the role's processes.
sigkillRole :: Scenario
sigkillRole =
  faultScenario
    FaultPlan
      { component = "workers",
        name = "sigkill-role",
        summary = "Kills one process of a chosen role with SIGKILL every period while orders flow, restarts it, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [],
        extraKnobs = [victimKnob],
        inject = \context system -> do
          let role = faultText context.knobs "fault.victim-role"
              period = faultInt context.knobs "fault.period-seconds"
              processes = max 1 system.config.processesPerRole
          restarts <- forM [0 .. faultInt context.knobs "fault.count" - 1] \n -> do
            threadDelay (period * 1000000)
            killAndRestart system role (n `mod` processes)
          let applied = catMaybes restarts
          pure (FaultEvidence (length applied) (object ["victimRole" .= role, "restarts" .= toJSON applied])),
        knownDefect = Nothing,
        databaseProxies = False
      }

victimKnob :: KnobSpec
victimKnob =
  KnobSpec
    (runtimeKnobName "fault.victim-role")
    "The role whose processes are killed; every long-running role is a planner variant."
    KnobText
    (VText "b-resume")
    (OneOf (VText "b-resume" :| [VText role | role <- longRunningRoles, role /= "b-resume"]))
    [VText role | role <- longRunningRoles]
