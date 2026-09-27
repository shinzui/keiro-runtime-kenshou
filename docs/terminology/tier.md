---
type: Term
title: tier
description: A scenario's declared execution cost class used to filter planned work.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-5
status: current
tags: [planning]
related: [TERM-1, TERM-9, TERM-11]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Scenario.hs}
  - {kind: doc, resource: docs/planning.md}
---

# tier

Scenarios declare `smoke`, `standard`, `extended`, or `soak`. A planner can
limit the highest admitted tier with `--max-tier`; the tier describes the
expected cost and reach of a [scenario](scenario.md), not whether an individual
[run](run.md) passed or whether its evidence is suitable for a benchmark
verdict. See [planning](../planning.md).
