---
type: Term
title: dimension
description: A named verification axis whose supported values select a run's instrumentation or PostgreSQL mode.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-6
status: current
tags: [execution]
related: [TERM-1, TERM-7, TERM-25]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Dimension.hs}
  - {kind: doc, resource: docs/planning.md}
---

# dimension

Kenshou's shared axes are `telemetry.tracing`, `telemetry.metrics`,
`pg.durability`, and `pg.version`. A [scenario](scenario.md) declares which
values are supported and which default applies. The planner can expand a matrix
across these axes, while `--dim NAME=VALUE` chooses one value. A
[knob](knob.md) instead controls scenario-specific workload behavior.
