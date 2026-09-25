---
type: Architecture Decision Record
title: Distinguish documented limitations from known defects
description: Verification classifies unpromised behavior as implementation findings and links confirmed contract failures to reproducible owner-repository bug reports.
timestamp: 2026-09-24T02:30:02Z
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

Kenshou represents a documented limitation or desired improvement as an
implementation-class invariant. Its measured behavior stays visible even when
the run passes its published-contract checks. An upstream improvement plan
alone does not turn an unpromised target into a contract or a `KnownDefect`.

Known-defect references use canonical `mori://` URIs. A new observation is
recorded as evidence and remains blocking when it violates a contract; the
suite does not invent or claim a defect filing.

For a newly reproduced failure of behavior the producer already promises,
file an OKF `Bug Report` in the repository that owns the behavior. State the
affected released version (or `unreleased` for an unshipped head), the
observed and expected behavior, the source of the expectation, and ordered
steps that reproduce it. Include the exact Kenshou cohort and run evidence,
and set `origin` to
`mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime`.
Record the report's canonical concept URI in the matching local
`docs/findings/` record and in that MasterPlan's issue register. Reuse an
equivalent existing report; where the behavior was never promised, file an
improvement request instead. Only attach `KnownDefect` to the scenario's
specific failure labels and affected cohorts, so another failure remains
blocking.

Kiroku scenarios state desired behavior in their implementation-class oracles
and retain upstream artifact links in the layer guide and ExecPlan. The
released cohort's five probes cover
fresh-stream deadlock (`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7`),
consumer-group resize gaps (`mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps`),
category reconnect regression and invalid batch-size acceptance
(`mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size`),
and persistent publisher decode-hook stalls
(`mori://shinzui/kiroku/plans/83-contain-persistent-publisher-decode-hook-failures`).
Each run reports the violated desired-behavior cell under
`implementationFindings` and still checks atomicity, coverage, and monotonic
checkpoints as contracts. CAP-11–13 and the owner subscription guide allow
reconnect replay and static group membership; IR-7 explicitly calls the
multi-versus-single deadlock an improvement. The other probes assert behavior
that the published APIs do not promise. The 60-second network blackhole
recovery target and category replay are likewise implementation findings;
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-16` requests
faster retries after publisher pool errors.

## Consequences

- Reports demonstrate operational hazards without falsely describing supported
  semantics as regressions.
- Confirmed contract defects are traceable to durable upstream ownership and
  can become cohort-specific when a fix ships.
- Undocumented failures cannot be made non-blocking merely by labeling them
  defects locally.
- Scenario documentation must state whether it verifies a contract, an
  implementation property, or a referenced known defect.
- A confirmed runtime failure has a versioned, reproducible owner-repository
  record and a canonical URI that remains visible in this repository.
