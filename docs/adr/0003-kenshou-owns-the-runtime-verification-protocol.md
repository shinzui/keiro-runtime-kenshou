---
type: Architecture Decision Record
title: Kenshou owns the runtime verification protocol
description: The harness kernel owns versioned list, run, result, worker, and manifest documents so every layer and external runner shares one stable protocol.
timestamp: 2026-09-21T16:14:01Z
generated:
  by: process:codex
  at: "2026-09-21T05:00:00Z"
docId: ADR-3
status: Accepted
date: 2026-09-20
originatingPlan: docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md
---

# Kenshou owns the runtime verification protocol

## Context

Layer packages, planning tools, remote cells, evidence publication, and CI all
need to discover and execute the same scenarios. If each consumer owns a
command or serialization variant, a result can no longer prove exactly what was
requested or be compared reliably with another run.

The protocol also crosses process boundaries. Worker children receive a run
identity and resolved parameters from the parent, while evidence tooling reads
completed run directories without linking the Haskell libraries.

## Decision

`kenshou-core` owns the runtime-facing protocol used by `kenshou list`,
`kenshou run`, future planning and comparison commands, worker processes, and
run-directory consumers. Its JSON documents carry explicit schema identifiers;
their field names and enum texts use hand-written codecs rather than derived
encodings.

The CLI aggregates commands and layer bundles through value-level extension
points. Layer and toolkit packages may contribute scenarios, roles, and command
values, but they do not define alternative run/result formats or bypass the
kernel runner. Standard output remains machine-readable command output;
diagnostics and scenario logs use standard error or run-directory logs.

A run directory is complete only after `manifest.json` has been written. The
effective `run-spec.json` is written before execution, `run-result.json` records
the truthful outcome and resolved cohort, and the manifest covers both plus all
artifacts. Process exit codes are part of the protocol: 0 passed or reproduced
non-blocking defect, 1 failed, 2 usage error, 3 inconclusive, and 4 errored or
infrastructure failure.

Analysis commands consume the same sealed protocol. `kenshou summarize`
recomputes the versioned measurements section from retained run artifacts and
can verify it against `run-result.json`. `kenshou compare` reads paired sealed
run directories, checks their compatibility and evidence grade, and writes a
separate versioned comparison document without changing either input run. Its
pass, regression, inconclusive, and infrastructure-failure verdicts use the
same exit-code meanings as scenario execution.

## Consequences

- Local runs, remote cells, CI, and evidence ingestion consume the same
  versioned documents.
- Adding a scenario never requires inventing a new execution command.
- Protocol changes require a new schema version and compatibility handling;
  silently changing an existing version is forbidden.
- The kernel is deliberately dependency-heavy enough to provision environments
  and write evidence, while layer packages remain focused on scenario logic.
