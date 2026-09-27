---
type: Term
title: evidence record
description: An OKF account of a run or comparison whose claim is fixed and whose raw artifacts are digest-pinned.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-27
status: current
tags: [evidence]
related: [TERM-4, TERM-20, TERM-28]
anchors:
  - {kind: file, resource: kenshou-evidence/src/Kenshou/Evidence/Record.hs}
  - {kind: doc, resource: docs/guides/recording-evidence.md}
---

# evidence record

`kenshou record` preserves a completed [run](run.md) or
[comparison](paired-comparison.md) as a historical fact in
`docs/verification`. The record identifies the cohort, conditions, result,
purpose, and SHA-256 links to durable data; measured values remain in those
linked artifacts. A later [attestation](attestation.md) adds a separate
verification event. The claim stays fixed, although ordered `verified`
metadata can be appended. See
[recording evidence](../guides/recording-evidence.md).
