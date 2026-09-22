module Kenshou.Telemetry.Detect
  ( FindingStatus (..),
    FindingSeverity (..),
    Finding (..),
    pipelineFindings,
    queueGrowthFinding,
    endpointFinding,
    handlerFinding,
    continuityFindings,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Telemetry.Compose (HandlerStatsSnapshot (..))
import Kenshou.Telemetry.Continuity (ContinuityResult (..), IsolationResult (..))
import Kenshou.Telemetry.Scrape (EndpointSummary (..))
import Kenshou.Telemetry.Tracing.Pipeline (PipelineSnapshot (..))

data FindingStatus = Fired | Quiet | NotApplicable deriving stock (Eq, Show)

data FindingSeverity = Info | Degraded | Failure deriving stock (Eq, Ord, Show)

data Finding = Finding
  { detector :: Text,
    status :: FindingStatus,
    severity :: FindingSeverity,
    evidence :: Value
  }
  deriving stock (Eq, Show)

instance ToJSON FindingStatus where
  toJSON Fired = toJSON ("fired" :: Text)
  toJSON Quiet = toJSON ("quiet" :: Text)
  toJSON NotApplicable = toJSON ("not-applicable" :: Text)

instance ToJSON FindingSeverity where
  toJSON Info = toJSON ("info" :: Text)
  toJSON Degraded = toJSON ("degraded" :: Text)
  toJSON Failure = toJSON ("failure" :: Text)

instance ToJSON Finding where
  toJSON value = object ["detector" .= value.detector, "status" .= value.status, "severity" .= value.severity, "evidence" .= value.evidence]

pipelineFindings :: Double -> Maybe PipelineSnapshot -> [(Text, Text, Double, Double)] -> [Finding]
pipelineFindings _ Nothing _ =
  [ Finding "span-drop" NotApplicable Info (object []),
    Finding "export-failure" NotApplicable Info (object []),
    Finding "shutdown-blocked" NotApplicable Info (object [])
  ]
pipelineFindings degradedFraction (Just snapshot) providerCalls =
  [ Finding "span-drop" (fired snapshot.spansDropped) dropSeverity (object ["spansEnded" .= snapshot.spansEnded, "spansDropped" .= snapshot.spansDropped, "fraction" .= dropFraction]),
    Finding "export-failure" (fired snapshot.spansExportFailed) (if snapshot.spansExportFailed > 0 then Degraded else Info) (object ["spansExportFailed" .= snapshot.spansExportFailed, "lastError" .= snapshot.lastExportError]),
    Finding "shutdown-blocked" (if null blocked then Quiet else Fired) (if null blocked then Info else Degraded) (object ["calls" .= [object ["call" .= name, "result" .= result, "durationMs" .= duration, "limitMs" .= limit] | (name, result, duration, limit) <- providerCalls], "blocked" .= fmap (\(name, _, _, _) -> name) blocked])
  ]
  where
    dropFraction = fromIntegral snapshot.spansDropped / fromIntegral (max 1 snapshot.spansEnded)
    dropSeverity = if dropFraction > degradedFraction then Degraded else Info
    blocked = filter (\(_, result, duration, limit) -> duration > limit || "timeout" `Text.isInfixOf` Text.toCaseFold result) providerCalls
    fired count = if count > 0 then Fired else Quiet

queueGrowthFinding :: Maybe Int -> [Int] -> Finding
queueGrowthFinding Nothing _ = Finding "queue-growth" NotApplicable Info (object [])
queueGrowthFinding (Just queueLimit) samples =
  Finding
    "queue-growth"
    (if longest > 10 then Fired else Quiet)
    (if longest > 10 then Degraded else Info)
    (object ["queueLimit" .= queueLimit, "threshold" .= threshold, "longestConsecutiveSamples" .= longest, "samples" .= length samples])
  where
    threshold = fromIntegral queueLimit * (0.9 :: Double)
    longest = longestRun ((> threshold) . fromIntegral) samples

longestRun :: (value -> Bool) -> [value] -> Int
longestRun predicate = snd . foldl step (0, 0)
  where
    step (current, best) value =
      let next = if predicate value then current + 1 else 0
       in (next, max best next)

endpointFinding :: [EndpointSummary] -> Finding
endpointFinding [] = Finding "endpoint-failure" NotApplicable Info (object [])
endpointFinding summaries = Finding "endpoint-failure" status severity (object ["failures" .= failures, "attempted" .= attempted, "fraction" .= fraction])
  where
    attempted = sum [summary.scrapes + summary.skippedTicks | summary <- summaries]
    failures = sum [summary.failures + summary.skippedTicks | summary <- summaries]
    fraction :: Double
    fraction = fromIntegral failures / fromIntegral (max 1 attempted)
    status = if fraction > 0.01 then Fired else Quiet
    severity = if status == Fired then Degraded else Info

handlerFinding :: HandlerStatsSnapshot -> Finding
handlerFinding snapshot = Finding "handler-stall" status severity (object ["handler" .= snapshot.name, "calls" .= snapshot.calls, "durationP99Ns" .= snapshot.durationP99Ns, "limitNs" .= (5_000_000 :: Integer)])
  where
    status = if snapshot.durationP99Ns > 5_000_000 then Fired else Quiet
    severity = if status == Fired then Degraded else Info

continuityFindings :: ContinuityResult -> IsolationResult -> [Finding]
continuityFindings continuity isolation =
  [ Finding "trace-discontinuity" (if continuity.violations > 0 then Fired else Quiet) (if continuity.violations > 0 then Failure else Info) (toJSON continuity),
    Finding "context-leak" (if isolation.violations > 0 then Fired else Quiet) (if isolation.violations > 0 then Failure else Info) (toJSON isolation)
  ]
