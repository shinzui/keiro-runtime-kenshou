---
type: Term
title: sealed run
description: A completed run directory whose manifest fixes the files that belong to its evidence.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-13
status: current
tags: [results]
related: [TERM-4, TERM-26, TERM-27]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Manifest.hs}
  - {kind: doc, resource: docs/adr/0011-never-mutate-a-sealed-run-during-offline-diagnosis.md}
---

# sealed run

Kenshou writes `manifest.json` last. Its presence marks the run directory as
complete, and its digests identify the saved artifacts. Offline
[diagnosis](diagnosis.md) reads those artifacts and writes derived output
outside the directory. This preserves the original [run](run.md) as the evidence
that was actually collected. See [ADR-11](../adr/0011-never-mutate-a-sealed-run-during-offline-diagnosis.md).
