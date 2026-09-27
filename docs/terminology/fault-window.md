---
type: Term
title: fault window
description: A recorded interval in which Kenshou deliberately disturbs a runtime or its environment.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-19
status: current
tags: [correctness]
related: [TERM-4, TERM-14, TERM-15]
anchors:
  - {kind: file, resource: kenshou-check/src/Kenshou/Check/Fault.hs}
  - {kind: doc, resource: kenshou-check/README.md}
---

# fault window

The checker records when a process kill, database failure, network disruption,
or other injected fault begins and ends. An [invariant](invariant.md) can then
judge observations against the declared disturbance, such as allowing a
bounded number of duplicate deliveries only inside crash windows. An
in-process exception is not a crash test; see [ADR-9](../adr/0009-define-crashes-as-process-or-backend-termination.md).
