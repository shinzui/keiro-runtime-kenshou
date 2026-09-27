---
type: Term
title: telemetry arm
description: A selected tracing or metrics mode whose effect and measurement overhead Kenshou can compare.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-25
status: current
tags: [observability]
related: [TERM-6, TERM-20]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Dimension.hs}
  - {kind: doc, resource: docs/guides/wiring-telemetry-arms.md}
---

# telemetry arm

Tracing has `off`, `noop`, `sdk-inmemory`, and `sdk-otlp` arms; metrics has
`off`, `collect`, `serve`, and `serve-scraped`. Each arm is a value of a
[dimension](dimension.md). The all-off arm still uses independent Kenshou
measurements, allowing telemetry overhead to be compared without depending on
the instrumentation under test. See [wiring telemetry arms](../guides/wiring-telemetry-arms.md).
