---
type: Architecture Decision Record
title: Distinguish documented limitations from known defects
description: Verification asserts documented implementation limitations as expected behavior and reserves known-defect status for behavior with an identified upstream correction.
timestamp: 2026-09-22T02:17:39Z
generated:
  by: process:codex
  at: "2026-09-22T02:17:39Z"
docId: ADR-14
status: Accepted
date: 2026-09-21
originatingPlan: docs/plans/8-cover-pgmq-hs-in-isolation.md
---

# Distinguish documented limitations from known defects

## Context

Runtime verification must expose hazards such as stale acknowledgements,
unlogged crash loss, grouped-batch successor leasing, commit-order inversion,
and notification throttle loss. Some are deliberately documented semantics;
others have accepted upstream work intended to change them. Marking every
hazard as a defect misrepresents the supported contract, while hiding expected
limitations leaves platform owners without operational evidence.

## Decision

Kenshou represents a documented limitation as an implementation-class
invariant whose passing condition is that the observed behavior matches its
documentation. It attaches `KnownDefect` only when a canonical upstream
artifact identifies work intended to correct the behavior.

Known-defect references use canonical `mori://` URIs. A new observation without
an upstream artifact is recorded as evidence and remains blocking according to
its invariant class; the suite does not invent or claim a defect filing.

## Consequences

- Reports demonstrate operational hazards without falsely describing supported
  semantics as regressions.
- Known defects are traceable to durable upstream ownership and can become
  cohort-specific when a fix ships.
- Undocumented failures cannot be made non-blocking merely by labeling them
  defects locally.
- Scenario documentation must state whether it verifies a contract, an
  implementation property, or a referenced known defect.
