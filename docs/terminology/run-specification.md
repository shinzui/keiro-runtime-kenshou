---
type: Term
title: run specification
description: A versioned input document that selects a scenario and supplies the values and environment for one execution.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-3
status: current
tags: [execution]
related: [TERM-1, TERM-4, TERM-6, TERM-7]
anchors:
  - {kind: file, resource: schemas/run-spec-v1.schema.json}
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/RunSpec.hs}
---

# run specification

A `kenshou.run-spec/v1` document names a [scenario](scenario.md) and can set
knobs, dimensions, seed, phases, timeout, environment, and an expected
[cohort](cohort.md). Kenshou resolves defaults before execution and writes the
effective specification as `run-spec.json` in the [run](run.md) directory. The
effective file describes what was executed, even when the submitted input was
minimal.
