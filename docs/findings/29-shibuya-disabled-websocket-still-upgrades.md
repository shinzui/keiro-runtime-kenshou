# Historical Shibuya disabled WebSocket endpoint still upgrades

Status: reproduced on released `shibuya-metrics` 0.9.0.3 and fixed on Hackage 0.10.0.0. Owner report: `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-10`.

`shibuya/metrics/correctness/websocket-flag-gates-upgrades` starts the metrics server with `enableWebSocket=False` and attempts a real `/ws` upgrade. Clean released run `runs/01a0e479-e837-745e-94e6-6139cfc9d33e/run-result.json` reproduced `REV-9-F2`: the disabled endpoint still accepted the upgrade. Pinned head passed at `runs/01a0e486-39a4-7686-aaa5-7e5b4df9d698/run-result.json`; isolated Hackage 0.10.0.0 passed at `runs/01a0e459-1c2e-710e-b961-54f8b32d1701/run-result.json`. These run paths are local to this repository.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` includes endpoint enable flags. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` found that the historical combined application installs the WebSocket upgrade path regardless of the flag. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests the enablement regression. This is an endpoint-gating contract breach.
