module Kenshou.Suite.Runtime.Correctness.OrderFlow
  ( scenarios,
    predictedMix,
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Int (Int64)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Check.Scenario (finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (Seed, parseScenarioId)
import Kenshou.Core.Knob (KnobValue (..), knobText)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Driver (DriverReport (..), GeneratedOrder (..), generateOrder)
import Kenshou.Suite.Runtime.Knobs (quiescenceDeadlineFrom, runtimeKnobName, runtimeKnobsWith)
import Kenshou.Suite.Runtime.Oracle (applySabotage, sabotageFrom, verifyEndToEnd, withCheckpointMonitor)
import Kenshou.Suite.Runtime.Roles (longRunningRoles, roleNameText)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.System.Schema (StatusCounts (..))
import Kenshou.Suite.Runtime.System.Warehouse (isDiscontinued)
import Kenshou.Suite.Runtime.Topology (QuiescenceReport (..), RunningSystem (..), awaitQuiescence, consumerSessionsEnded, driverReports, systemSpecFrom, withReferenceSystem)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [singleOrderRoundtrip, happyPath, mixedOutcomes, completionExpiryRace, duplicateSubmission]

-- | What a scenario expects of the terminal mix, beyond I1 to I4.
data MixExpectation
  = -- | Every accepted order completes and ships.
    AllCompleted
  | -- | The observed mix equals the one the seed predicts.
    SeedPredicted
  | -- | Every order ends completed or expired, in any proportion; the race
    -- itself is judged by I1 to I4.
    CompletedOrExpired
  | -- | Every order completes, and every submission beyond the first per
    -- order is recognised as a duplicate.
    DuplicatesRecognised

singleOrderRoundtrip :: Scenario
singleOrderRoundtrip =
  orderFlowScenario
    "single-order-roundtrip"
    1
    "Pushes ten orders through the two-context reference system, one process per role, to Completed and Shipped."
    TierSmoke
    [ ("runtime.processes-per-role", VInt 1),
      ("runtime.orders", VInt 10),
      ("runtime.refuse-fraction", VDouble 0),
      ("runtime.expire-fraction", VDouble 0),
      ("runtime.quiescence-deadline-seconds", VInt 60)
    ]
    AllCompleted

happyPath :: Scenario
happyPath =
  orderFlowScenario
    "happy-path"
    1
    "Runs the default order flow with two processes per role; every order completes and invariants I1 to I4 hold."
    TierStandard
    [ ("runtime.refuse-fraction", VDouble 0),
      ("runtime.expire-fraction", VDouble 0)
    ]
    AllCompleted

mixedOutcomes :: Scenario
mixedOutcomes =
  orderFlowScenario
    "mixed-outcomes"
    1
    "Refuses and expires a seeded fraction of orders; the observed outcome mix equals the seed's prediction and I1 to I4 hold."
    TierStandard
    [ ("runtime.refuse-fraction", VDouble 0.2),
      ("runtime.expire-fraction", VDouble 0.1),
      ("runtime.fulfilment-deadline-seconds", VInt 5)
    ]
    SeedPredicted

completionExpiryRace :: Scenario
completionExpiryRace =
  orderFlowScenario
    "completion-expiry-race"
    1
    "Sets the cooling-off just under the deadline so shipping races expiry for every order; no order is both shipped and released, or neither."
    TierStandard
    [ ("runtime.refuse-fraction", VDouble 0),
      ("runtime.expire-fraction", VDouble 0),
      ("runtime.fulfilment-deadline-seconds", VInt 3),
      ("runtime.cooling-off-ms", VInt 2600),
      ("runtime.orders", VInt 300)
    ]
    CompletedOrExpired

duplicateSubmission :: Scenario
duplicateSubmission =
  orderFlowScenario
    "duplicate-submission"
    1
    "Two drivers submit the same seeded orders three times each; every order is placed exactly once."
    TierStandard
    [ ("runtime.refuse-fraction", VDouble 0),
      ("runtime.expire-fraction", VDouble 0),
      ("runtime.orders", VInt 200),
      ("runtime.driver-partitioning", VText "replicated"),
      ("runtime.submission-rounds", VInt 3)
    ]
    DuplicatesRecognised

orderFlowScenario :: Text -> Int -> Text -> Tier -> [(Text, KnobValue)] -> MixExpectation -> Scenario
orderFlowScenario name revision summary tier overrides expectation =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId ("runtime/order-flow/correctness/" <> name)),
      revision,
      summary,
      tier,
      placement = PlaceEither,
      knobs = runtimeKnobsWith overrides,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = runtimeRequirements,
      knownDefect = Nothing,
      run = runOrderFlow expectation
    }

-- | The terminal mix the seed implies: a discontinued SKU is refused, a slow
-- pick expires, and everything else completes. Computed by folding over
-- order indices, so it never holds all orders in memory.
predictedMix :: Seed -> SystemConfig -> Map Text Int64
predictedMix seed config = foldl' add Map.empty [0 .. total - 1]
  where
    total = if config.orders > 0 then config.orders else config.durationSeconds * max 1 config.ratePerSecond
    add counts index =
      let order = generateOrder seed config index
          outcome
            | isDiscontinued order.sku = "rejected"
            | order.slowPick = "expired"
            | otherwise = "completed"
       in Map.insertWith (+) outcome 1 counts

