---
type: Architecture Decision Record
title: Own the shared keiro fixture in kenshou-keiro
description: The kenshou-keiro layer owns the ledger aggregate, workload, and independent oracles consumed by later Keiro runtime verification plans.
timestamp: 2026-09-23T19:55:00Z
generated:
  by: process:codex
  at: "2026-09-23T19:55:00Z"
docId: ADR-15
status: Accepted
date: 2026-09-23
originatingPlan: docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md
---

# Own the shared keiro fixture in kenshou-keiro

## Context

The command, outbox, timer, and assembled-runtime suites need one business
effect whose outcomes can be compared across layers. Separate toy aggregates
would give each suite different event shapes and conservation rules. The
repository also keeps layer packages independent of one another.

## Decision

`kenshou-keiro` owns the shared bank-ledger fixture under
`Kenshou.Suite.Keiro.Fixture.*`. It defines account, transfer, and bonus
aggregates, deterministic workload operations, a pure reference model,
and SQL oracles that read durable state independently of the runtime API.
The fixture exposes stable signatures for the later local plans
`docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md`,
`docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md`,
and `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`.
Changes to those signatures must update the dependent plans and their usage.

One account event represents one target effect. The model checks that balances
remain nonnegative and that the sum of balances changes only for openings,
deposits, withdrawals, bonuses, and transfers still in flight.

## Consequences

- Later suites use the same event identifiers, codecs, and money invariant.
- `kenshou-keiro` is an interface owner even for scenarios registered by
  later plans in the same package.
- A change to event shapes or fold behavior requires coordinated fixture,
  snapshot discriminator, oracle, and dependent-plan updates.
