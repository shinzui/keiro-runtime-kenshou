---
id: 23
slug: define-the-round-protocol-and-its-report
title: "Define the round protocol and its report"
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

# Define the round protocol and its report

This ExecPlan is a living document. Keep its living sections current. The
2026-11-17 update supersedes the former local generic implementation design.


## Purpose / Big Picture

Make repeated verification rounds easy to run from this consumer using
released generic round machinery. Keep Keiro cohort selection, report locations,
coverage policy, and optional Rei tracking here. EP-5 runs the first release
refresh without waiting for this integration; its accepted frozen evidence is a hard prerequisite for this child’s
real producer/consumer handoff.

This is EP-4 of
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

- Decision: A round freezes its base as an explicit list of run IDs captured at `round open`,
  not as a run plan.
  Rationale: MasterPlan 1's released-cohort baseline was accumulated over many plans, cells and
  local runs, so no single run plan describes it. Listing the latest counted observation per
  scenario at open time is exact and immutable. Comparing against a moving "latest" would let a
  base change underneath an open round.
  Date: 2026-10-01

- Decision: `round open` refuses while `owners scopes --strict` reports an error for an in-scope
  record, unless `--allow-scope-errors` is given and recorded in the round file.
  Rationale: A stale scope makes the candidate run lie. An owner-fixed defect whose scope still
  covers the fixed version stays non-blocking even when it still reproduces.
  Date: 2026-10-01

- Decision: Rei changes are printed by default and applied only with `--apply-rei`.
  Rationale: Rei is shared personal state outside this repository. A dry-run default lets a
  person review the intentions and dependencies before they appear, matching how the rest of
  the house tooling treats outward-facing writes.
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

The exact prerequisite is: EP-5 (docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md) Complete and EP-3 (docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md) Complete, plus G4: adopted published generic round definitions, selection, frozen-baseline handling, and reporting.
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

Inspect the published round schema and command extension contract. Wire the
consumer's catalog, component graph, cohort descriptors, evidence readers, and
EP-3's disposition contribution into it. Generic round opening, snapshotting,
selection, reporting, and schemas must be implemented and released upstream;
this child must not add `Kenshou.Owners.Round` to a local generic package.

Require exact frozen baseline run IDs and trust, candidate identity, record
scope, and selection inputs. The current-history view is not an alternative to a
frozen baseline. Retain broad release-refresh coverage separately from a later
change-only round; budgets and excluded scenarios must be visible. Check the
scope-error refusal and explicit override behavior against the released API.

Use EP-5's accepted `rounds/1/refresh-inputs.json` with its exact run IDs, identities,
plan/spec/policy digests, and owner snapshot to exercise the producer/consumer
handoff. It is ordinary report input data, not already a generic round document.
Construct any formal `rounds/1.json` only with the upstream schema, preserving
these references. Retain the original refresh report and write a separately dated
derived report. Account for changed source claims or interpretations explicitly.
Do not begin this integration while those artifacts are unaccepted; the whole-child
EP-5 hard dependency must be satisfied, not replaced by a synthetic fixture.

Print optional Rei commands from a consumer adapter under
`intention_01m3w49yheevg9mzkyfab1mqy4`. Verify current Rei source/docs through Mori
before relying on its CLI; the October 1 command assumptions may be stale.
Applying tracking changes requires the execution's authorization. Generic Kenshou
must not require Rei. This consumer still never edits owner lifecycle fields.
Write an operator guide here using the released command syntax, covering frozen
inputs, separate cohort builds, placement, execution, reporting, omissions, and
recovery. Any reusable operator documentation belongs upstream; link it by its
canonical Mori handle rather than copying a generic protocol specification.


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

The assembled consumer can freeze, plan, execute, and report a round with the released generic tools. Baseline input remains fixed when newer history arrives; reports expose trust, labels, skips, scope overrides, and infrastructure failures. The real EP-5 handoff replays without silently changing inputs, and Rei is optional.

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

EP-4 owns consumer round configuration, report presentation policy, operator guide, and optional Rei wiring. Generic round types, schemas, commands, selection, freezing, and derivation belong upstream. EP-5 owns the original refresh artifacts; EP-4 consumes rather than replaces them.

Concrete upstream types and command signatures must come from the verified
published release. This document declares consumer responsibilities and the
acceptance gate rather than reserving an unimplemented generic protocol.
