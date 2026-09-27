---
type: Term
title: scenario
description: A registered verification case with a stable identity, declared inputs and environment needs, and executable behavior.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-1
status: current
tags: [execution]
related: [TERM-3, TERM-4, TERM-5]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Scenario.hs}
---

# scenario

A scenario is the unit Kenshou can list, select, and run. Its ID has the form
`layer/component/kind/name`; for example,
`selftest/kernel/correctness/always-pass`. It declares a revision, tier,
placement, supported [dimensions](dimension.md), [knobs](knob.md), phases, and
environment requirements. A [run](run.md) is one execution of that scenario
with particular inputs, so one scenario can produce many runs.
