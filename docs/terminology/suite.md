---
type: Term
title: suite
description: A named planning policy that selects a useful set of scenario kinds, tiers, and matrix settings.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-9
status: current
tags: [planning]
related: [TERM-1, TERM-5, TERM-11]
anchors:
  - {kind: file, resource: schemas/suite.v1.schema.json}
  - {kind: doc, resource: docs/planning.md}
---

# suite

Checked-in suites such as `smoke`, `change`, `nightly`, `weekly-soak`, and
`release` encode common planning intentions. `kenshou plan --suite change`
applies one such policy and writes a [run plan](run-plan.md). Command-line
policy options can override the suite; the suite itself is not a completed
collection of run results.
