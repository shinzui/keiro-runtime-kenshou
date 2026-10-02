# Outbox terminal oracle rejects valid single-attempt exhaustion

Status: fixed and verified by the retry-budget boundary matrix.
Owner: this repository's terminal-state oracle. No upstream issue is assigned.

The terminal-state scenario allowed `outbox.max-attempts=1`, but its oracle
expected every transient failure to recover and every dead row to retain the
permanent-poison error. A one-attempt retry budget makes a first transient
failure terminal, so those expectations contradicted the configured workload.

Durable PostgreSQL 18 probe `01a0fdca-607f-7305-86f7-6c96f48cd0e9`, under
`runs/ep13-terminal-one-attempt-before/`, enqueued 20 rows at seed
`4252662818734786`, with transient failure ratio 1 and poison/rejection ratios
0. Every row correctly reached `OutboxDead`, attempt count 1 and error
`synthetic transient failure`; the broker appended nothing. Nevertheless,
`every-row-terminal` and `poison-attempt-ceiling` failed. The sealed probe
passes all 16 schema checks and 17 artifact-integrity checks. It was a dirty
local diagnostic and is not a selected baseline record.

The released implementation in `mori://shinzui/keiro`, tag `keiro-0.17.0.0`,
project-relative path `keiro/src/Keiro/Outbox/Schema.hs`
(artifact-level URI pending), marks a failure dead when the consumed attempt
count is at least the configured maximum. That behavior agrees with the raw
rows; the error was in this suite's interpretation.

Terminal-state revision 3 now accepts transient exhaustion at a one-attempt
budget and verifies its actual error text. The independent replay reconstructs
the same intended outcome from the seed and fault knobs without importing the
scenario or runtime oracle. A fixture regression accepts the saved raw rows
at one attempt, rejects them as premature exhaustion at two attempts, and
rejects replacement of their transient error with a permanent-poison error.

All sixteen repaired durable controls pass under
`runs/ep13-terminal-attempt-boundaries/`: four ordering policies, keyed/keyless
rows and retry budgets one/two, with 20 transient-failure rows in each arm.
The one-attempt arms end dead after one consumed attempt; the two-attempt arms
recover to sent after two consumed attempts. Independent replay agrees with all twelve checks in
every arm; all 256 schema and 272 artifact checks pass. Full verification and
the 79-example CLI suite pass. Earlier sealed verdicts remain unchanged.
