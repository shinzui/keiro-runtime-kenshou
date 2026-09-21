---
type: Architecture Decision Record
title: Layer packages never import one another
description: Each runtime layer is its own cabal package depending only on the kernel and toolkits, so a red layer is attributable and layers build and run independently.
timestamp: 2026-09-20T00:00:00Z
generated:
  by: human:nadeem
  at: "2026-09-20T00:00:00Z"
docId: ADR-1
status: Accepted
date: 2026-09-20
---

# Layer packages never import one another

## Context

Kenshou must identify which part of the Keiro runtime failed and select only the
verification work affected by a change. Organizing code primarily by evidence
axis (`correctness`, `concurrency`, or `benchmarking`) would spread one runtime
layer across several build units and make both attribution and selection
ambiguous.

The repository instead has a kernel, reusable verification toolkits, one package
per runtime layer, an assembled-runtime package, and the CLI. This boundary must
remain explicit as the planned packages are added.

## Decision

The five layer packages (`kenshou-pgmq`, `kenshou-kiroku`,
`kenshou-shibuya`, `kenshou-kafka`, and `kenshou-keiro`) depend on
`kenshou-core` and the toolkit packages, and never depend on one another. Only
`kenshou-runtime` and `kenshou-cli` may depend on layer packages.

Correctness, concurrency, soak, and benchmark coverage live below the applicable
layer package rather than forming top-level package boundaries. A later plan may
add modules or tests to a layer, but it may not reach across to another layer to
reuse fixtures or implementation.

## Consequences

- A failing layer build or scenario has one attributable runtime boundary.
- Change-aware planning can map a changed runtime component to its layer without
  interpreting evidence-axis directories.
- Layers remain independently buildable and runnable, allowing parallel work and
  focused CI targets.
- Shared fixtures and helpers must be promoted to the kernel or a toolkit instead
  of being imported from another layer.
- Cross-layer behavior belongs in `kenshou-runtime`; command aggregation belongs
  in `kenshou-cli`.
