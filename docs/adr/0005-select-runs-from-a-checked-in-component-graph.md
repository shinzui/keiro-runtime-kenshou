---
type: Architecture Decision Record
title: Select runs from a checked-in component graph and over-select when unsure
description: Kenshou maps changes through a reviewed build-and-runtime dependency graph, verifies build edges mechanically, and selects all evidence when an input cannot be mapped safely.
timestamp: 2026-09-21T14:03:22Z
generated:
  by: process:codex
  at: "2026-09-21T14:03:22Z"
docId: ADR-5
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/3-plan-and-select-runs-from-what-changed.md
---

# Select runs from a checked-in component graph and over-select when unsure

## Context

The runtime verification suite is too large to run every scenario for every
change. Package dependencies alone do not describe the verification impact:
migration packages change the schemas used by stores, the harness exercises
external services, and parts of Keiro consume only selected Shibuya contracts.
Inferring these relationships anew from paths or package names would make
selection opaque and could silently omit required evidence.

Observability changes add another trap. A default configuration has tracing and
metrics disabled, so selecting a telemetry scenario without enabling telemetry
would execute no changed code.

## Decision

Kenshou keeps a versioned component graph in
`kenshou-core/data/components.json`. It distinguishes build edges visible in
Cabal from runtime edges that express schema, service, and harness coupling.
Whole components and reviewed sub-components own scenario selectors. Change
inputs are mapped into this graph and traverse the transitive dependent closure;
every selected scenario records the shortest dependency path that selected it.

`kenshou plan --graph-check` compares build edges with Cabal's resolved
`plan.json`. Runtime edges remain explicit reviewable assertions because the
build plan cannot prove them.

An unknown cohort package, an unmapped local path, or an unsafe cohort-project
change selects all scenarios and emits a warning. Documentation-only upstream
paths may be ignored only when a repository-scoped diff proves they are outside
all declared source roots. Changes originating in observability components or
telemetry sub-components raise the minimum dimension policy to
`telemetry-corners`.

## Consequences

- Selection decisions are reproducible, explainable, and reviewable in source.
- Cabal dependency drift fails a machine check instead of quietly changing the
  planner's behavior.
- Runtime relationships require maintenance when architecture changes.
- Uncertainty costs execution time but cannot silently remove evidence.
- Telemetry changes always exercise enabled telemetry paths even when the suite
  policy otherwise requests only defaults.
