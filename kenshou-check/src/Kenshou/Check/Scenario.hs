module Kenshou.Check.Scenario
  ( CheckEnv (..),
    withCheck,
    finishWithVerdicts,
    deriveSeed,
  )
where

import Data.Aeson (object, toJSON, (.=))
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Check.Fact (ProcId (..))
import Kenshou.Check.Ledger
import Kenshou.Check.Verdict
import Kenshou.Core.Context
import Kenshou.Core.Id (deriveGen, mkSeed, renderRunId)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Scenario (ScenarioReport (..))
import System.Environment (lookupEnv)
import System.FilePath (makeRelative)
import System.Random.SplitMix (nextWord64)
import Text.Read (readMaybe)

data CheckEnv = CheckEnv
  { context :: !RunContext,
    ledger :: !LedgerWriter,
    ledgerDirectory :: !FilePath,
    skewBoundMicros :: !Int64
  }

withCheck :: RunContext -> (CheckEnv -> IO value) -> IO value
withCheck context action = do
  directory <- artifactPath context VerdictsDir "ledger"
  measured <- lookupEnv "KENSHOU_CLOCK_SKEW_BOUND_MICROS"
  let (source, skew) = case measured >>= readMaybe of
        Just value -> (Measured, value)
        Nothing -> (SameHost, 1000)
      config = LedgerConfig directory (ProcId "harness" 0 0) (renderRunId context.runId) (64 * 1024 * 1024) (ClockInfo source skew)
  withLedger config \writer -> action (CheckEnv context writer directory skew)

finishWithVerdicts :: CheckEnv -> [Verdict] -> IO ScenarioReport
finishWithVerdicts environment verdicts = do
  verdictDirectory <- artifactPath environment.context VerdictsDir ""
  let runInfo = RunInfo environment.context.runId environment.context.scenario
  paths <- traverse (writeVerdict verdictDirectory runInfo) verdicts
  traverse_ (\path -> declareMediaType environment.context (makeRelative environment.context.outDir path) "application/json") paths
  putSummary environment.context Verdicts "checks" (toJSON (fmap summaryValue verdicts))
  let outcome = outcomeFromVerdicts verdicts
      failures = [verdict.checker | verdict <- verdicts, verdict.cls == Contract, verdict.status == Violated]
      reason = case outcome of
        Passed -> Nothing
        Failed -> Just "one or more contract invariants were violated"
        Inconclusive -> Just "one or more contract invariants could not be decided"
        Errored -> Just "one or more contract invariants were not evaluated"
        InfrastructureFailure -> Just "correctness evidence could not be collected"
  pure (ScenarioReport outcome reason failures)
  where
    summaryValue verdict =
      object
        [ "checker" .= verdict.checker,
          "invariant" .= verdict.invariant,
          "class" .= showClass verdict.cls,
          "status" .= showStatus verdict.status,
          "violations" .= Map.findWithDefault 0 "violations" verdict.counts
        ]
    showClass Contract = ("contract" :: Text)
    showClass Implementation = "implementation"
    showStatus Held = ("held" :: Text)
    showStatus Violated = "violated"
    showStatus NotEvaluated = "not-evaluated"

deriveSeed :: Word64 -> Text -> Word64
deriveSeed seed label = fst (nextWord64 (deriveGen (either (error . Text.unpack) id (mkSeed seed)) label))
