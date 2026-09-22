---
type: Architecture Decision Record
title: Collect layer metrics through the native SQL surface
description: A layer without a metrics endpoint implements telemetry collection by polling its native SQL metrics API on a dedicated connection.
timestamp: 2026-09-22T02:17:39Z
generated:
  by: process:codex
  at: "2026-09-22T02:17:39Z"
docId: ADR-13
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/8-cover-pgmq-hs-in-isolation.md
---

# Collect layer metrics through the native SQL surface

## Context

`pgmq-hs` emits no application metrics and serves no HTTP endpoint. Its current
operator-facing metrics surface is the `pgmq.metrics` SQL function exposed by
`allQueueMetrics`. Treating metrics collection as unsupported would omit the
only real observation cost that PGMQ users pay, while borrowing an endpoint
from a higher runtime layer would break layer isolation.

## Decision

For an isolated layer that has a native queryable metrics surface but no
metrics endpoint, `telemetry.metrics=collect` polls that surface at the
configured scrape interval. The poller uses a dedicated connection and writes
its values and its own query latency to a Kenshou-owned time series.

The scenario workload pool does not lend a connection to the poller, so the
workload's pool-size dimension retains its meaning. Endpoint-serving arms stay
unsupported until the isolated layer itself provides an endpoint.

## Consequences

- Collection exercises the same SQL and table scans an operator would use.
- Metrics overhead can be measured independently of application telemetry.
- Poll failures remain visible in the series instead of silently stopping the
  collector.
- A future native endpoint can add serving arms without changing the meaning
  of the existing collection arm.
