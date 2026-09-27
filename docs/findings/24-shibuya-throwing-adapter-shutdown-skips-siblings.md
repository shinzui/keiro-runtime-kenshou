# Historical Shibuya throwing shutdown skips siblings

Status: reproduced on released `shibuya-core` 0.9.0.3 and fixed on Hackage 0.10.0.0. Owner report: `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-6`.

`shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings` starts three processors, makes the first adapter shutdown throw and requests graceful stop from eight callers. Clean released run `runs/01a0e46f-aa45-723f-a899-d6f2db105bce/run-result.json` reproduced `sibling-shutdown-skipped`. Pinned head passed at `runs/01a0e47c-50e6-7403-acfd-04af75363b8f/run-result.json`; the isolated Hackage 0.10.0.0 CLI passed at `runs/01a0e44f-6085-77a9-8db6-5d165e1201e8/run-result.json`. These run paths are local to this repository.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-3` assigns named-processor shutdown to the application handle. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-2` found the historical sequential adapter loop unprotected by cleanup, and owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-3` reproduced a skipped sibling and incomplete application wait. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests exception-safe ownership and sibling signalling. This is separate from the total-deadline improvement for a forever-blocking shutdown action.
