---
type: Term
title: known defect
description: An owner-repository contract failure whose reference and expected failure labels are scoped to affected cohorts.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-18
status: current
tags: [correctness]
related: [TERM-2, TERM-12, TERM-15]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Scenario.hs}
  - {kind: doc, resource: docs/adr/0014-distinguish-documented-limitations-from-known-defects.md}
---

# known defect

A scenario may cite a confirmed bug report using its canonical `mori://` URI.
Kenshou applies that reference only to the specified [cohorts](cohort.md) and
failure labels. Reproducing exactly the covered labels can make a failed run
nonblocking; a new failure label still blocks. A documented limitation or
desired improvement is an implementation finding, not a known defect. See
[ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md).
