---
type: Term
title: baseline
description: A reference run or set of trials against which candidate behavior is assessed.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-21
status: current
tags: [measurement]
related: [TERM-20, TERM-27, TERM-28]
anchors:
  - {kind: doc, resource: docs/guides/measuring-and-comparing.md}
  - {kind: doc, resource: docs/guides/recording-evidence.md}
---

# baseline

In a [paired comparison](paired-comparison.md), baseline trials are the
reference arm run alongside candidate trials under controlled conditions. In
historical evidence, `purpose: baseline` marks a retained reference run, and
`kenshou history --confirmed-only` can derive compatible references from
confirmed records. Neither label alone makes a run
[benchmark-grade](benchmark-grade-run.md).
