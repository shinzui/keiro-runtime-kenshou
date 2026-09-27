---
type: Term
title: outcome
description: The reported execution state of a run, distinct from whether its failure blocks a gate.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-12
status: current
tags: [results]
related: [TERM-4, TERM-17, TERM-18]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Outcome.hs}
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/RunResult.hs}
---

# outcome

A run can be `passed`, `failed`, `errored`, `inconclusive`, or
`infrastructure-failure`. The result also records `blocking` and an exit code.
For example, a failed run that reproduces only an applicable
[known defect](known-defect.md) may be nonblocking while retaining its `failed`
outcome. A [verdict](verdict.md) gives the status of an individual check within
a run.
