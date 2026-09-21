module Kenshou.Diagnose.Render
  ( renderLeakReport,
    renderStallReport,
    renderProfileReport,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Diagnose.Leak
import Kenshou.Diagnose.LockGraph qualified as LockGraph
import Kenshou.Diagnose.Pool (PoolStats (..))
import Kenshou.Diagnose.Profile
import Kenshou.Diagnose.Stall.Types
import Kenshou.Diagnose.Threads (ThreadDump (..), ThreadEntry (..))

renderLeakReport :: LeakReport -> Text
renderLeakReport report = Text.unlines (header : fmap renderProbe report.probes)
  where
    header = "leak verdict: " <> leakVerdictText report.verdict
    renderProbe probe =
      Text.intercalate
        "  "
        [ probe.probe <> "[" <> probe.process <> "]",
          leakVerdictText probe.verdict,
          "slope=" <> maybe "n/a" (\value -> showText value <> " " <> probe.unit <> "/hour") probe.slopePerHour,
          "reason=" <> probe.reason
        ]

renderStallReport :: StallReport -> Text
renderStallReport report =
  Text.unlines
    ( ["stall " <> Text.pack (show report.captureNumber) <> ": " <> stallClassText report.classification]
        <> fmap ("reason: " <>) report.reasons
        <> nonempty "wait graph:" (LockGraph.renderText report.snapshot.graph)
        <> ["thread " <> fromMaybe "<unlabelled>" entry.label <> ": " <> entry.status <> maybe "" (" " <>) entry.blockReason | entry <- report.snapshot.haskellThreads.entries, entry.status == "blocked"]
        <> ["pool " <> pool.name <> ": " <> showText pool.inUse <> "/" <> showText pool.size <> " in use, saturated " <> showText pool.saturatedSeconds <> "s" | pool <- report.snapshot.pools]
    )
  where
    nonempty _ "" = []
    nonempty label value = label : Text.lines value

renderProfileReport :: ProfileReport -> Text
renderProfileReport report =
  Text.unlines
    [ "profile session: " <> Text.pack report.sessionDirectory,
      "mode: " <> Text.pack (show report.mode),
      "event log: " <> showText report.eventlogBytes <> " bytes" <> if report.truncated then " (truncated)" else "",
      "wrapped exit: " <> showText report.exitCode
    ]

leakVerdictText :: LeakVerdict -> Text
leakVerdictText LeakSuspected = "leak-suspected"
leakVerdictText Stable = "stable"
leakVerdictText InsufficientData = "insufficient-data"

showText :: (Show value) => value -> Text
showText = Text.pack . show
