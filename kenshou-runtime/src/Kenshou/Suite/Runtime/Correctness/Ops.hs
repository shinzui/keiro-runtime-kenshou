module Kenshou.Suite.Runtime.Correctness.Ops (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), defaultRetryPolicy, enqueueToGroup)
import Keiro.PGMQ.Runtime (queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Process (ChildSignal (..))
import Kenshou.Check.Scenario (finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobText)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Runtime.Knobs (runtimeKnobName, runtimeKnobsWith)
import Kenshou.Suite.Runtime.Ops (OpsCall (..), runOps)
import Kenshou.Suite.Runtime.Oracle (checkCell, verdictFor)
import Kenshou.Suite.Runtime.Oracle.Ops (OpsCheck (..), dlqShapeProblems, judgeOpsAgreement, opsChecks)
import Kenshou.Suite.Runtime.Roles (longRunningRoles)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Context (runtimeRequirements)
import Kenshou.Suite.Runtime.System.Schema (ContextName (..), StatusCounts (..), orderStatusCountsTx)
import Kenshou.Suite.Runtime.System.Store (ContextStore, runSql)
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), signalRole, systemSpecFrom, withReferenceSystem)

scenarios :: [Scenario]
scenarios = [keiroOpsCrossCheck]

-- | I8: the operator console agrees with direct SQL on a frozen system.
keiroOpsCrossCheck :: Scenario
keiroOpsCrossCheck =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "runtime/ops/correctness/keiro-ops-cross-check"),
      revision = 1,
      summary = "Freezes the running system with a warehouse outbox backlog, suspended workflows and a pick dead letter, then checks that keiro-ops --json agrees with direct SQL.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        runtimeKnobsWith
          [ ("runtime.refuse-fraction", VDouble 0),
            ("runtime.expire-fraction", VDouble 0),
            ("runtime.cooling-off-ms", VInt 5000)
          ]
          <> [opsSabotageKnob],
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
      run = runCrossCheck
    }

-- | A sabotage control for I8 alone: after the console has answered and
-- before SQL is read, one sent shop outbox row is set back to pending,
-- so the two sides must disagree on the outbox backlog.
opsSabotageKnob :: KnobSpec
opsSabotageKnob =
  KnobSpec
    (runtimeKnobName "ops.sabotage")
    "Change durable state between the keiro-ops reading and the SQL reading so I8 must fail (sabotage control only)."
    KnobText
    (VText "none")
    (OneOf (VText "none" :| [VText "ops-drift"]))
    []

