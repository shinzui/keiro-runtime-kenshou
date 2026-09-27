---
type: Term
title: series key
description: A digest of run compatibility inputs including the resolved cohort plan hash.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-24
status: current
tags: [measurement]
related: [TERM-23, TERM-2]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Compat.hs}
---

# series key

Kenshou stores this key beside the [comparison key](comparison-key.md) in a
run result. The series key includes the resolved [cohort](cohort.md) plan hash,
so a different dependency solution produces a different series even when its
workload and environment inputs are otherwise comparable.
