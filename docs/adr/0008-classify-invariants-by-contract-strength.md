---
type: Architecture Decision Record
title: Classify invariants by contract strength
description: Kenshou labels every correctness invariant as a public contract or an implementation property and only contract failures block a release.
timestamp: 2026-09-21T16:51:32Z
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

## Consequences

- Release gates track promises made to runtime users rather than incidental
  storage behavior.
- Implementation changes may surface evidence without becoming false release
  blockers.
- Missing workloads, broken selectors, and empty ledgers cannot produce green
  correctness results.
- Scenario authors must state and justify the class when registering an
  invariant.
