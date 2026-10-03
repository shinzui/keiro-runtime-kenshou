module Kenshou.Suite.Runtime.Concurrency
  ( FaultPlan (..),
    FaultEvidence (..),
    faultScenario,
    faultKnob,
    faultInt,
    faultText,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers)
import Kenshou.Check.Scenario (CheckEnv (..), finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobInt, knobText)
import Kenshou.Core.Knob qualified as Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (KnownDefect, Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Knobs (quiescenceDeadlineFrom, runtimeKnobName, runtimeKnobsWith)
import Kenshou.Suite.Runtime.Oracle (checkCell, verdictFor, verifyEndToEnd, withCheckpointMonitor)
import Kenshou.Suite.Runtime.Oracle.Duplicates (collectObservations, declaredWindows, hopAllowances, judgeDuplicates)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.Topology (QuiescenceReport (..), RunningSystem (..), SystemSpec (..), awaitQuiescence, consumerSessionsEnded, restartsOf, stopRoles, systemSpecFrom, withReferenceSystem)

-- | What a fault schedule reports: how many faults took effect, and the
-- evidence for each. A scenario whose schedule took no effect is errored,
-- never passed.
data FaultEvidence = FaultEvidence
  { applied :: !Int,
    detail :: !Value
  }

-- Placement: a scenario whose fault needs PostgreSQL server control, broker
-- process control or a second proxied broker lane is @local@. A cell
-- offers none of these yet, so routing it there would only report the
-- fault as not applied.

-- | One whole-runtime fault scenario. Every scenario shares 'faultScenario's
-- procedure; the plan supplies only its identity, knobs and schedule.
data FaultPlan = FaultPlan
  { component :: !Text,
    name :: !Text,
    summary :: !Text,
    tier :: !Tier,
    placement :: !Placement,
    overrides :: ![(Text, KnobValue)],
    extraKnobs :: ![KnobSpec],
    -- | Runs the fault schedule during the steady phase and returns once
    -- every fault has been lifted.
    inject :: RunContext -> RunningSystem -> IO FaultEvidence,
    knownDefect :: !(Maybe KnownDefect),
    -- | Route role processes to their databases through proxies.
    databaseProxies :: !Bool
  }

-- | The shared procedure: start the system, warm up, run the schedule while
-- orders flow, let the drivers finish, await quiescence, stop every role,
-- and judge I1 to I6 with the recorded disturbance windows.
faultScenario :: FaultPlan -> Scenario
faultScenario plan =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId ("runtime/" <> plan.component <> "/concurrency/" <> plan.name)),
      revision = 1,
      summary = plan.summary,
      tier = plan.tier,
      placement = plan.placement,
      knobs = fmap override (runtimeKnobsWith [] <> sharedFaultKnobs <> plan.extraKnobs),
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = runtimeRequirements,
      knownDefect = plan.knownDefect,
      run = runFault plan
    }
  where
    defaults = [("runtime.orders", VInt 0), ("runtime.duration-seconds", VInt 180), ("runtime.quiescence-deadline-seconds", VInt 300)]
    -- A plan's overrides win over the shared defaults, for every declared
    -- knob, including the fault knobs.
    override spec = maybe spec (\value -> spec {Knob.def = value}) (lookup spec.name [(runtimeKnobName name, value) | (name, value) <- plan.overrides <> defaults])

sharedFaultKnobs :: [KnobSpec]
sharedFaultKnobs =
  [ faultKnob "fault.warmup-seconds" "Seconds of traffic before the first fault." 30 0 3600,
    faultKnob "fault.period-seconds" "Seconds between faults." 20 1 3600,
    faultKnob "fault.count" "Faults injected." 5 0 1000,
    faultKnob "fault.outage-seconds" "How long an outage lasts." 20 1 3600,
    KnobSpec (runtimeKnobName "oracle.declared-windows") "Judge I5 with the declared disturbance windows; ignore them only as a sabotage control, so every redelivery must fail I5." KnobText (VText "use") (OneOf (VText "use" :| [VText "ignore"])) []
  ]

faultKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
faultKnob name summary value low high = KnobSpec (runtimeKnobName name) summary KnobInt (VInt (fromIntegral value)) (IntRange (fromIntegral low) (fromIntegral high)) []

faultInt :: ResolvedKnobs -> Text -> Int
faultInt knobs name = fromIntegral (knobInt knobs (runtimeKnobName name))

faultText :: ResolvedKnobs -> Text -> Text
faultText knobs name = knobText knobs (runtimeKnobName name)

runFault :: FaultPlan -> RunContext -> IO ScenarioReport
runFault plan context = withReferenceSystem context (systemSpecFrom context) {proxiedDatabases = plan.databaseProxies} \system -> withCheckpointMonitor system.shop system.warehouse \checkpoints -> do
  let config = system.config
      submissionSeconds =
        if config.orders > 0
          then fromIntegral config.orders / fromIntegral (max 1 config.ratePerSecond)
          else fromIntegral config.durationSeconds :: Double
  threadDelay (faultInt context.knobs "fault.warmup-seconds" * 1000000)
  evidence <- plan.inject context system
  putSummary context Verdicts "faults" (object ["applied" .= evidence.applied, "detail" .= evidence.detail])
  report <- awaitQuiescence system (realToFrac (submissionSeconds + 300)) (quiescenceDeadlineFrom context.knobs)
  putSummary context Verdicts "quiescence" (toJSON report)
  sessions <- consumerSessionsEnded system
  putSummary context Verdicts "consumerSessionsEnded" (object [Key.fromText role .= count | (role, count) <- sessions])
  restarts <- restartsOf system
  putSummary context Verdicts "restarts" (toJSON restarts)
  monotonic <- checkpoints
  endToEnd <- verifyEndToEnd config system.shop system.warehouse
  -- Stop every role so that each process's observations are complete.
  stopRoles system
  -- The harness holds its own ledger open for writing until it is sealed.
  sealLedger system.check.ledger
  ledgers <- discoverLedgers system.check.ledgerDirectory
  declared <- declaredWindows ledgers
  let windows = if faultText context.knobs "oracle.declared-windows" == "ignore" then [] else declared
  observations <- collectObservations ledgers
  let redeliveries = Map.fromListWith (+) [(hop, length instants - 1) | ((hop, _), instants) <- Map.toList observations, length instants > 1]
  putSummary context Verdicts "redeliveries" (object ["byHop" .= redeliveries, "windows" .= length declared, "windowsUsed" .= length windows])
  bounded <- verdictFor "duplicates-bounded" "Every redelivery on a hop falls inside a declared fault, restart or consumer-session window extended by the hop's lease or commit interval." (judgeDuplicates windows (hopAllowances config) observations)
  now <- getCurrentTime
  let applied =
        Verdict
          { checker = "fault-took-effect",
            invariant = "fault-took-effect",
            cls = Contract,
            status = if evidence.applied > 0 then Held else NotEvaluated,
            reason = if evidence.applied > 0 then Nothing else Just "fault-not-applied",
            summary = "The fault schedule took effect at least once.",
            counts = Map.fromList [("examined", 1), ("violations", 0), ("applied", fromIntegral evidence.applied)],
            parameters = object [],
            counterExamples = [],
            counterExamplesTruncated = False,
            inputs = [],
            replay = Nothing,
            checkedAt = now,
            durationMillis = 0
          }
  quiescence <- checkCell (Contract, "quiescence-reached", report.reached, toJSON report)
  finishWithVerdicts system.check ([applied, quiescence, bounded {parameters = object ["windows" .= length windows, "redeliveries" .= redeliveries]}, monotonic] <> endToEnd)
