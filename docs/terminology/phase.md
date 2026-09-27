---
type: Term
title: phase
description: A timed part of a run's workload lifecycle, named warm-up, steady, or drain.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-8
status: current
tags: [execution]
related: [TERM-3, TERM-4]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Phase.hs}
---

# phase

The [run specification](run-specification.md) assigns durations to `warm-up`,
`steady`, and `drain`. Warm-up lets the workload settle, steady is the main
observation window, and drain allows outstanding work to finish. The result
records phase timings so measurements can be interpreted against the intended
window.
