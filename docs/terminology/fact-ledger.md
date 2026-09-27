---
type: Term
title: fact ledger
description: An append-only record of scenario actions and observations consumed by independent correctness checks.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-14
status: current
tags: [correctness]
related: [TERM-15, TERM-16, TERM-17]
anchors:
  - {kind: file, resource: kenshou-check/src/Kenshou/Check/Ledger.hs}
  - {kind: doc, resource: kenshou-check/README.md}
---

# fact ledger

`kenshou-check` writes bounded JSON Lines ledgers for each process incarnation.
Facts such as an intent, acknowledgement, or observation give an
[invariant](invariant.md) checker evidence independent of the runtime's own
success report. Critical facts are flushed before the corresponding operation
is acknowledged; a torn final line can be tolerated after a crash. See the
[checker guide](../../kenshou-check/README.md).
