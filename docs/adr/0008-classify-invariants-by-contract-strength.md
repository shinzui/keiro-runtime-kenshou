---
type: Architecture Decision Record
title: Classify invariants by contract strength
description: Kenshou labels every correctness invariant as a public contract or an implementation property and only contract failures block a release.
timestamp: 2026-10-03T13:08:57Z
generated:
  by: process:codex
  at: "2026-09-21T16:51:32Z"
docId: ADR-8
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md
---

# Classify invariants by contract strength

## Context

The runtime exposes documented guarantees such as acknowledged items not being
lost, checkpoints moving monotonically, and one owner acting for a lease. The
verification suite also checks useful properties of today's implementation,
such as Kiroku assigning gapless global positions, that upstream documentation
does not promise.

Treating both categories identically would either block releases for harmless
implementation changes or weaken actual public guarantees. A checker can also
appear to pass when it selected no evidence, so an empty check needs an explicit
outcome rather than an implicit success.

## Decision

Every `kenshou.verdict/v1` document records an invariant class of `contract` or
`implementation` and a status of `held`, `violated`, or `not-evaluated`.
Violating a contract invariant makes the run fail. A contract invariant that
cannot be evaluated makes the run errored, except bounded search exhaustion,
which is inconclusive. Implementation-invariant findings remain visible in the
run evidence but do not determine the run outcome.

A checker that selects no relevant facts is `not-evaluated` with reason
`vacuous` unless it explicitly allows empty input. Every checker also has a
targeted non-vacuity test showing that a doctored ledger produces a violation.

A scenario whose verdict is computed from live external state, such as broker
offsets, two databases in the assembled runtime, or a process killed inside a
crash window, also carries a live control recorded as run evidence. An oracle
over live state has a sabotage knob that corrupts the gathered evidence before
judging, and that sabotage run must fail with exactly the oracle's normal
violation label. A crash-window scenario also has a control arm that kills the
process one durable boundary earlier, together with a check that the kill
landed in the intended window, so that a failure implicates the window rather
than the harness.

For Kiroku, acknowledged append durability, strict global order, no subscription
loss, and monotonic subscription checkpoints are contract checks. Contiguous
global positions and the current duplicate limits are implementation checks:
the non-group `$all` publisher can replay up to its 1,000-event batch after a
crash, while category and consumer-group workers use their configured batch
size. A deleted stream can leave legitimate gaps, so no consumer may infer a
contract from contiguous positions. These classifications follow the storage
and subscription behavior of `mori://shinzui/kiroku` and remain visible in
Kiroku scenario verdicts.

## Consequences

- Release gates track promises made to runtime users rather than incidental
  storage behavior.
- Implementation changes may surface evidence without becoming false release
  blockers.
- Missing workloads, broken selectors, and empty ledgers cannot produce green
  correctness results.
- Live controls show that a passing broker, assembled-runtime or crash-window
  verdict could have failed, which a unit test over doctored data cannot show
  for the evidence-gathering path.
- Scenario authors must state and justify the class when registering an
  invariant.
