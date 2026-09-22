---
type: Architecture Decision Record
title: Judge message leases on the database clock
description: PGMQ lease and due-time verdicts compare timestamps produced by PostgreSQL rather than clocks from harness or worker processes.
timestamp: 2026-09-22T02:17:39Z
generated:
  by: process:codex
  at: "2026-09-22T02:17:39Z"
docId: ADR-12
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/8-cover-pgmq-hs-in-isolation.md
---

# Judge message leases on the database clock

## Context

PGMQ assigns visibility and read timestamps inside PostgreSQL. Concurrency and
crash scenarios observe those values from several operating-system processes,
whose wall clocks can differ from one another and from the database. Comparing
a worker clock with a database timestamp would turn clock skew into an apparent
early redelivery or overlap.

## Decision

Kenshou judges PGMQ visibility, redelivery, and scheduled-delivery boundaries
using only timestamps produced by PostgreSQL. For consecutive leases of one
message, the next `last_read_at` must be no earlier than the previous `vt`,
unless an observed visibility-change operation moved the boundary earlier.
Due-time verdicts likewise compare the database-produced read timestamp with
the due timestamp stored by PostgreSQL.

Harness monotonic clocks may measure elapsed scenario time and enforce safety
timeouts, but they do not decide whether a PGMQ lease was valid.

## Consequences

- Lease verdicts remain sound across worker processes and machines with skewed
  wall clocks.
- Scenario facts must retain PGMQ's `last_read_at`, `vt`, and `read_ct` values.
- A killed worker that did not flush its lease fact can delay later delivery,
  but cannot create a false overlap finding.
- Database-clock correctness and harness-latency measurement remain separate.
