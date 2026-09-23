---
type: Architecture Decision Record
title: Judge heap leaks on live bytes after major collections
description: Heap leak verdicts use forced-major-collection samples or the lower envelope of post-major live bytes, while native memory is reported separately.
timestamp: 2026-09-21T18:15:00Z
generated:
  by: process:codex
  at: "2026-09-21T18:15:00Z"
docId: ADR-10
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md
---

# Judge heap leaks on live bytes after major collections

## Context

GHC's `live_bytes` describes the most recent garbage collection. After a minor
collection it includes everything still resident in the old generation,
including objects that a later major collection can reclaim. Raw live-byte and
resident-set-size series therefore form allocator and generational sawteeth
that can rise without a retained Haskell heap leak. `max_live_bytes` is a
high-water mark and cannot demonstrate that growth later stopped.

The verification suite must also detect memory retained by C libraries. That
memory does not appear in GHC heap statistics, while resident memory includes
both it and allocator noise.

## Decision

`kenshou-diagnose` judges `heap.live-bytes` from samples taken immediately after
an explicitly requested major collection when a scenario enables that probe.
Otherwise it fits the lower envelope of `live_bytes_last_gc` in windows where
the major-collection counter advances. The verdict uses a robust Theil–Sen
slope, a moving-block bootstrap interval, absolute and relative growth floors,
and a second-half slope that distinguishes an unbounded trend from a cache that
reaches a plateau.

Forced major collections are diagnostic perturbations. Benchmark scenarios
must reject them, and a run that enables them is not comparable latency
evidence.

Native memory is a separate, lower-confidence probe computed from resident
memory less the GHC run-time system's memory-in-use figure. It never replaces
the major-collection basis for a Haskell heap verdict.

## Consequences

- Stable allocator and generational sawteeth do not become false heap leaks.
- A short or statistically ambiguous run is `insufficient-data`, not `stable`.
- Native leaks remain visible but carry a distinct confidence statement.
- Exact major-collection sampling can change pauses and object ageing, so it is
  opt-in for correctness and soak diagnosis only.
- A periodic `live_bytes_last_gc` value is eligible for the heap trend only when
  `major_gcs` has advanced since the previous sample. A value carried through a
  minute without a major collection cannot stand in for post-major evidence.
- Long-running measurement counters must force their numeric state on each
  update, and supervised worker handles must close when workers exit. Otherwise
  the harness itself can satisfy the leak detector's growth criteria, as the
  Kiroku reduced soak demonstrated with retained heap and descriptors.
