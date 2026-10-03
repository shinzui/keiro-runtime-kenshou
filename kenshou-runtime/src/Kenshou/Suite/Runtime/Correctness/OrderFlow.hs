module Kenshou.Suite.Runtime.Correctness.OrderFlow
  ( scenarios,
    predictedMix,
  )
where

import Data.Aeson (object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Process (readChildMessages)
import Kenshou.Check.Scenario (finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (Seed, parseScenarioId)
import Kenshou.Core.Knob (KnobValue (..), knobText)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Driver (DriverReport (..), GeneratedOrder (..), generateOrder)
import Kenshou.Suite.Runtime.Knobs (quiescenceDeadlineFrom, runtimeKnobName, runtimeKnobsWith)
import Kenshou.Suite.Runtime.Oracle (applySabotage, checkCell, sabotageFrom, verifyEndToEnd, withCheckpointMonitor)
import Kenshou.Suite.Runtime.Roles (longRunningRoles, roleNameText)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.System.Schema (StatusCounts (..))
import Kenshou.Suite.Runtime.System.Warehouse (isDiscontinued)
import Kenshou.Suite.Runtime.Topology (QuiescenceReport (..), RunningSystem (..), awaitQuiescence, consumerSessionsEnded, driverReports, processesOf, systemSpecFrom, withReferenceSystem)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [singleOrderRoundtrip, happyPath, mixedOutcomes, completionExpiryRace, duplicateSubmission, hotAccountContention]

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
  | -- | Every order completes; contention on the hot accounts is reported.
    HotAccounts

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

-- | One stream each for the escrow, the merchant and the loyalty pool, at
-- the default rate. Per-stream optimistic concurrency serialises every
-- order through them (finding 66); the scenario keeps that limitation
-- visible. Correctness must still hold once the backlog drains, and the
-- contention is reported as an implementation property.
hotAccountContention :: Scenario
hotAccountContention =
  orderFlowScenario
    "hot-account-contention"
    1
    "Runs 3,600 orders at 20 per second through single escrow, merchant and loyalty-pool streams; I1 to I4 must hold after the backlog drains, and retry exhaustion on the hot streams is reported."
    TierExtended
    [ ("runtime.hot-account-buckets", VInt 1),
      ("runtime.refuse-fraction", VDouble 0),
      ("runtime.expire-fraction", VDouble 0),
      ("runtime.orders", VInt 3600),
      ("runtime.quiescence-deadline-seconds", VInt 900)
    ]
    HotAccounts

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
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
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
  -- Shop dispatch retries whose command exhausted its conflict retries,
  -- per hot stream.
  shopDispatchers <- processesOf system "a-dispatch"
  retryMessages <- concat <$> traverse readChildMessages shopDispatchers
  let exhausted =
        Map.fromListWith
          (+)
          [ (Text.takeWhile (/= '"') (Text.drop 1 (snd (Text.breakOn "\"" problem))), 1 :: Int)
          | WrkCustom "dispatch-retry" payload <- retryMessages,
            Aeson.Object fields <- [payload],
            Just (Aeson.String problem) <- [KeyMap.lookup "problem" fields],
            "RetryExhausted" `Text.isInfixOf` problem
          ]
  let observed = Map.fromList report.shopOrders.byStatus
      expectedOrders = fromIntegral (if config.orders > 0 then config.orders else config.durationSeconds * max 1 config.ratePerSecond) :: Int64
      completedOnly = Map.singleton "completed" expectedOrders
      submissions = [value | Just value <- drivers]
      (mixHeld, predicted) = case expectation of
        AllCompleted -> (observed == completedOnly, toJSON completedOnly)
        DuplicatesRecognised -> (observed == completedOnly, toJSON completedOnly)
        HotAccounts -> (observed == completedOnly, toJSON completedOnly)
        SeedPredicted -> let mix = predictedMix context.seed config in (observed == mix, toJSON mix)
        CompletedOrExpired -> (all (`elem` ["completed", "expired"]) (Map.keys observed) && sum (Map.elems observed) == expectedOrders, toJSON ("completed or expired" :: Text))
      extraCells = case expectation of
        HotAccounts ->
          [(Implementation, "hot-account-retries-absent", Map.null exhausted, object ["retryExhaustedByStream" .= exhausted, "secondsToDrainAfterDrivers" .= report.secondsAfterDrivers, "reference" .= ("finding 66" :: Text)])]
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
    traverse checkCell $
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
