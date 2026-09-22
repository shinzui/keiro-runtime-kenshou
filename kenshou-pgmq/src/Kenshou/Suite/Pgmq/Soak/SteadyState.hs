module Kenshou.Suite.Pgmq.Soak.SteadyState (SoakProfile (..), mkSteadyState, scenarios) where

import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

data SoakProfile = FullSoak | ReducedSoak deriving stock (Eq, Ord, Show)

mkSteadyState :: SoakProfile -> Scenario
mkSteadyState FullSoak = pgmqScenario (soak "pgmq/queue/soak/steady-state" "Runs a four-hour steady-state queue workload with leak and bloat verdicts." TierSoak PlaceCell)
mkSteadyState ReducedSoak = pgmqScenario (soak "pgmq/queue/soak/steady-state-reduced" "Runs the local reduced steady-state workload with the same verdicts." TierExtended PlaceEither)

scenarios :: [Scenario]
scenarios = [mkSteadyState FullSoak, mkSteadyState ReducedSoak]
