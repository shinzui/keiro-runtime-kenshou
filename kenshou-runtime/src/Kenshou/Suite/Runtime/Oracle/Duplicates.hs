module Kenshou.Suite.Runtime.Oracle.Duplicates
  ( HopAllowance (..),
    hopAllowances,
    Observations,
    collectObservations,
    declaredWindows,
    judgeDuplicates,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger.Read (LedgerSet, foldFacts)
import Kenshou.Check.Window (DisturbanceWindow (..), loadWindows)
import Kenshou.Suite.Runtime.Oracle (Judgement (..))
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..), Timeouts (..), timeoutsFor)

-- I5: a handled delivery seen again on the same hop is a redelivery. It is
-- explained only by a declared window that disturbed that hop (an injected
-- fault, a supervised restart, or a consumer-session resumption): the
-- delivery was first handled before the window ended, extended by the time
-- the hop may take to notice (its lease, visibility timeout or commit
-- interval), and handled again after the window started. A replay from a
-- checkpoint or committed offset is bounded by what was handled before the
-- disturbance, not by how long the replay takes.

-- | Which disturbances explain redeliveries on a hop, and how long after a
-- window a delivery first handled still counts as handled before it.
data HopAllowance = HopAllowance
  { hop :: !Text,
    -- | Roles whose processes deliver on this hop.
    roles :: ![Text],
    extensionMicros :: !Int64
  }
  deriving stock (Eq, Show)

-- | The hops that record observations, with their allowances under the
-- run's lease profile. Five seconds of slack cover restart backoff and
-- polling intervals.
hopAllowances :: SystemConfig -> [HopAllowance]
hopAllowances config =
  [ HopAllowance "dispatch-shop-dispatch" ["a-dispatch"] (seconds (timeouts.shardLeaseSeconds + timeouts.shardRenewSeconds)),
    HopAllowance "dispatch-warehouse-dispatch" ["b-dispatch"] (seconds (timeouts.shardLeaseSeconds + timeouts.shardRenewSeconds)),
    HopAllowance (config.shopTopic <> "-consumer") ["b-consumer"] consumer,
    HopAllowance (config.warehouseTopic <> "-consumer") ["a-consumer"] consumer,
    HopAllowance "pick" ["b-jobs"] (seconds (fromIntegral timeouts.jobVisibilitySeconds)),
    -- A workflow advances in the dispatcher that starts it and in the
    -- resume workers.
    HopAllowance "step-request-pick" ["b-resume", "b-dispatch"] (seconds timeouts.workflowLeaseSeconds),
    HopAllowance "step-ship" ["b-resume", "b-dispatch"] (seconds timeouts.workflowLeaseSeconds)
  ]
  where
    timeouts = timeoutsFor config.ttlProfile
    -- The consumers' session timeout plus the auto-commit interval.
    consumer = seconds 11
    seconds :: Double -> Int64
    seconds value = round ((value + 5) * 1000000)

-- | Observation instants per hop and delivery identity.
type Observations = Map (Text, Text) [Int64]

collectObservations :: LedgerSet -> IO Observations
collectObservations ledgers = foldFacts ledgers Map.empty \observations fact ->
  pure case fact.kind of
    Observed -> Map.insertWith (<>) (hopOf fact, fact.key) [fact.wall] observations
    _ -> observations
  where
    hopOf fact = case KeyMap.lookup "hop" fact.attrs of
      Just (String hop) -> hop
      _ -> fact.id

-- | The windows I5 accepts: injected faults (@fault/…@), supervised restarts,
-- consumer-group start-up and consumer-session resumptions. The supervisor's own signal edges are
-- excluded because a restart changes their target and leaves them open.
declaredWindows :: LedgerSet -> IO [DisturbanceWindow]
declaredWindows ledgers = filter declared <$> loadWindows ledgers
  where
    declared window = "fault/" `Text.isPrefixOf` window.label || window.label `elem` ["restart", "consumer-startup", "consumer-session"]

-- | Every observation after the first of an identity must be explained by a
-- window that disturbed its hop. A window's target is @<role>/<index>@ (or
-- @<hop>/<index>@ for a consumer-session resumption); the target @*@
-- disturbs every hop. An open window lasts to the end of the run. A hop
-- without an allowance is explained only by a window naming it.
judgeDuplicates :: [DisturbanceWindow] -> [HopAllowance] -> Observations -> Judgement
judgeDuplicates windows allowances observations = foldMap judge (Map.toList observations)
  where
    entryFor hop = lookup hop [(entry.hop, entry) | entry <- allowances]
    disturbs hop window =
      let source = fst (Text.breakOnEnd "/" window.target)
          role = if Text.null source then window.target else Text.dropEnd 1 source
       in window.target == "*" || role == hop || maybe False (\entry -> role `elem` entry.roles) (entryFor hop)
    explained hop first instant =
      any
        (\window -> disturbs hop window && instant >= window.start && maybe True (\end -> first <= end + maybe 0 (.extensionMicros) (entryFor hop)) window.end)
        windows
    judge ((hop, identity), instants) = case sort instants of
      first : repeats ->
        let unexplained = [instant | instant <- repeats, not (explained hop first instant)]
         in if null unexplained
              then Judgement (fromIntegral (length instants)) 0 []
              else Judgement (fromIntegral (length instants)) (fromIntegral (length unexplained)) [object ["hop" .= hop, "identity" .= identity, "observations" .= length instants, "unexplainedAtMicros" .= unexplained]]
      [] -> mempty
