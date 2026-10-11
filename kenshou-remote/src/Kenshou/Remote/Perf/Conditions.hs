module Kenshou.Remote.Perf.Conditions (validateCellConditions) where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId)

-- Canonical owner: mori://shinzui/load-testing-infra, artifact URI pending;
-- project-relative nixos/pkgs/cell-agent/src/src/health.rs. Check the reported
-- observations against their thresholds, rather than trusting passed alone.
validateCellConditions :: RunId -> Text -> [Text] -> Value -> Value -> Either Text ()
validateCellConditions runId cell machines health reset = either (Left . Text.pack) Right do
  parseEither healthDocument health
  parseEither resetDocument reset
  where
    names = ["host-maintenance", "background-load", "storage-pressure", "incomplete-reset", "version-mismatch"]
    healthDocument = withObject "cell health" \v -> do
      schema <- v .: "schema"
      identifier <- v .: "runId"
      passed <- v .: "passed"
      start <- v .: "windowStart" :: Parser UTCTime
      end <- v .: "windowEnd" :: Parser UTCTime
      unless (schema == ("cell.health/v1" :: Text) && identifier == runId && passed && start <= end && not (null machines)) (fail "cell health identity, window or outcome is invalid")
      gates <- v .: "gates" >>= traverse (gate start end)
      unless (sort gates == sort [(machine, name) | machine <- machines, name <- names]) (fail "cell health gate coverage is missing, duplicated or unexpected")
    gate start end = withObject "cell health gate" \v -> do
      machine <- v .: "machine"
      name <- v .: "name"
      status <- v .: "status"
      at <- v .: "at" :: Parser UTCTime
      observed <- v .: "observed"
      threshold <- v .: "threshold"
      unless (status == ("ok" :: Text) && at >= start && at <= end) (fail "cell health gate tripped or lies outside its window")
      valid <- case name :: Text of
        "host-maintenance" -> pure (observed == String "NONE" && threshold == String "NONE")
        "incomplete-reset" -> pure (observed == Bool True && threshold == Bool True)
        "version-mismatch" -> pure (observed == Bool True && threshold == Bool True)
        "background-load" -> do
          busy <- percent "settleCpuPercent" observed
          steal <- percent "runStealCpuPercent" observed
          busyLimit <- percent "settleCpuMaxPercent" threshold
          stealLimit <- percent "runStealCpuMaxPercent" threshold
          pure (busy <= busyLimit && steal <= stealLimit)
        "storage-pressure" -> do
          initial <- percent "startFreePercent" observed
          final <- percent "runFreePercent" observed
          initialLimit <- percent "startFreeMinPercent" threshold
          finalLimit <- percent "runFreeMinPercent" threshold
          exceeded <- withObject "disk observation" (.: "outputExceeded") observed
          expectedExceeded <- withObject "disk threshold" (.: "outputExceeded") threshold
          pure (initial >= initialLimit && final >= finalLimit && not exceeded && not expectedExceeded)
        _ -> fail "unknown cell health gate"
      unless valid (fail "cell health observation violates its threshold")
      pure (machine, name)
    percent key = withObject "health percentage" \v -> do
      value <- v .: key :: Parser Double
      unless (not (isNaN value || isInfinite value) && value >= 0 && value <= 100) (fail "invalid cell health percentage")
      pure value
    resetDocument = withObject "cell reset" \v -> do
      schema <- v .: "schema"
      identifier <- v .: "runId"
      owner <- v .: "cell"
      cache <- v .: "cachePolicy"
      verified <- v .: "verified"
      start <- v .: "startedAt" :: Parser UTCTime
      end <- v .: "finishedAt" :: Parser UTCTime
      steps <- v .: "steps" :: Parser [Value]
      unless (schema == ("cell.reset-evidence/v1" :: Text) && identifier == runId && owner == cell && cache == ("cold" :: Text) && verified && start <= end && not (null steps)) (fail "cell reset identity, cache policy, window or verification is invalid")
      mapM_
        ( withObject "reset step" \step -> do
            status <- step .: "status"
            from <- step .: "startedAt" :: Parser UTCTime
            to <- step .: "finishedAt" :: Parser UTCTime
            unless (status == ("ok" :: Text) && from >= start && to <= end && from <= to) (fail "cell reset step failed or lies outside its window")
        )
        steps
