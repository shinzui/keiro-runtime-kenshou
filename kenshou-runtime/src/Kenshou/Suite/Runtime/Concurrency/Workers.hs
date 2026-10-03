module Kenshou.Suite.Runtime.Concurrency.Workers (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario, faultText)
import Kenshou.Suite.Runtime.Knobs (runtimeKnobName)
import Kenshou.Suite.Runtime.Roles (longRunningRoles)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), killAndRestart)

scenarios :: [Scenario]
scenarios = [sigkillRole]

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
        knownDefect = Nothing
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
