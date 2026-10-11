module Kenshou.Remote.Perf.Conditions (validateCellConditions, validateCellObservations, validateHealthPolicy) where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Perf.Request (strictObject)

data Sample = Sample {at :: UTCTime, total :: Integer, idle :: Integer, steal :: Integer, disk :: Double}

-- Canonical algorithm: mori://shinzui/load-testing-infra, project-relative
-- nixos/pkgs/cell-agent/src/src/health.rs and runner.rs (artifact URIs pending).
-- The immutable execution interval supplies the actual payload start; nested
-- runtime timestamps and mutable status timestamps cannot substitute for it.
validateCellObservations :: RunId -> Text -> Value -> Value -> Value -> [(Text, Text, Text, Value)] -> Either Text ()
validateCellObservations runId agentVersion policy health interval windows = either (Left . Text.pack) Right do
  let roles = [role | (role, _, _, _) <- windows]
      machines = [machine | (_, machine, _, _) <- windows]
  unless (sort roles `elem` [sort ["driver", "postgres", "monitoring"], sort ["driver", "postgres", "monitoring", "broker"]] && nub machines == machines) (Left "raw observation role coverage is missing or duplicated")
  parseEither replay interval
  where
    replay = withObject "execution window" \v -> do
      strictObject ["schema", "runId", "resetStarted", "runStarted", "runFinished"] v
      schema <- v .: "schema"
      identifier <- v .: "runId"
      resetStarted <- v .: "resetStarted"
      started <- v .: "runStarted"
      finished <- v .: "runFinished"
      unless (schema == ("cell.execution-window/v1" :: Text) && identifier == runId && resetStarted <= addUTCTime (-10) started && started < finished) (fail "invalid sealed execution interval")
      (healthStart, healthEnd, gates) <- withObject "health report" (\h -> (,,) <$> h .: "windowStart" <*> h .: "windowEnd" <*> h .: "gates") health
      unless (healthStart == resetStarted && healthEnd == finished) (fail "health and execution intervals differ")
      limits <- healthLimits policy
      mapM_ (window resetStarted started finished limits gates) windows
    window resetStarted started finished (busyLimit, stealLimit, startLimit, runLimit) gates (role, machine, image, document) =
      withObject
        "raw machine observations"
        ( \v -> do
            strictObject ["schema", "machine", "image", "agentVersion", "systemClosure", "from", "to", "samples", "maintenanceEvents", "samplingErrors"] v
            schema <- v .: "schema"
            actualMachine <- v .: "machine"
            actualImage <- v .: "image"
            actualVersion <- v .: "agentVersion"
            closure <- v .: "systemClosure"
            from <- v .: "from"
            to <- v .: "to"
            maintenance <- v .: "maintenanceEvents" :: Parser [Value]
            errors <- v .: "samplingErrors" :: Parser [Value]
            unless (schema == ("cell.observations/v1" :: Text) && actualMachine == machine && actualImage == image && actualVersion == agentVersion && "/nix/store/" `Text.isPrefixOf` closure && Text.length closure > 11 && abs (diffUTCTime from resetStarted) <= 0.001 && abs (diffUTCTime to finished) <= 0.001 && null maintenance && null errors) (fail "raw machine identity, window, maintenance or sampling errors invalidate the trial")
            samples <- v .: "samples" >>= traverse sample
            unless (not (null samples) && all (\s -> s.at <= to) samples && and [a.at < b.at && diffUTCTime b.at a.at <= 2 && a.total < b.total && a.idle <= b.idle && a.steal <= b.steal | (a, b) <- zip samples (drop 1 samples)]) (fail "raw samples are missing, unordered, interrupted or have invalid counters")
            let settle = filter (\s -> s.at >= addUTCTime (-10) started && s.at <= started) samples
                running = filter (\s -> s.at >= started && s.at <= finished) samples
            (firstSettle, lastSettle) <- endpoints settle
            (firstRun, lastRun) <- endpoints running
            unless (diffUTCTime lastSettle.at firstSettle.at >= 8 && diffUTCTime firstRun.at started <= 2 && diffUTCTime finished lastRun.at <= 2) (fail "raw settle or run sample coverage is incomplete")
            busy <- fraction True firstSettle lastSettle
            steals <- traverse (\(prior, latest) -> fraction False (rolling prior latest) latest) [(take i running, latest) | (i, latest) <- zip [1 ..] (drop 1 running)]
            let settleBusy = if role `elem` ["monitoring", "broker"] then 0 else busy
                runSteal = if role == "monitoring" then 0 else maximum (0 : steals)
                startFree = firstRun.disk
                runFree = minimum (map (.disk) running)
            unless (settleBusy <= busyLimit && runSteal <= stealLimit && startFree >= startLimit && runFree >= runLimit) (fail "raw observations violate the frozen health policy")
            checkGate gates machine "background-load" (object ["settleCpuPercent" .= settleBusy, "runStealCpuPercent" .= runSteal]) (object ["settleCpuMaxPercent" .= busyLimit, "runStealCpuMaxPercent" .= stealLimit]) finished
            checkGate gates machine "storage-pressure" (object ["startFreePercent" .= startFree, "runFreePercent" .= runFree, "outputExceeded" .= False]) (object ["startFreeMinPercent" .= startLimit, "runFreeMinPercent" .= runLimit, "outputExceeded" .= False]) finished
        )
        document
    sample = withObject "health sample" \v -> do
      strictObject ["at", "cpuTotalTicks", "cpuIdleTicks", "cpuStealTicks", "diskFreePercent"] v
      value <- Sample <$> v .: "at" <*> v .: "cpuTotalTicks" <*> v .: "cpuIdleTicks" <*> v .: "cpuStealTicks" <*> v .: "diskFreePercent"
      unless (value.total >= 0 && value.idle >= 0 && value.steal >= 0 && value.idle + value.steal <= value.total && validPercent value.disk) (fail "invalid health counters or disk percentage")
      pure value
    endpoints [] = fail "missing health samples"
    endpoints (first : rest) = pure (first, foldl (\_ next -> next) first rest)
    rolling prior latest = case reverse (filter (\s -> diffUTCTime latest.at s.at >= 30) prior) of
      first : _ -> first
      [] -> case prior of first : _ -> first; [] -> latest
    fraction countIdle first latest = do
      let total = latest.total - first.total
          counter = if countIdle then latest.idle - first.idle else latest.steal - first.steal
      unless (total > 0 && counter >= 0 && counter <= total) (fail "CPU counters did not advance consistently")
      pure (100 * fromIntegral (if countIdle then total - counter else counter) / fromIntegral total :: Double)
    checkGate :: [Value] -> Text -> Text -> Value -> Value -> UTCTime -> Parser ()
    checkGate gates machine name observed threshold finished = do
      matching <- filter (\(m, n, _, _, _) -> m == machine && n == name) <$> traverse (withObject "gate" \v -> (,,,,) <$> v .: "machine" <*> v .: "name" <*> v .: "observed" <*> v .: "threshold" <*> v .: "at") gates
      case matching of
        [(_, _, actual, actualThreshold, at)] | near actual observed && actualThreshold == threshold && at == finished -> pure ()
        _ -> fail "reported health gate differs from raw observations or frozen policy"
    near (Number a) (Number b) = abs (realToFrac a - realToFrac b :: Double) <= 0.000001
    near (Object a) (Object b) = a == b || (length a == length b && and [maybe False (near value) (KeyMap.lookup key b) | (key, value) <- KeyMap.toList a])
    near a b = a == b

validateHealthPolicy :: Value -> Either Text ()
validateHealthPolicy = either (Left . Text.pack) (const (Right ())) . parseEither healthLimits

healthLimits :: Value -> Parser (Double, Double, Double, Double)
healthLimits = withObject "cell policy" \v -> do
  schema <- v .: "schema"
  unless (schema == ("cell.policy/v1" :: Text)) (fail "unsupported cell health policy")
  limits <- v .: "health" >>= withObject "health limits" (\h -> (,,,) <$> h .: "settleCpuMaxPercent" <*> h .: "runStealCpuMaxPercent" <*> h .: "startFreeDiskMinPercent" <*> h .: "runFreeDiskMinPercent")
  let (a, b, c, d) = limits
  unless (all validPercent [a, b, c, d]) (fail "invalid frozen health thresholds")
  pure limits

validPercent :: Double -> Bool
validPercent value = not (isNaN value || isInfinite value) && value >= 0 && value <= 100

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
