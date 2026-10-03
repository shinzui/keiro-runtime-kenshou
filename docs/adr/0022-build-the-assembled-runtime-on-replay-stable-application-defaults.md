---
type: Architecture Decision Record
title: Build the assembled runtime on replay-stable application defaults
description: The assembled-runtime reference system is purpose-built on the pinned cohort, dispatches every command from an at-least-once context under a deterministic identifier, consumes Kafka crash-only and publishes with per-record acknowledgement.
timestamp: 2026-10-03T13:08:57Z
generated:
  by: process:claude-code
  at: "2026-10-03T13:08:57Z"
docId: ADR-22
status: Accepted
date: 2026-10-03
originatingPlan: docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md
---

# Build the assembled runtime on replay-stable application defaults

## Context

The layer suites isolate one runtime component each. The assembled-runtime
suite links them as a service would: two bounded contexts with their own
PostgreSQL servers, joined by Kafka, run as a dozen worker processes. Keiro
has no Kafka dependency and does not supervise processes, so the bridge to
librdkafka, the worker loops and the process supervision are application
code. The suite's verdicts are only meaningful if that application code is
correct by construction; otherwise a defect in the reference system would be
reported as a runtime defect.

Every hop in the runtime is at-least-once. A workflow step, job handler,
timer fire action or inbox handler can run again after a crash and re-decide
its command against state that the first run already changed. The released
Kafka adapter also has scoped defects: fast consecutive `AckRetry` decisions
can skip or reorder records, a batch-enqueue publish path cannot report
broker acknowledgements, and an adapter session can end on a rebalance with
no fault injected (`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`).
Keiro also documents that cancelling a workflow does not cascade to the
awakeables it allocated.

## Decision

The reference system is purpose-built in `kenshou-runtime` on the pinned
cohort. Older example systems serve only as shapes. It reaches the Keiro
fixture and the Kafka environment through one seam module each, as
[ADR-1](0001-layer-packages-never-import-one-another.md) permits for
`kenshou-runtime`.

Every command issued from an at-least-once context uses deduplicated
dispatch (`dispatchDeduplicatedCommand`) or delegated inbox intake
(`delegatedCommand`) under a deterministic event identifier. No business
outcome depends on a command being rejected; any ledger rejection is an
invariant violation.

By default, Kafka consumption is crash-only. A transient database error is
retried in place a bounded number of times, and then the process exits for
supervised restart. A consumer whose adapter session ends without a stop
request sweeps its intake table, starts a fresh session and records each
occurrence against BUG-4. Publishing acknowledges every record with the
broker before reporting the outbox row as sent. The `AckRetry` and
batch-enqueue wirings are exercised only by scenarios that carry their
scoped known defects.

The application cancels pending awakeables owned by terminal workflows,
because Keiro's cancellation does not cascade, and quiescence requires none
to remain.

## Consequences

- An end-to-end failure in the default configuration points at the runtime
  or at a documented limitation, not at an unguarded retry in the reference
  system.
- Known adapter defects stay visible as counted, scoped observations instead
  of turning every outage scenario red for one known reason.
- When the upstream defects are fixed, the `ack-retry` and `batch-enqueue`
  arms are the scenarios that confirm it; the defaults need not change.
- The reference system carries application responsibilities, such as
  awakeable cleanup and intake sweeps, that real services must also carry.
