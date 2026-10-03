module Kenshou.Suite.Runtime.Correctness.Telemetry (scenarios) where

import Data.Aeson (object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Check.Scenario (finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobValue (..))
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Knobs (quiescenceDeadlineFrom, runtimeKnobsWith, traceSabotageKnob)
import Kenshou.Suite.Runtime.Oracle (Judgement (..), checkCell, verdictFor, verifyEndToEnd)
import Kenshou.Suite.Runtime.Oracle.Trace
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.System.Store (runSql)
import Kenshou.Suite.Runtime.Telemetry (SpanRecord (..), readSpanRecords)
import Kenshou.Suite.Runtime.Topology (QuiescenceReport (..), RunningSystem (..), awaitQuiescence, stopRoles, systemSpecFrom, withReferenceSystem)

scenarios :: [Scenario]
scenarios = [traceContinuity]

-- | I7 over one hundred orders with the in-memory span probe in every role
-- process. The OTLP arm is not offered: its built-in sink counts spans but
-- keeps none, so nothing could judge their parentage.
traceContinuity :: Scenario
traceContinuity =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "runtime/telemetry/correctness/trace-continuity"),
      revision = 1,
      summary = "Traces one hundred orders through every role process and checks the documented hops: outbox traceparent, Kafka send-to-process parentage in both directions, and the pick job's continuation of its workflow step.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        runtimeKnobsWith
          [ ("runtime.refuse-fraction", VDouble 0),
            ("runtime.expire-fraction", VDouble 0),
            ("runtime.orders", VInt 100),
            ("otel.inmemory.retain", VInt 200000)
          ]
          <> [traceSabotageKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingSdkInMemory :| []) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = runtimeRequirements,
      knownDefect = Nothing,
      run = runTraceContinuity
    }

runTraceContinuity :: RunContext -> IO ScenarioReport
runTraceContinuity context = withReferenceSystem context (systemSpecFrom context) \system -> do
  let config = system.config
      submissionSeconds = fromIntegral config.orders / fromIntegral (max 1 config.ratePerSecond) :: Double
  report <- awaitQuiescence system (realToFrac (submissionSeconds + 120)) (quiescenceDeadlineFrom context.knobs)
  putSummary context Verdicts "quiescence" (toJSON report)
  endToEnd <- verifyEndToEnd config system.shop system.warehouse
  orders <- either (ioError . userError . show) pure =<< runSql system.shop orderIdsTx
  shopOutbox <- either (ioError . userError . show) pure =<< runSql system.shop outboxTraceTx
  warehouseOutbox <- either (ioError . userError . show) pure =<< runSql system.warehouse outboxTraceTx
  -- Every role writes its spans when it stops.
  stopRoles system
  spans <- readSpanRecords context.outDir
  let index = indexSpans spans
      outbox = judgeOutboxTrace "shop" shopOutbox <> judgeOutboxTrace "warehouse" warehouseOutbox
      shopHop = judgeKafkaHop config.shopTopic index spans
      warehouseHop = judgeKafkaHop config.warehouseTopic index spans
      jobHop = judgeJobHop index spans
      journeys = judgeJourneys orders spans
      expected = fromIntegral (length orders)
      (shopRows, _, _) = shopOutbox
      (warehouseRows, _, _) = warehouseOutbox
      exercised =
        [ ("orders", expected),
          ("shop-outbox-rows", shopRows),
          ("warehouse-outbox-rows", warehouseRows),
          ("shop-topic-consumer-spans", shopHop.examined),
          ("warehouse-topic-consumer-spans", warehouseHop.examined),
          ("pick-spans", jobHop.examined)
        ]
      perProcess = Map.fromListWith (+) [(record.process, 1 :: Int) | record <- spans]
  putSummary context Verdicts "spans" (object ["total" .= length spans, "perProcess" .= perProcess, "exercised" .= object [Key.fromText name .= count | (name, count) <- exercised]])
  i7 <- verdictFor "trace-continuity" "Outbox rows carry a traceparent, every Kafka consumer span is a child of its topic's send span in another process, and every pick span continues its enqueuing step's trace." (outbox <> shopHop <> warehouseHop <> jobHop)
  single <- verdictFor "single-trace-journeys" "The command spans of each order's stream and fulfilment stream belong to one trace." journeys
  cells <-
    traverse
      checkCell
      [ (Contract, "quiescence-reached", report.reached, toJSON report),
        ( Contract,
          "trace-continuity-exercised",
          expected > 0 && shopRows >= expected && warehouseRows >= expected && shopHop.examined >= expected && warehouseHop.examined >= expected && jobHop.examined >= expected,
          object [Key.fromText name .= count | (name, count) <- exercised]
        )
      ]
  finishWithVerdicts system.check (i7 : single {cls = Implementation} : cells <> endToEnd)

orderIdsTx :: Tx.Transaction [Text]
orderIdsTx = Tx.statement () (Statement.preparable "SELECT order_id FROM shop.orders ORDER BY order_id" Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text))))
