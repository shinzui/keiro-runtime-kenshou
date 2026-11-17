---
id: 22
slug: derive-fix-verification-dispositions-from-recorded-evidence
title: "Derive fix-verification dispositions from recorded evidence"
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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-17T15:53:33Z
      mode: "update"
      note: "Link filed Kenshou improvement requests to consumer integration gates without claiming delivery"
---

# Derive fix-verification dispositions from recorded evidence

This ExecPlan is a living document. Keep its living sections current. The
2026-11-17 update supersedes the former local generic implementation design.


## Purpose / Big Picture

Let a maintainer distinguish an owner's fixed claim from evidence that the
fix passed here. Integrate released generic evidence joins and disposition
calculation with Keiro record locations, scenario mappings, and replay oracles.
Do not implement generic observation loading or disposition rules locally.

This is EP-3 of
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

- Decision: Join through the scenario catalog, not the run record's `knownDefects` list.
  Rationale: `defectDisposition` in `kenshou-core/src/Kenshou/Core/Run.hs` keeps only defects
  whose scope applies to the run's cohort, and the recorder copies only those into the record's
  `knownDefects`. A passing run on a cohort that contains the fix therefore has no link to the
  record it verifies. The catalog's current declarations, evaluated against the run's recorded
  `components`, restore that link. The join deliberately uses the current declaration even for
  older runs. For example, local run `runs/01a0e479-e310-7716-8cc3-af7b54e43fca/run-result.json`
  recorded its reproduced defect as `mori://shinzui/shibuya/okf/reviews/concepts/REV-8`, before
  the owner filed `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8`. Today's catalog
  attributes the same scenario and labels to BUG-8.
  Date: 2026-10-01

- Decision: Only `confirmed` evidence supports a headline `verified-fixed`. `unverified` and
  `local` evidence is shown with its trust label.
  Rationale: ADR-18 makes attestation the evidence of what was checked. The 2026-09-29 baseline
  report already distinguishes local sealed runs from published, attested records. Most
  finding-level runs are still local.
  Date: 2026-10-01

- Decision: Re-scope this child to consumer integration of published generic
  Kenshou capabilities, superseding the local package/type/command implementation
  instructions in the October 1 draft.
  Rationale: Reusable tooling belongs in the extracted harness; Keiro inputs,
  policy, and evidence remain in this suite. The first rerun proceeds separately.
  Date: 2026-11-17

- Decision: Link this integration to the filed upstream request in Context and Orientation;
  retain the existing published-release and adoption prerequisites.
  Rationale: A proposed request records ownership and acceptance criteria but is
  not evidence of implementation or command availability.
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

The exact prerequisite is: EP-1 and EP-2 Complete (docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md and docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md), plus G3: adopted published generic disposition derivation.
The generic capability is requested in
`mori://shinzui/kenshou/okf/improvement-requests/concepts/IR-4`
(status proposed). Filing the request does not satisfy the release/adoption gate.

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

Configure the generic history reader with this repository's evidence subject,
bundle path, and explicitly requested local sealed-run roots. Register the
consumer recomputers through the adopted bundle/API contract. Resolve scenario
links through EP-1's configuration, including passes outside the known-defect
scope: such runs may carry no embedded owner reference. Reuse EP-2's evaluator.

Read exact run-result failure labels from digest-verified data. A bundle outcome
alone is insufficient to identify which defect reproduced. Preserve separate
owner claims, run outcomes, scope applicability, missing labels, trust, and
historical order. Use the generic engine's published vocabulary, verifying it
against the intended meanings in the parent MasterPlan before registration.
Missing fixed-version evidence or incompatible runs cannot become verified fixes.
Only confirmed compatible records may support a headline verified-fixed claim.

Exercise the real Keiro evidence and a bounded consumer fixture containing a
confirmed passing fixed-cohort run, a matching reproduction, an unrelated failure,
an unverified/local pass, and absent labels. The fixture checks the consumer's
registration, source mapping, and replay hooks; the generic rule matrix belongs
upstream. If EP-5 is available, replay its frozen owner/run index and explain any
difference without substituting newer history or editing owner records.


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

Every displayed disposition traces to exact scenario/run IDs, verified label artifacts, scope evidence, and a separate trust value. Local/unverified evidence cannot enter confirmed fix counts; unresolved labels and incompatible observations stay explicit.

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

EP-3 owns Keiro oracle/recomputer and evidence-source registration. Generic observation loading, trust rules, aggregation, vocabulary, and disposition calculation belong upstream. EP-4 renders that published output.

Concrete upstream types and command signatures must come from the verified
published release. This document declares consumer responsibilities and the
acceptance gate rather than reserving an unimplemented generic protocol.
