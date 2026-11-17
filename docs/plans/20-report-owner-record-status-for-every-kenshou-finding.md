---
id: 20
slug: report-owner-record-status-for-every-kenshou-finding
title: "Report owner-record status for every kenshou finding"
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

# Report owner-record status for every kenshou finding

This ExecPlan is a living document. Keep its living sections current. The
2026-11-17 update supersedes the former local generic implementation design.


## Purpose / Big Picture

Let a maintainer inspect current upstream owner status for every bug or
improvement cited by this Keiro suite. Integrate a released generic reader with
local findings, catalog references, and configuration; do not implement a new
`kenshou-owners` package here. The proposed `owners status` command spelling is
a target user experience, not evidence that a released API exists.

This is EP-1 of
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

- Decision: Resolve every owner URI through the `mori path` executable rather than a path
  table or a mori library.
  Rationale: `mori path <uri>` prints the resolved file on standard output and exits 1 with
  `Error: artifact '<uri>' not found` otherwise (checked 2026-10-01). It is the registry's own
  answer, and it is how every other cross-repository lookup in this portfolio works. A
  hard-coded path table would silently rot when a checkout moves.
  Date: 2026-10-01

- Decision: Never infer status from a finding's prose.
  Rationale: `docs/findings/*.md` files have no frontmatter. Their first `Status:` line is free
  prose such as "reproduced on released Shibuya metrics 0.9.0.3 and fixed on Hackage 0.10.0.0".
  The owner record's frontmatter is the only machine-readable status, and this command reports
  it. The finding's status line is shown verbatim as context.
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

The exact prerequisite is: G1: a published generic owner-record API in mori://shinzui/kenshou and accepted consumer adoption of that release. There is no preceding child dependency.
The generic capability is requested in
`mori://shinzui/kenshou/okf/improvement-requests/concepts/IR-2`
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

Locate the generic release and its source through Mori and inspect the
consumer extension contract. Identify this suite's findings directory, registered
catalog, evidence target, and project identity as explicit inputs. Follow canonical
owner URIs, including duplicates and unresolved/non-record references, through
the upstream reader. Do not hard-code this suite's paths or package names into
generic Kenshou. Register its command contribution in this consumer's executable
assembly; keep diagnostic output separate from machine-readable output.

Supply the local finding/scenario links and owner-plan/intention discovery as
consumer inputs or adapters. Cross-project plan references must be exact Mori
URIs. If upstream lacks a reusable source-reader or adapter hook, stop that
integration slice and reference upstream work instead of implementing a second
reader locally. Owner lifecycle and version fields remain read-only.

Demonstrate the integration on this repository: one resolved report, a duplicate,
an unresolved URI, and a catalog reference that is not an owner record. Inspect
raw owner sources to verify the reported values and show the exact local findings
and scenarios that cite each URI. Compare with EP-5's audit if it exists, labeling
status changes by observation date rather than rewriting the frozen audit.


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

The consumer lists every cited canonical owner URI with status, versions, resolution, local findings/scenarios, and available owner-plan links; unresolved and non-record entries remain visible. One generic implementation serves this real consumer and the upstream synthetic consumer.

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

EP-1 owns local reference collection and command/configuration wiring. It exports the resulting consumer configuration to EP-2 through EP-4; generic record types, parsing, duplicate handling, and codecs belong upstream.

Concrete upstream types and command signatures must come from the verified
published release. This document declares consumer responsibilities and the
acceptance gate rather than reserving an unimplemented generic protocol.
