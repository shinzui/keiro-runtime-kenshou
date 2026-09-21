---
type: Architecture Decision Record
title: Never mutate a sealed run during offline diagnosis
description: Offline analysis reads immutable run evidence and writes requested derived output outside the sealed run directory.
timestamp: 2026-09-21T20:27:02Z
generated:
  by: process:codex
  at: "2026-09-21T20:27:02Z"
docId: ADR-11
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md
---

# Never mutate a sealed run during offline diagnosis

## Context

A completed Kenshou run ends with `manifest.json`, which binds every artifact in
the run directory to its digest. Leak thresholds and stall classifiers will
evolve, so maintainers must be able to re-evaluate old evidence without rerunning
the workload. Writing a new diagnosis into the old directory would invalidate
the manifest and blur the distinction between evidence captured during the run
and an interpretation made later.

## Decision

Once a run has been sealed, offline commands treat its directory as immutable.
`kenshou diagnose leak RUN_DIR` and `kenshou diagnose stall RUN_DIR` read the run
result, manifest, series, and saved captures but do not add, replace, or delete
anything beneath `RUN_DIR`.

Human-readable output goes to standard output. A caller requesting JSON,
Graphviz DOT, or another derived artifact must name a destination outside the
sealed run directory. The derived document identifies its source run and the
generator and algorithm version so it can be audited independently.

Live diagnosis and diagnosis performed inside a running scenario may still
write `diagnosis/*.json`; those artifacts are created before sealing and are
therefore included in the manifest.

## Consequences

- A sealed run remains byte-for-byte verifiable after any number of offline
  analyses.
- Historical evidence can be reclassified with newer algorithms without
  pretending the new conclusion existed when the workload ran.
- Automation must allocate a separate output location for retained offline
  reports.
- Any future command that intentionally edits a run must use a new run identity
  or an explicitly versioned derivation container rather than weakening this
  boundary.
