---
type: Term
title: invariant
description: A stated property that Kenshou checks against observations from a scenario.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-15
status: current
tags: [correctness]
related: [TERM-14, TERM-16, TERM-17]
anchors:
  - {kind: file, resource: kenshou-check/src/Kenshou/Check/Invariant.hs}
  - {kind: doc, resource: docs/adr/0008-classify-invariants-by-contract-strength.md}
---

# invariant

Examples include no acknowledged work being lost, checkpoints never
regressing, and two owners never acting under the same lease. Kenshou classifies
an invariant as a published `contract` or an `implementation` property. A
contract violation blocks a run; implementation findings remain visible
without claiming an unpromised guarantee. See [ADR-8](../adr/0008-classify-invariants-by-contract-strength.md).
