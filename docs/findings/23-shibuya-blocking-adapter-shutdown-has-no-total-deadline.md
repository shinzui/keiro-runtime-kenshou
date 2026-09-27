# Historical Shibuya shutdown has no total adapter deadline

Status: implementation limitation reproduced on released `shibuya-core` 0.9.0.3 and addressed by the Hackage 0.10.0.0 total-deadline behavior. Owner request: `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6`; owner review: `mori://shinzui/shibuya/okf/reviews/concepts/REV-2`. No owner bug report is warranted by the historical published deadline contract.

`shibuya/core-runner/concurrency/blocking-adapter-shutdown-is-bounded` supplies an adapter whose `shutdown` blocks indefinitely. Clean released run `runs/01a0e46f-b38a-71f6-aa2a-3e26ffafd427/run-result.json` reproduced `REV-2-A1` when `stopAppGracefully` did not return within the scenario's 70-second watchdog. Pinned head passed at `runs/01a0e47c-59da-75c3-a4d7-fb6f2c5ec17f/run-result.json`; the isolated Hackage 0.10.0.0 CLI passed at `runs/01a0e44f-6911-7323-a8ca-31c0b4401207/run-result.json`. These run paths are local to this repository.

Owner REV-2 states that the 0.9.0.3 timeout began only after adapter shutdown actions returned and documented a drain timeout, not a total shutdown deadline. The scenario tests the stronger total-deadline behavior introduced on the remediation line. IR-6 requests that behavior; the historical result is a versioned implementation gap, not evidence that the old published drain deadline was violated.
