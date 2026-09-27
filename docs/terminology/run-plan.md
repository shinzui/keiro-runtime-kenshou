---
type: Term
title: run plan
description: A versioned schedule of selected runs with fixed specifications, reasons, and identities.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-11
status: current
tags: [planning]
related: [TERM-9, TERM-10, TERM-4]
anchors:
  - {kind: file, resource: schemas/run-plan.v1.schema.json}
  - {kind: doc, resource: docs/planning.md}
---

# run plan

`kenshou plan` writes `kenshou.run-plan/v1` with selected
[scenarios](scenario.md), complete specifications, run IDs, skips, estimates,
and selection reasons. `kenshou execute` consumes that exact document and
maintains a separate plan summary. Resuming requires the same plan digest;
interrupted entries get new run IDs. See [planning](../planning.md).
