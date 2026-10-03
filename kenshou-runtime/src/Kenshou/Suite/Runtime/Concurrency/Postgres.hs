module Kenshou.Suite.Runtime.Concurrency.Postgres (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario, faultText)
import Kenshou.Suite.Runtime.Knobs (runtimeKnobName)
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), recordWindow)

scenarios :: [Scenario]
scenarios = [backendKill, postmasterRestart]

-- | Terminates the role processes' backends in one context every period.
-- With @fault.target=listener@ only the LISTEN connections that feed push
-- wake-up are terminated, so the fallback poll must keep workflows moving.
backendKill :: Scenario
backendKill =
  faultScenario
    FaultPlan
      { component = "postgres",
        name = "backend-kill",
        summary = "Terminates the role processes' PostgreSQL backends of one context every period while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [],
        extraKnobs = [contextKnob, choice "fault.target" "Which backends are terminated: ordinary pooled ones, LISTEN connections, or both." "all" ["pool", "listener"]],
        inject = \context system -> do
          let target = faultText context.knobs "fault.target"
              prefix = "kenshou-" <> Text.take 8 (renderRunId context.runId) <> "-runtime/"
              selected backend =
                prefix `Text.isPrefixOf` backend.applicationName && case target of
                  "pool" -> not (listener backend)
                  "listener" -> listener backend
                  _ -> True
          passes <- forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
            threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
            recordWindow system "fault/backend-kill" "*" DisturbanceStart
            terminated <- forM (contextEnvironments context system) \postgres -> do
              victims <- filter selected <$> listBackends postgres
              forM_ victims \backend -> (terminateBackends postgres (ByPid backend.pid)).inject
              pure (length victims)
            recordWindow system "fault/backend-kill" "*" DisturbanceEnd
            pure (sum terminated)
          pure (FaultEvidence (length (filter (> 0) passes)) (object ["target" .= target, "terminatedPerPass" .= passes])),
        knownDefect = Nothing,
        databaseProxies = False
      }
  where
    listener backend = "LISTEN" `Text.isPrefixOf` Text.toUpper (Text.stripStart backend.query)

-- | Stops one context's PostgreSQL server for the outage and starts it
-- again; durable commits must survive and the system must recover without
-- operator action.
postmasterRestart :: Scenario
postmasterRestart =
  faultScenario
    FaultPlan
      { component = "postgres",
        name = "postmaster-restart",
        summary = "Stops and restarts one context's PostgreSQL server while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.count", VInt 2), ("fault.outage-seconds", VInt 10), ("fault.period-seconds", VInt 30)],
        extraKnobs = [contextKnob, choice "fault.restart-mode" "How the server is stopped: an immediate shutdown (crash recovery on start) or a fast one." "immediate" ["fast"]],
        inject = \context system -> do
          let mode = if faultText context.knobs "fault.restart-mode" == "fast" then StopFast else StopImmediate
              controls = [control | postgres <- contextEnvironments context system, Just control <- [postgres.control]]
          restarts <-
            if null controls
              then pure []
              else forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
                threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
                recordWindow system "fault/postmaster" "*" DisturbanceStart
                forM_ controls \control -> control.stopServer mode
                threadDelay (faultInt context.knobs "fault.outage-seconds" * 1000000)
                forM_ controls \control -> control.startServer
                recordWindow system "fault/postmaster" "*" DisturbanceEnd
                pure (length controls)
          pure (FaultEvidence (length restarts) (object ["mode" .= show mode, "servers" .= length controls, "restarts" .= restarts])),
        knownDefect = Nothing,
        databaseProxies = False
      }

contextKnob :: KnobSpec
contextKnob = choice "fault.context" "Which context's database is disturbed: the shop (a), the warehouse (b), or both." "b" ["a", "both"]

contextEnvironments :: RunContext -> RunningSystem -> [PostgresEnv]
contextEnvironments context system = case faultText context.knobs "fault.context" of
  "a" -> [system.shopPostgres]
  "both" -> [system.shopPostgres, system.warehousePostgres]
  _ -> [system.warehousePostgres]

choice :: Text -> Text -> Text -> [Text] -> KnobSpec
choice name summary value others = KnobSpec (runtimeKnobName name) summary KnobText (VText value) (OneOf (VText value :| fmap VText others)) []
