---
type: Architecture Decision Record
title: Comparison verdicts require controlled benchmark evidence
description: Performance verdicts come only from paired, interleaved, compatibility-checked, benchmark-grade runs, while historical measurements remain telemetry.
timestamp: 2026-10-11T06:41:03Z
generated:
  by: process:codex
  at: "2026-09-21T16:14:01Z"
docId: ADR-6
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md
---

# Comparison verdicts require controlled benchmark evidence

## Context

Absolute benchmark history combines runtime changes with host drift, compiler
changes, PostgreSQL checkpoints, background work, and durability settings. A
historical movement therefore does not establish that the candidate caused the
movement. This agrees with
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-5`, which treats historical timing
as telemetry and reserves authoritative gates for controlled comparisons.

Small trial counts also make a narrow bootstrap interval unsafe, and a large
relative change near zero may have no practical impact. Runs can only support a
verdict when their workload and environment inputs are compatible.

## Decision

`kenshou compare` accepts paired baseline and candidate trials whose execution
order is interleaved as ABBA or BAAB. All compatibility inputs must be equal
except a non-empty list of varying axes declared by the caller. A run is
benchmark-grade only when it retains full raw samples, uses durable PostgreSQL
settings when applicable, and has no health condition that invalidates its
evidence. In particular, `pg.durability=fsync-off` is exploratory evidence.

Each metric uses the envelope of a deterministic seeded percentile-bootstrap
interval and a Student-t interval. A regression requires the lower bounds of
both an adverse relative ratio and an adverse absolute delta to exceed their
policy limits. Excessive variance, insufficient pairs, checkpoint asymmetry,
soft health observations, non-interleaving, or exploratory evidence produces
an inconclusive verdict. Hard health observations, infrastructure outcomes, or
machine-profile changes produce an infrastructure-failure verdict. These
evidence checks take precedence over statistical regressions.

A bounded performance profile declares required metric names, units, and minimum
steady sample counts. Admission must reconstruct retained histograms from full
raw operation samples and compare the retained summary with recomputed values.
Missing metrics or insufficient samples cannot pass merely because another
metric passed. Corrupt evidence is invalid; incomplete or failed runtime work
remains a blocker rather than a replaceable infrastructure observation.

A profile is uncalibrated until verified sensitivity and turnaround evidence is
bound to its effective workload, policy, toolchain, and machine profile. A catalog
claim alone cannot admit a gating result. Calibration requests may select explicit
uncalibrated profiles, including A/A controls with an empty source diff, and their
results remain non-gating. Deliberate profile scope and whole-change coverage are
separate claims. Count-bound scenario revisions must declare their actual phases
and timeout; unsupported phase declarations are rejected.

A completed cell trial must also retain sealed cold-reset evidence and all five
health gates for every required machine. Reported observations must satisfy their
thresholds; a claimed passing flag or nested passing run alone is insufficient.
Missing or failed cell conditions invalidate performance evidence. A reproduced
known runtime defect remains a blocking observation even when its ordinary run
exit is zero and its statistical metrics pass.

The aggregate orchestration journal retains the original execution deadline,
spent admission allowance, attempt and replacement counts across interruption.
A new lease starts a separate unfinished comparison attempt; pairs from different
leases are not pooled. Durable publication uses create-only objects and verifies
every retrieved artifact, including pre-existing objects. Failed publication or
retrieval cannot yield an authoritative success. Reports link input, comparison,
outer-cell and nested-runtime artifacts in a separately sealed snapshot. A
create-only, retrieved publication receipt anchors the root manifest digest and
measured time from freshly verified payloads to a retrieved durable report; it
remains outside that manifest to avoid a self-referential digest. Resuming a
finished session verifies and reuses that report without extending its deadline
or rerunning trials. Replay preserves the original
sealed comparison bytes and compares evidence identities and statistical outputs
while permitting a new analysis ID, clock and analysis-host fingerprint.

Historical series remain useful for investigation and workload selection, but
they never determine a comparison verdict.

For Kiroku, paired trials use durable PostgreSQL and compare each arm at its
own best measured pool size; the `$all` row lock makes a common pool size an
unfair default when concurrency changes. Only trials on a controlled benchmark
cell are authoritative. Local macOS runs report their actual `wal_sync_method`
and remain exploratory because its `fsync` behavior does not establish the
same durability and timing basis as the Linux cell. A local 10-versus-32 pool
trial at a paced 250 append/s produced an inconclusive p99 comparison, so it
does not establish a pool-size optimum. This applies the performance evidence
decision in `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5`.

## Consequences

- A reported regression has a controlled counterfactual and clears both a
  statistical threshold and a practical-effect threshold.
- Noisy or unhealthy evidence fails closed as inconclusive or infrastructure
  failure instead of accusing the runtime.
- Operators must run multiple paired trials and declare every intended varying
  axis.
- Exploratory runs remain inspectable and reproducible, but cannot silently
  become release-gating evidence.
