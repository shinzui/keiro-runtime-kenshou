# Outbox best-effort fixture propagates same-key failures

Status: fixed and verified by a minimal broker witness, policy-grouping
regressions and the durable terminal-state matrix.
Owner: this repository's synthetic broker and outbox terminal-state scenario.
No upstream runtime bug report is assigned.

A clean sixteen-arm durable PostgreSQL 18 sweep at `39f73ab` varied all four
ordering policies, constant/exponential backoff and zero/seven partition keys,
with 200 rows, batch size 17 and seed `4252662818734786`. Fifteen arms passed.
The best-effort/exponential/seven-key arm
`01a0fdab-5460-70f7-8b21-7106d0ed8273` failed `every-row-terminal` and
`poison-attempt-ceiling`. The sealed original remains under
`runs/ep13-outbox-terminal-controls/`; all 240 schema and 256 artifact checks
pass, including that failed result.

The terminal scenario used the broker's key-ordered callback for `BestEffort`.
That callback reports a failure for later same-key rows after an earlier row
fails, even when their own fault script says to succeed. Keiro's best-effort
finalizer consumes each reported row failure independently. Repeated collateral
failures can therefore consume another row's attempt ceiling or replace a
poison row's expected failure text. The terminal oracle instead predicted
independent per-row fault decisions.

A two-row witness isolates this mismatch without PostgreSQL or Keiro's
publisher. The first row always fails and the second, with the same key, is
healthy. The old callback returns `synthetic permanent failure` followed by
`earlier record of this group failed`, appending zero records; the independent
row-outcome expectation fails. The released implementation was located through
`mori://shinzui/keiro` and read at tag `keiro-0.17.0.0`, project-relative path
`keiro/src/Keiro/Outbox.hs` (artifact-level URI pending): best-effort finalization
groups by row ID, while ordered policies restore skipped attempts. This is a
fixture/oracle mismatch, not evidence of a Keiro defect.

`publishScriptedWithPolicy` now groups callback failures by the selected
ordering policy. Terminal-state revision 2 uses that callback for every policy.
The repaired best-effort witness returns one intended failure and one success,
appending exactly the healthy record. Four regression examples distinguish
same-key, other-key and other-source outcomes for every policy.

The after matrix under `runs/ep13-outbox-terminal-controls-after/` passes all
sixteen arms, all 240 schema checks and all 256 artifact checks. The 54-example
Keiro suite and full `nix develop -c just verify` gate pass. These functional
controls establish no performance comparison; older sealed results are retained.
