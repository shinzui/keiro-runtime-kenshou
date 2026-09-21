---
type: Architecture Decision Record
title: Scenarios use provisioned databases and one migration ledger
description: Scenarios receive database handles from the harness; the environment composes Kiroku, Keiro, and PGMQ migrations through one pg-migrate ledger per database.
timestamp: 2026-09-21T05:01:00Z
generated:
  by: process:codex
  at: "2026-09-21T05:01:00Z"
docId: ADR-4
status: Accepted
date: 2026-09-20
originatingPlan: docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md
---

# Scenarios use provisioned databases and one migration ledger

## Context

Database setup is itself part of the experiment. PostgreSQL major version,
durability, required schemas, reset behavior, and server control affect both
correctness and performance. A scenario that starts its own server or runs a
component-specific migration helper can silently diverge from its effective run
specification and can create multiple migration histories in one database.

Kiroku, Keiro, and PGMQ publish migration components for
`mori://shinzui/pg-migrate`. Keiro depends on Kiroku, so applying their plans
independently is especially prone to order and ledger mistakes.

## Decision

Scenarios never open, initialize, migrate, or tear down their declared database
environment. They declare `PostgresRequirement` values and obtain a
`PostgresEnv` from `RunContext`. The harness owns the private server or external
database lifecycle, configuration checks, template cloning, connection strings,
snapshots, server control, logging, and teardown.

All requested schema components are composed into one ordered `pg-migrate`
plan. Keiro implies Kiroku; components are ordered Kiroku, Keiro, then PGMQ.
The composed plan is applied once to the template database and therefore uses
one `pgmigrate` ledger per database. Run and case databases are cloned only
after migration connections have closed.

Each run receives its own PostgreSQL server in ephemeral mode. Template cloning
may share that server within the run, but servers are never shared between
runs. A scenario requiring crash or restart control cannot use an external
server.

## Consequences

- Dimensions and fingerprints describe the database the scenario actually used.
- Every schema in a database has one ordered, inspectable migration history.
- Fault and crash scenarios use a consistent server-control boundary.
- Scenarios remain portable between local ephemeral runs and validated external
  environments without carrying provisioning code.
- Environment setup failures are infrastructure failures, not scenario failures.
