---
type: Term
title: verdict
description: A saved judgment that a named check held, was violated, or could not be evaluated.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-17
status: current
tags: [correctness]
related: [TERM-12, TERM-15, TERM-20]
anchors:
  - {kind: file, resource: kenshou-check/src/Kenshou/Check/Verdict.hs}
  - {kind: file, resource: schemas/kenshou.verdict.v1.schema.json}
---

# verdict

A correctness verdict names the checker and [invariant](invariant.md), classifies
it as `contract` or `implementation`, and reports `held`, `violated`, or
`not-evaluated`. It keeps counts, parameters, input digests, and counterexamples
so the judgment can be inspected. A [run outcome](outcome.md) summarizes the
whole execution; a [paired comparison](paired-comparison.md) has its own
performance verdict.
