---
type: Term
title: run
description: One identified execution of a scenario whose inputs, outcome, and artifacts are saved together.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-4
status: current
tags: [execution]
related: [TERM-1, TERM-3, TERM-12, TERM-13]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Run.hs}
  - {kind: file, resource: schemas/run-result-v1.schema.json}
---

# run

Each run has its own UUIDv7 ID and directory. The directory holds the effective
[run specification](run-specification.md), result, samples, verdicts, diagnosis,
logs, and a manifest written last. The result identifies the resolved
[cohort](cohort.md) and reports an [outcome](outcome.md). A new trial or retry
gets a new run ID; an existing run directory is never overwritten.
