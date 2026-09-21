module Kenshou.Check.Selftest (bundle) where

import Control.Monad (forM_)
import Data.Aeson (Object, Value (Number), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Kenshou.Check.Fact
import Kenshou.Check.Invariant
import Kenshou.Check.Ledger
import Kenshou.Check.Ledger.Read
import Kenshou.Check.Scenario
import Kenshou.Check.Selftest.BackendKill
import Kenshou.Check.Selftest.KillRestart
import Kenshou.Check.Selftest.ModelReplay
import Kenshou.Check.Selftest.ProxyPartition
import Kenshou.Check.Verdict
import Kenshou.Check.Window
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Layer (Selftest), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario

bundle :: LayerBundle
bundle = LayerBundle Selftest [ledgerScenario, killRestartScenario, backendKillScenario, proxyPartitionScenario, modelReplayScenario] [consumerRole]

ledgerScenario :: Scenario
ledgerScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/check/correctness/ledger-detects-loss-dup-reorder"),
      revision = 1,
      summary = "Proves that rotated evidence ledgers remain intact and sortable in bounded chunks.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = ledgerKnobs,
      dimensions = telemetryOff,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runLedgerScenario
    }

runLedgerScenario :: RunContext -> IO ScenarioReport
runLedgerScenario context = withCheck context \environment -> do
  let factCount = fromIntegral (knobInt context.knobs (name "ledger.facts")) :: Int
      keyCount = fromIntegral (knobInt context.knobs (name "ledger.keys")) :: Int
  writeFacts environment factCount keyCount
  sealLedger environment.ledger
  ledgerSet <- discoverLedgers environment.ledgerDirectory
  windows <- loadWindows ledgerSet
  verdicts <- runCheckers environment ledgerSet (checkerCatalogue windows)
  now <- getCurrentTime
  let nonVacuity = nonVacuityVerdict now
  finishWithVerdicts environment (verdicts <> [nonVacuity])

writeFacts :: CheckEnv -> Int -> Int -> IO ()
writeFacts environment factCount keyCount = do
  forM_ [1 .. factCount] \number -> do
    let key = "key-" <> text (number `mod` keyCount)
        item = "fact-" <> text number
        sequenceNumber = fromIntegral number
        gp = KeyMap.singleton (Key.fromText "gp") (Number (fromIntegral number))
    recordDurable environment.ledger Intent key sequenceNumber item mempty
    record environment.ledger Produced key sequenceNumber item mempty
    recordDurable environment.ledger Observed key sequenceNumber item gp
    recordDurable environment.ledger Effect key sequenceNumber item mempty
    record environment.ledger Terminal key sequenceNumber item mempty
    record environment.ledger Checkpoint "subscription/member" sequenceNumber item mempty
  record environment.ledger Acquired "lease" 1 "lease-a" mempty
  record environment.ledger Acted "lease" 1 "lease-a" mempty
  record environment.ledger Released "lease" 1 "lease-a" mempty

checkerCatalogue :: [DisturbanceWindow] -> [Checker]
checkerCatalogue windows =
  [ noLoss "no-loss" Contract "harness/0",
    duplicatesWithin "duplicates" Contract "harness/0" (DuplicateBudget (Just 50) Nothing) windows,
    perKeyOrder "per-key-order" Contract "harness/0",
    globalOrder "global-order" Contract "harness/0" "gp",
    gaplessPositions "gapless-positions" Implementation,
    exactlyNEffects "exactly-n-effects" Contract 1,
    eventualQuiescence "eventual-quiescence" Contract (Deadline 60000000),
    monotonicCheckpoints "monotonic-checkpoints" Contract,
    disjointOwnership "disjoint-ownership" Contract
  ]

nonVacuityVerdict :: UTCTime -> Verdict
nonVacuityVerdict now =
  let mutations :: [(Text, Checker, [Fact])]
      mutations =
        [ ("drop-observation", noLoss "no-loss" Contract "consumer", [fact Produced "consumer" 1 1 mempty]),
          ("duplicate", duplicatesWithin "duplicates" Contract "consumer" (DuplicateBudget (Just 0) Nothing) [], [fact Observed "consumer" 1 1 mempty, fact Observed "consumer" 2 1 mempty]),
          ("per-key-reorder", perKeyOrder "per-key-order" Contract "consumer", [fact Observed "consumer" 1 2 mempty, fact Observed "consumer" 2 1 mempty]),
          ("global-reorder", globalOrder "global-order" Contract "consumer" "gp", [fact Observed "consumer" 1 1 (gp 2), fact Observed "consumer" 2 2 (gp 1)]),
          ("gap", gaplessPositions "gapless" Implementation, [fact Produced "producer" 1 1 mempty, fact Produced "producer" 2 3 mempty]),
          ("double-effect", exactlyNEffects "effects" Contract 1, [fact Effect "consumer" 1 1 mempty, fact Effect "consumer" 2 1 mempty]),
          ("not-terminal", eventualQuiescence "quiescence" Contract (Deadline 10), [fact Produced "producer" 1 1 mempty]),
          ("checkpoint-regression", monotonicCheckpoints "checkpoint" Contract, [fact Checkpoint "consumer" 1 2 mempty, fact Checkpoint "consumer" 2 1 mempty]),
          ("overlap", disjointOwnership "ownership" Contract, [fact Acquired "owner-a" 1 1 mempty, fact Acquired "owner-b" 2 1 mempty, fact Acted "owner-a" 3 1 mempty])
        ]
      results = [(mutation, evaluateChecker checker facts) | (mutation, checker, facts) <- mutations]
      failed = [mutation | (mutation, checkResult) <- results, checkResult.status /= Violated]
   in Verdict
        "non-vacuity"
        "checker-non-vacuity"
        Contract
        (if null failed then Held else Violated)
        Nothing
        "Every checker rejects its targeted doctored ledger."
        (Map.fromList [("examined", fromIntegral (length results)), ("violations", fromIntegral (length failed))])
        (object ["mutations" .= [object ["mutation" .= mutation, "targetStatus" .= statusText checkResult.status] | (mutation, checkResult) <- results]])
        []
        False
        []
        Nothing
        now
        0
  where
    fact :: FactKind -> Text -> Word64 -> Int64 -> Object -> Fact
    fact kind scope n sequenceNumber attrs = Fact kind "key" sequenceNumber "item" scope (ProcId scope 0 0) n (fromIntegral n) (fromIntegral n * 100) attrs
    gp :: Int64 -> Object
    gp value = KeyMap.singleton (Key.fromText "gp") (Number (fromIntegral value))
    statusText Held = ("held" :: Text)
    statusText Violated = "violated"
    statusText NotEvaluated = "not-evaluated"

ledgerKnobs :: [KnobSpec]
ledgerKnobs =
  [ intKnob "ledger.facts" "Number of facts written" 20000 1000 5000000,
    intKnob "ledger.keys" "Ordering keys" 64 1 100000,
    intKnob "ledger.observers" "Observer count reserved for checker self-tests" 2 1 16,
    intKnob "ledger.sort-run-records" "Facts per external-sort run" 5000 100 1000000,
    intKnob "ledger.max-live-mib" "Maximum expected live heap" 256 32 4096
  ]

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

text :: (Show value) => value -> Text
text = Text.pack . show

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable
