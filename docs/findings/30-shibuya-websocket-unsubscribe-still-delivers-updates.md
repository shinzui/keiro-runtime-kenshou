# Historical Shibuya WebSocket unsubscribe still delivers updates

Status: reproduced on released `shibuya-metrics` 0.9.0.3 and fixed on Hackage 0.10.0.0. Owner report: `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-11`.

`shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates` subscribes to all processors, unsubscribes from them, and keeps traffic flowing. Clean released run `runs/01a0e479-ed61-76a8-8264-3b30756e2a90/run-result.json` reproduced `REV-9-F3`: an update still arrived. Pinned head passed at `runs/01a0e486-3ed0-7602-ad22-7eb39dd8cdbc/run-result.json`; isolated Hackage 0.10.0.0 passed at `runs/01a0e459-1f1a-71bb-a8bc-e2126fe483b3/run-result.json`. These run paths are local to this repository.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` provides live WebSocket metrics, and the public `Shibuya.Metrics.Types.Unsubscribe` frame names processors to remove. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` found that historical subscribe-all state was still interpreted as all processors after an unsubscribe. This is a subscription-protocol contract breach.
