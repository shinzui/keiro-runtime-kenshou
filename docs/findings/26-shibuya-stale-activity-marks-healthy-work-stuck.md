# Historical Shibuya activity timestamp marks healthy work stuck

Status: reproduced on released Shibuya 0.9.0.3 and fixed on Hackage 0.10.0.0. Owner report: `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-7`.

`shibuya/metrics/correctness/ready-not-stuck-under-sustained-load` keeps `Async 8` handlers busy for ten seconds with a three-second stuck threshold. It checks processed counts advance, work remains in flight, and `/health/ready` stays healthy; a truly blocked control must become unready. Clean released run `runs/01a0e479-51a0-7395-9fca-62dc811b2308/run-result.json` reproduced `REV-7-F1`. Pinned head passed at `runs/01a0e485-a321-7215-9a94-e4524e3a142e/run-result.json`; isolated Hackage 0.10.0.0 passed at `runs/01a0e458-8d0f-7366-a182-882199a4e398/run-result.json`. These run paths are local to this repository.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` provides a health endpoint suitable for orchestrator probes. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-7` found that the 0.9.0.3 core retained a timestamp from the first successful burst and reused it for later work, producing false stuck-readiness results. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests a refreshed activity model. The owner bug report is marked fixed in 0.10.0.0.