runCrossCheck :: RunContext -> IO ScenarioReport
runCrossCheck context = withReferenceSystem context (systemSpecFrom context) \system -> do
  let sabotage = knobText context.knobs (runtimeKnobName "ops.sabotage")
  -- Let orders reach both contexts before building the backlog.
  traffic <- waitFor 120 (fmap (either (const False) (\counts -> counts.total >= 60)) (runSql system.shop orderStatusCountsTx))
  -- A paused warehouse publisher leaves its outbox rows pending.
  signalRole system Stop "b-publisher"
  injectPoisonPick system.config.warehouseDatabase
  let warehouseCount query = either (const 0) id <$> runSql system.warehouse (scalar query)
  prepared <- waitFor 60 do
    backlog <- warehouseCount "SELECT count(*) FROM keiro.keiro_outbox WHERE status IN ('pending', 'failed')"
    workflows <- warehouseCount "SELECT count(*) FROM keiro.keiro_workflows WHERE status IN ('running', 'suspended')"
    letters <- warehouseCount "SELECT count(*) FROM pgmq.q_pick_dlq"
    pure (backlog > 0 && workflows > 0 && letters > 0)
  -- Freeze every other process so both readings see one state.
  let others = filter (/= "b-publisher") longRunningRoles
  forM_ others (signalRole system Stop)
  threadDelay 1000000
  calls <- forM opsChecks \check -> (check,) <$> runOps system check.context check.arguments
  when (sabotage == "ops-drift") do
    changed <- runSql system.shop (scalar "WITH u AS (UPDATE keiro.keiro_outbox SET status = 'pending' WHERE outbox_id = (SELECT outbox_id FROM keiro.keiro_outbox WHERE status = 'sent' ORDER BY outbox_id LIMIT 1) RETURNING 1) SELECT count(*) FROM u")
    when (changed /= Right 1) (ioError (userError ("ops-drift sabotage changed no outbox row: " <> show changed)))
  compared <- forM calls \(check, call) -> do
    stored <- either (\problem -> ioError (userError ("SQL facts for " <> Text.unpack check.name <> ": " <> show problem))) pure =<< runSql (storeOf system check.context) check.facts
    let reported = call.output >>= check.extract
    pure (check, call, reported, stored)
  forM_ ("b-publisher" : others) (signalRole system Cont)
  let agreement = foldMap (\(check, _, reported, stored) -> judgeOpsAgreement check.name check.context reported stored) compared
      factsOf name ctx = concat [stored | (check, _, _, stored) <- compared, check.name == name, check.context == ctx]
      dlqShape = concat [either (const []) dlqShapeProblems call.output | (check, call, _, _) <- compared, check.name == "pick-dead-letters"]
      backlog = sum [read (Text.unpack fact) :: Int64 | fact <- factsOf "outbox-backlog" Warehouse]
      exercised =
        [ ("warehouse-outbox-backlog", backlog),
          ("warehouse-unfinished-workflows", fromIntegral (length (factsOf "workflows-unfinished" Warehouse))),
          ("pick-dead-letters", fromIntegral (length (factsOf "pick-dead-letters" Warehouse))),
          ("owned-shop-buckets", fromIntegral (length [() | fact <- factsOf "shard-status" Shop, "bucket/" `Text.isPrefixOf` fact, not ("/unowned" `Text.isSuffixOf` fact)])),
          ("owned-warehouse-buckets", fromIntegral (length [() | fact <- factsOf "shard-status" Warehouse, "bucket/" `Text.isPrefixOf` fact, not ("/unowned" `Text.isSuffixOf` fact)])),
          ("shop-checkpoints", fromIntegral (length [() | fact <- factsOf "subscription-checkpoints" Shop, "checkpoint/" `Text.isPrefixOf` fact])),
          ("warehouse-checkpoints", fromIntegral (length [() | fact <- factsOf "subscription-checkpoints" Warehouse, "checkpoint/" `Text.isPrefixOf` fact]))
        ]
  putSummary context Verdicts "keiroOps" (toJSON [object ["check" .= check.name, "context" .= show check.context, "arguments" .= call.arguments, "exitCode" .= call.exitCode, "file" .= call.file, "facts" .= length stored] | (check, call, _, stored) <- compared])
  putSummary context Verdicts "frozenState" (object [name .= count | (name, count) <- exercised])
  putSummary context Verdicts "sabotage" (toJSON sabotage)
  i8 <- verdictFor "ops-cross-check" "keiro-ops --json agrees with direct SQL for outbox and inbox backlogs, unfinished workflows, stuck timers, shard status, subscription checkpoints and the pick dead-letter queue." agreement
  cells <-
    traverse
      checkCell
      [ (Contract, "frozen-state-exercised", traffic && prepared && all ((> 0) . snd) exercised, object ["trafficObserved" .= traffic, "statePrepared" .= prepared, "counts" .= object [name .= count | (name, count) <- exercised]]),
        (Implementation, "ops-json-machine-shaped", null dlqShape, object ["field" .= ("pgmq dlq read: dlq_message_id" :: Text), "renderedAs" .= take 5 dlqShape])
      ]
  finishWithVerdicts system.check (i8 {parameters = object ["checks" .= length compared, "opsVersion" .= ("keiro-ops 0.17.0.0" :: Text)]} : cells)

storeOf :: RunningSystem -> ContextName -> ContextStore
storeOf system = \case
  Shop -> system.shop
  Warehouse -> system.warehouse

-- | Enqueue a pick job whose payload the pick codec rejects; keiro-pgmq
-- dead-letters it as an invalid payload. Its own FIFO group keeps it from
-- blocking any SKU.
injectPoisonPick :: Text -> IO ()
injectPoisonPick database = withJobRuntime database Nothing \jobs -> do
  let poison = Job "pick" (queueRef "pick") aesonJobCodec FifoHeads defaultRetryPolicy :: Job Value
  result <- runJobEff jobs (enqueueToGroup poison "kenshou-poison" (object ["poison" .= True]))
  either (\problem -> ioError (userError ("poison pick enqueue failed: " <> show problem))) (const (pure ())) result

waitFor :: Double -> IO Bool -> IO Bool
waitFor seconds condition = do
  started <- getCurrentTime
  let loop = do
        held <- condition
        now <- getCurrentTime
        if held
          then pure True
          else
            if realToFrac (diffUTCTime now started) > seconds
              then pure False
              else threadDelay 250000 >> loop
  loop

scalar :: Text -> Tx.Transaction Int64
scalar query = Tx.statement () (Statement.preparable query Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))