runOrderFlow :: MixExpectation -> RunContext -> IO ScenarioReport
runOrderFlow expectation context = withReferenceSystem context (systemSpecFrom context) \system -> withCheckpointMonitor system.shop system.warehouse \checkpoints -> do
  let config = system.config
      submissionSeconds = fromIntegral config.orders / fromIntegral (max 1 config.ratePerSecond) :: Double
  report <- awaitQuiescence system (realToFrac (submissionSeconds + 120)) (quiescenceDeadlineFrom context.knobs)
  putSummary context Verdicts "quiescence" (toJSON report)
  sessions <- consumerSessionsEnded system
  putSummary context Verdicts "consumerSessionsEnded" (object [Key.fromText role .= count | (role, count) <- sessions])
  let sabotage = sabotageFrom (knobText context.knobs (runtimeKnobName "oracle.sabotage"))
  applySabotage sabotage system.shop
  putSummary context Verdicts "sabotage" (toJSON (show sabotage))
  monotonic <- checkpoints
  endToEnd <- verifyEndToEnd config system.shop system.warehouse
  let invariants = endToEnd <> [monotonic]
  logs <-
    traverse
      (\(role, index) -> (role,) <$> doesFileExist (context.outDir </> "logs" </> logLabel role index))
      [(role, index) | role <- longRunningRoles, index <- [0 .. max 1 config.processesPerRole - 1]]
  drivers <- driverReports system
  let observed = Map.fromList report.shopOrders.byStatus
      expectedOrders = fromIntegral (if config.orders > 0 then config.orders else config.durationSeconds * max 1 config.ratePerSecond) :: Int64
      completedOnly = Map.singleton "completed" expectedOrders
      submissions = [value | Just value <- drivers]
      (mixHeld, predicted) = case expectation of
        AllCompleted -> (observed == completedOnly, toJSON completedOnly)
        DuplicatesRecognised -> (observed == completedOnly, toJSON completedOnly)
        SeedPredicted -> let mix = predictedMix context.seed config in (observed == mix, toJSON mix)
        CompletedOrExpired -> (all (`elem` ["completed", "expired"]) (Map.keys observed) && sum (Map.elems observed) == expectedOrders, toJSON ("completed or expired" :: Text))
      extraCells = case expectation of
        DuplicatesRecognised ->
          let copies = fromIntegral (length submissions * max 1 config.submissionRounds)
              accepted = sum [value.accepted | value <- submissions]
              duplicates = sum [value.duplicates | value <- submissions]
              failed = sum [value.failed | value <- submissions]
           in [(Contract, "duplicates-recognised", fromIntegral accepted == expectedOrders && fromIntegral duplicates == expectedOrders * (copies - 1) && failed == 0, object ["accepted" .= accepted, "duplicates" .= duplicates, "failed" .= failed, "drivers" .= length submissions, "rounds" .= config.submissionRounds])]
        CompletedOrExpired ->
          -- Whether both sides of the race won at least once depends on timing,
          -- so it is reported as an implementation property.
          [(Implementation, "race-exercised", Map.findWithDefault 0 "completed" observed > 0 && Map.findWithDefault 0 "expired" observed > 0, object ["observed" .= observed])]
        _ -> []
      missingLogs = [role | (role, False) <- logs]
  putSummary context Verdicts "outcomeMix" (object ["observed" .= observed, "predicted" .= predicted])
  cells <-
    traverse cell $
      [ (Contract, "quiescence-reached", report.reached, toJSON report),
        (Contract, "outcome-mix", mixHeld, object ["observed" .= observed, "predicted" .= predicted]),
        (Contract, "worker-logs-present", null missingLogs, toJSON missingLogs)
      ]
        <> extraCells
  finishWithVerdicts system.check (cells <> invariants)

-- | The supervisor names each process log after its role, index and
-- incarnation; the first incarnation is zero.
logLabel :: Text -> Int -> FilePath
logLabel role index = Text.unpack (Text.replace "/" "-" (roleNameText role)) <> "-" <> show index <> ".0.stderr.log"

cell :: (InvariantClass, Text, Bool, Value) -> IO Verdict
cell (invariantClass, name, held, detail) = do
  now <- getCurrentTime
  pure
    Verdict
      { checker = name,
        invariant = name,
        cls = invariantClass,
        status = if held then Held else Violated,
        reason = Nothing,
        summary = if held then "Runtime check held" else "Runtime check failed",
        counts = Map.fromList [("examined", 1), ("violations", if held then 0 else 1)],
        parameters = object [],
        counterExamples = [detail | not held],
        counterExamplesTruncated = False,
        inputs = [],
        replay = Nothing,
        checkedAt = now,
        durationMillis = 0
      }
