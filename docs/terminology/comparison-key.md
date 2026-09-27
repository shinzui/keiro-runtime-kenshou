---
type: Term
title: comparison key
description: A digest of the workload and environment inputs that must match for a direct run comparison.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-23
status: current
tags: [measurement]
related: [TERM-20, TERM-24, TERM-2]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Compat.hs}
---

# comparison key

The `kenshou.compat-key/v1` comparison key hashes canonical compatibility
inputs such as scenario revision, knobs, dimensions, phases, machine and
PostgreSQL profiles, and schemas. It excludes the resolved cohort's solver plan
hash so a candidate [cohort](cohort.md) can be compared to a baseline when the
intended varying axis is declared. The [series key](series-key.md) includes
that plan hash.
