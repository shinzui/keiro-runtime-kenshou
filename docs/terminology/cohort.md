---
type: Term
title: cohort
description: The resolved set of runtime component packages and sources tested by a Kenshou executable.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-2
status: current
tags: [identity]
related: [TERM-4, TERM-11]
anchors:
  - {kind: file, resource: kenshou-core/src/Kenshou/Core/Cohort.hs}
  - {kind: doc, resource: docs/adr/0002-every-result-carries-a-resolved-cohort-identity.md}
---

# cohort

The `released` and `head` descriptors say which runtime versions or revisions
Kenshou intends to test. The resolved cohort identity records what the build
actually selected, including package sources and a solver plan hash. Every
[run](run.md) carries that identity so a result cannot be mistaken for evidence
about merely requested pins. See [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md).
