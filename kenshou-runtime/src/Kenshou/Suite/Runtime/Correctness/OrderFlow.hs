module Kenshou.Suite.Runtime.Correctness.OrderFlow (scenarios) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Check.Scenario (finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobValue (..))
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Knobs (quiescenceDeadlineFrom, runtimeKnobsWith)
import Kenshou.Suite.Runtime.Roles (longRunningRoles, roleNameText)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.System.Schema (StatusCounts (..))
import Kenshou.Suite.Runtime.Topology (QuiescenceReport (..), RunningSystem (..), awaitQuiescence, consumerSessionsEnded, systemSpecFrom, withReferenceSystem)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [singleOrderRoundtrip]

singleOrderRoundtrip :: Scenario
singleOrderRoundtrip =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "runtime/order-flow/correctness/single-order-roundtrip"),
      revision = 1,
      summary = "Pushes ten orders through the two-context reference system, one process per role, to Completed and Shipped.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        runtimeKnobsWith
          [ ("runtime.processes-per-role", VInt 1),
            ("runtime.orders", VInt 10),
            ("runtime.refuse-fraction", VDouble 0),
            ("runtime.expire-fraction", VDouble 0),
            ("runtime.quiescence-deadline-seconds", VInt 60)
          ],
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
      run = runSingleOrderRoundtrip
    }

runSingleOrderRoundtrip :: RunContext -> IO ScenarioReport
runSingleOrderRoundtrip context = withReferenceSystem context (systemSpecFrom context) \system -> do
  let config = system.config
      submissionSeconds = fromIntegral config.orders / fromIntegral (max 1 config.ratePerSecond) :: Double
  report <- awaitQuiescence system (realToFrac (submissionSeconds + 120)) (quiescenceDeadlineFrom context.knobs)
  putSummary context Verdicts "quiescence" (toJSON report)
  sessions <- consumerSessionsEnded system
  putSummary context Verdicts "consumerSessionsEnded" (object [Key.fromText role .= count | (role, count) <- sessions])
  logs <-
    traverse
      (\(role, index) -> (role,) <$> doesFileExist (context.outDir </> "logs" </> logLabel role index))
      [(role, index) | role <- longRunningRoles, index <- [0 .. max 1 config.processesPerRole - 1]]
  let expected = fromIntegral config.orders :: Int64
      statusCount counts status = Map.findWithDefault 0 status (Map.fromList counts.byStatus)
      missingLogs = [role | (role, False) <- logs]
  putSummary context Verdicts "orderFlow" $
    object
      [ "expectedOrders" .= expected,
        "completed" .= statusCount report.shopOrders "completed",
        "shipped" .= statusCount report.warehouseFulfilments "shipped",
        "missingLogs" .= missingLogs
      ]
  recordCells
    system
    [ ("quiescence-reached", report.reached, toJSON report),
      ("orders-completed", statusCount report.shopOrders "completed" == expected && report.shopOrders.total == expected, toJSON report.shopOrders.byStatus),
      ("fulfilments-shipped", statusCount report.warehouseFulfilments "shipped" == expected && report.warehouseFulfilments.total == expected, toJSON report.warehouseFulfilments.byStatus),
      ("single-terminal-event", report.shopOrders.multipleTerminals == 0 && report.warehouseFulfilments.multipleTerminals == 0, object ["shop" .= report.shopOrders.multipleTerminals, "warehouse" .= report.warehouseFulfilments.multipleTerminals]),
      ("worker-logs-present", null missingLogs, toJSON missingLogs)
    ]

-- | The supervisor names each process log after its role, index and
-- incarnation; the first incarnation is zero.
logLabel :: Text -> Int -> FilePath
logLabel role index = Text.unpack (Text.replace "/" "-" (roleNameText role)) <> "-" <> show index <> ".0.stderr.log"

recordCells :: RunningSystem -> [(Text, Bool, Value)] -> IO ScenarioReport
recordCells system cells = do
  now <- getCurrentTime
  let verdict (name, held, detail) =
        Verdict
          { checker = "runtime-" <> name,
            invariant = name,
            cls = Contract,
            status = if held then Held else Violated,
            reason = Nothing,
            summary = if held then "Runtime invariant held" else "Runtime invariant failed",
            counts = Map.fromList [("examined", 1), ("violations", if held then 0 else 1)],
            parameters = object [],
            counterExamples = [detail | not held],
            counterExamplesTruncated = False,
            inputs = [],
            replay = Nothing,
            checkedAt = now,
            durationMillis = 0
          }
  finishWithVerdicts system.check (map verdict cells)
