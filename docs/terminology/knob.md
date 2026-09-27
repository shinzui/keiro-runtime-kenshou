---
type: Term
title: knob
description: A typed, scenario-specific input that changes a workload or diagnostic setting.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-7
status: current
tags: [execution]
related: [TERM-1, TERM-3, TERM-6]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Knob.hs}
  - {kind: doc, resource: docs/planning.md}
---

# knob

A scenario declares each knob's accepted type, default, and any reviewed
variants. `--set NAME=VALUE` selects a value; for example,
`diagnose.major-gc-interval-ms=1000` enables exact post-collection heap
samples. Unlike a [dimension](dimension.md), a knob is owned by the scenario
and need not be meaningful across the catalog.
