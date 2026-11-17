---
id: 21
slug: reconcile-known-defect-cohort-scopes-with-owner-records
title: "Reconcile known-defect cohort scopes with owner records"
kind: exec-plan
created_at: 2026-10-01T16:22:58Z
intention: "intention_01m3w49yheevg9mzkyfab1mqy4"
master_plan: "docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T16:22:58Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-17T15:29:57Z
      mode: "update"
      note: "Rescope generic owner and round implementation to released upstream consumer integration"
---

# Reconcile known-defect cohort scopes with owner records

This ExecPlan is a living document. Keep its living sections current. The
2026-11-17 update supersedes the former local generic implementation design.


## Purpose / Big Picture

Let a maintainer see where this suite's `KnownDefect` declarations disagree
with verified owner version claims. This child supplies Keiro package mappings
and catalog data to released generic reconciliation. It does not add a scope
engine, catalog codec, or evaluator to this repository's transitional copies.

This is EP-2 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
The release refresh in
`docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md`
runs first using existing commands and a recorded manual audit.


## Progress

- [ ] Milestone 1: verify the published upstream capability and accepted consumer
  adoption; record exact release, source/tag, APIs, and dependency acceptance.
- [ ] Milestone 2: wire this consumer's inputs and contributions through that
  release, without implementing reusable machinery in local generic packages.
- [ ] Milestone 3: demonstrate the consumer behavior, retain acceptance evidence,
  and update operator documentation and parent coordination status.


## Surprises & Discoveries

The generic harness was extracted after this plan's October 1 draft. Its
checkout documents the consumer retaining local copies until publication and
later adoption. This is not permission to extend those copies into a separate
owner/round implementation. Upstream release status was not verified in this
update because Mori's configured database was unavailable.


## Decision Log

- Decision: Propose scope changes; never edit scenario source.
  Rationale: Narrowing a scope changes what blocks a run, and a project-level `affects` can be
  ambiguous. A person reviews and commits the change. The command prints the proposed Haskell
  expression and the source file that declares the reference, so the edit is mechanical.
  Date: 2026-10-01

- Decision: Keep the existing `knownDefect` key in `kenshou.scenario-list/v1` unchanged, and add
  a new `knownDefects` array beside it.
  Rationale: Consumers of `kenshou.scenario-list/v1` already read `knownDefect` as a string or
  list of strings. An additive key keeps them valid without a schema version bump.
  Date: 2026-10-01

- Decision: Re-scope this child to consumer integration of published generic
  Kenshou capabilities, superseding the local package/type/command implementation
  instructions in the October 1 draft.
  Rationale: Reusable tooling belongs in the extracted harness; Keiro inputs,
  policy, and evidence remain in this suite. The first rerun proceeds separately.
  Date: 2026-11-17


## Outcomes & Retrospective

Planning updated; no upstream release, consumer adoption, command availability,
or integration acceptance is claimed.


## Context and Orientation

This repository owns the Keiro verification layer bundles, scenario declarations,
cohort descriptors, findings, and evidence. Generic harness code belongs in
`mori://shinzui/kenshou`, whose extraction initiative is
`mori://shinzui/kenshou/masterplans/1-extract-a-package-agnostic-verification-harness-into-kenshou`.
The current consumer command assembly is
`kenshou-cli/src/Kenshou/Cli/Registry.hs`; use the adopted release's extension
point if adoption moves it. Do not edit the local generic kernel/toolkits to
recreate missing upstream features.

The exact prerequisite is: EP-1 (docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md) Complete, plus G2: adopted published generic scope reconciliation and scope evaluation.
A gate is satisfied by an exact published package version, authoritative tag,
source/docs inspection, and an accepted consumer check. No verified upstream
implementation plan for these new capabilities has been assigned here. If they
are missing, plan them upstream and record canonical Mori work references;
keep this child pending. Adoption itself is separately scoped work. Do not
silently depend on an unpublished source checkout or guess dependency bounds.

Read [ADR-3](../adr/0003-kenshou-owns-the-runtime-verification-protocol.md),
[ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md),
and [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md).
The generic boundary follows
`mori://shinzui/kenshou/okf/adrs/concepts/ADR-1` and
`mori://shinzui/kenshou/okf/adrs/concepts/ADR-18`.
Owner records are read-only. Canonical cross-repository references are mandatory.
Frozen round evidence must not be rewritten as owner status changes.


## Plan of Work

Read actual scenario declarations and cohort descriptors, and inspect the
released generic catalog/scope representations. Connect this suite's complete
defect labels and scopes through the supported bundle contribution. If generic
serialization cannot preserve them, request that capability upstream; do not
patch a consumer-specific protocol into `kenshou-core` here.

Map each owner `affects` URI to the actual cohort package or packages. Preserve
ambiguity for a project spanning several packages. Compare scopes with observed
released fixed versions; `unreleased`, unknown, malformed, missing, and unresolved
claims are not guessed into version bounds. Duplicate resolution comes from
EP-1's generic reader. Reuse one upstream evaluator for later disposition work.

Expose the upstream scope report through the consumer command assembly, with
local module locations and proposed corrections. Source changes remain reviewed
consumer edits rather than automatic rewrites. Exercise at least a known wrong
bound, a multi-package ambiguity, and a failure label outside a defect's scope.
Use the actual current owner records, not the October 1 guessed Kafka release
bounds. Reconcile with EP-5's frozen scope audit without modifying it.


## Concrete Steps

Start with dependency discovery from this repository root:

```bash
mori registry list
mori registry search kenshou
mori registry show shinzui/kenshou --full
mori registry docs shinzui/kenshou
mori path mori://shinzui/kenshou/masterplans/1-extract-a-package-agnostic-verification-harness-into-kenshou
```

Read the located release sources and documentation. Check Hackage and the
upstream tags before choosing versions. Verify all prerequisite children and
the consumer's adoption evidence. If a capability is absent, retain the exact
unmet gate and stop dependent implementation; EP-5 remains eligible. Once the
released APIs are known, record concrete registration paths and invocations in
this plan before implementing. Do not treat the former proposed commands as
already installed or reintroduce their implementation here.

Run the consumer's relevant unit/build checks, `just cohort-check`, and the real
behavior described below using that adopted release. Capture exact invocations,
outputs, harness/cohort identity, and the evidence location in Progress when
accepting the milestone. Broader generic rule tests belong upstream.


## Validation and Acceptance

A maintainer can trace every proposed correction to its current owner claim and local declaration. Unknown versions stay unresolved, a passing reconciliation never broadens a defect to hide an unrelated failure, and EP-3 consumes the same generic evaluator.

The upstream release and adoption gate must be evidenced, prerequisite children
Complete, and this consumer's behavior demonstrated through the published APIs.
No runtime-specific source, package name, URI, bucket, or Rei requirement is
introduced into generic Kenshou. A documentation update alone does not complete
this child. Update the MasterPlan registry and append provenance on acceptance.


## Idempotence and Recovery

Keep the working cohort and sealed evidence unchanged during integration checks.
Use scratch output directories and exact frozen fixtures for repeated reports.
Do not overwrite committed evidence or owner status. An unavailable upstream
feature blocks this integration, not the release refresh. Preserve the existing
consumer until a published release and its adoption are accepted.


## Interfaces and Dependencies

EP-2 owns Keiro package mappings and reviewed scenario scope edits. The generic scope model, catalog codec, reconciliation rules, and evaluator belong upstream. EP-3 consumes the evaluator through the adopted release.

Concrete upstream types and command signatures must come from the verified
published release. This document declares consumer responsibilities and the
acceptance gate rather than reserving an unimplemented generic protocol.
