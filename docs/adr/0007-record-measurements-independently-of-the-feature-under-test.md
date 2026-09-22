---
type: Architecture Decision Record
title: Record measurements independently of the feature under test
description: The measurement toolkit records latency, load, runtime, process, host, and database evidence without depending on application telemetry paths being tested.
timestamp: 2026-09-21T16:14:01Z
generated:
  by: process:codex
  at: "2026-09-21T16:14:01Z"
docId: ADR-7
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md
---

# Record measurements independently of the feature under test

## Context

Later verification plans compare tracing and metrics enabled and disabled. If
the harness obtains its latency, progress, or resource measurements through the
application metrics endpoint, the disabled arm becomes unobservable and the
measurement channel changes with the feature under test.

The previous GCP load harness derived throughput from the application metrics
endpoint. That made a metrics-off control arm impossible and allowed endpoint
failure to remove the evidence needed to judge the run. This decision follows
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-5`, which treats controlled workload
evidence as authoritative and historical telemetry as supporting evidence.

The same problem applies to PostgreSQL pool behavior: a sampler that borrows a
connection from the pool being measured can create or hide pool starvation.

## Decision

`kenshou-measure` owns a separate evidence channel. Operations record monotonic
intended-start and service timestamps directly into bounded histograms and raw
sample files. Load progress, GHC RTS state, operating-system process and host
state, and PostgreSQL statistics are written as run-directory series. The
PostgreSQL sampler uses its own connection named `kenshou-sampler` and excludes
that connection from activity evidence.

Application tracing and metrics may add observations through toolkit extension
points, but the core recorder, health gates, summary, and verdict do not depend
on those features. Helpers such as the OTLP sink and metrics scraper run in
separate processes when their work would perturb the measured process. No
benchmark verdict reads latency, throughput, or resource use from a tracer,
meter, or endpoint under test. Every emitted file is declared to the kernel and
sealed into the run manifest described by
[ADR-3](0003-kenshou-owns-the-runtime-verification-protocol.md).

## Consequences

- Telemetry-off arms remain measurable and comparable.
- Measurement remains available when the application endpoint is stalled or
  incorrect.
- The sampler has observable overhead of its own, which health gates report as
  sampler overrun or recorder back-pressure.
- Telemetry-specific plans may extend the evidence, but cannot replace this
  independent channel as the source of benchmark verdicts.
