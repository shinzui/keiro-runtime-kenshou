module Kenshou.Check.Verdict
  ( InvariantClass (..),
    VerdictStatus (..),
    InputRef (..),
    Replay (..),
    RunInfo (..),
    Verdict (..),
    writeVerdict,
    outcomeFromVerdicts,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId, ScenarioId)
import Kenshou.Core.Outcome (Outcome (..))
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath ((</>))

data InvariantClass = Contract | Implementation deriving stock (Eq, Ord, Show)

data VerdictStatus = Held | Violated | NotEvaluated deriving stock (Eq, Ord, Show)

data InputRef = InputRef {path :: !FilePath, sha256 :: !Text} deriving stock (Eq, Show)

data Replay = Replay
  { seed :: !Word,
    size :: !Int,
    shrinkPath :: ![Int],
    command :: !Text
  }
  deriving stock (Eq, Show)

data RunInfo = RunInfo {runId :: !RunId, scenario :: !ScenarioId} deriving stock (Eq, Show)

data Verdict = Verdict
  { checker :: !Text,
    invariant :: !Text,
    cls :: !InvariantClass,
    status :: !VerdictStatus,
    reason :: !(Maybe Text),
    summary :: !Text,
    counts :: !(Map Text Int64),
    parameters :: !Value,
    counterExamples :: ![Value],
    counterExamplesTruncated :: !Bool,
    inputs :: ![InputRef],
    replay :: !(Maybe Replay),
    checkedAt :: !UTCTime,
    durationMillis :: !Int64
  }
  deriving stock (Eq, Show)

writeVerdict :: FilePath -> RunInfo -> Verdict -> IO FilePath
writeVerdict directory runInfo verdict = do
  createDirectoryIfMissing True directory
  let path = directory </> sanitise verdict.checker <> ".json"
      temporary = path <> ".tmp"
  LazyByteString.writeFile temporary (encode (verdictDocument runInfo verdict) <> "\n")
  renameFile temporary path
  pure path
  where
    sanitise = fmap (\character -> if character == '/' then '-' else character) . Text.unpack

outcomeFromVerdicts :: [Verdict] -> Outcome
outcomeFromVerdicts verdicts
  | any isContractViolation verdicts = Failed
  | any isSearchExhausted verdicts = Inconclusive
  | any isContractUnevaluated verdicts = Errored
  | otherwise = Passed
  where
    isContractViolation verdict = verdict.cls == Contract && verdict.status == Violated
    isSearchExhausted verdict = verdict.cls == Contract && verdict.status == NotEvaluated && verdict.reason == Just "search-budget-exhausted"
    isContractUnevaluated verdict = verdict.cls == Contract && verdict.status == NotEvaluated

verdictDocument :: RunInfo -> Verdict -> Value
verdictDocument runInfo verdict =
  object
    [ "schema" .= ("kenshou.verdict/v1" :: Text),
      "runId" .= runInfo.runId,
      "scenario" .= runInfo.scenario,
      "checker" .= verdict.checker,
      "invariant" .= verdict.invariant,
      "class" .= classText verdict.cls,
      "status" .= statusText verdict.status,
      "blocking" .= (verdict.cls == Contract),
      "reason" .= verdict.reason,
      "summary" .= verdict.summary,
      "counts" .= verdict.counts,
      "parameters" .= verdict.parameters,
      "counterExamples" .= verdict.counterExamples,
      "counterExamplesTruncated" .= verdict.counterExamplesTruncated,
      "inputs" .= verdict.inputs,
      "replay" .= verdict.replay,
      "checkedAt" .= verdict.checkedAt,
      "durationMillis" .= verdict.durationMillis
    ]

classText :: InvariantClass -> Text
classText Contract = "contract"
classText Implementation = "implementation"

statusText :: VerdictStatus -> Text
statusText Held = "held"
statusText Violated = "violated"
statusText NotEvaluated = "not-evaluated"

instance ToJSON InputRef where toJSON value = object ["path" .= value.path, "sha256" .= value.sha256]

instance ToJSON Replay where
  toJSON value = object ["seed" .= value.seed, "size" .= value.size, "shrinkPath" .= value.shrinkPath, "command" .= value.command]
