---
id: 2
slug: close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds
title: "Close the verification and repair loop for the keiro runtime in rounds"
kind: master-plan
created_at: 2026-10-01T16:21:09Z
intention: "intention_01m3w49yheevg9mzkyfab1mqy4"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T16:21:09Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-17T15:29:57Z
      mode: "update"
      note: "Prioritize released-cohort refresh and align reusable tooling with extracted Kenshou ownership"
---

# Close the verification and repair loop for the keiro runtime in rounds

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. Child plans own milestone
progress; this document owns sequencing and shared boundaries.


## Vision & Scope

The immediate goal is to rerun the available Keiro runtime verification suite
against current released packages and compare it with the historical baseline.
The [September baseline report](../reports/2026-09-29-runtime-baseline.md) and
`cohort/released.{json,project}` remain historical inputs. A *cohort* is an exact
set of resolved runtime packages, not a label for whatever is newest today.
[ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md) requires
proof of the packages each executable actually links.

Many releases have happened since the initial tests. Round 1 must therefore
cover previously passing behavior, known defect reproductions, open findings,
and available newer scenarios across PGMQ, Kiroku, Shibuya, Kafka, Keiro, and the
assembled runtime. Selecting only records whose owners say `fixed` is too narrow.
An *owner record* is an upstream bug or improvement report addressed by its
canonical Mori URI. Owner status is an input to verification, never proof of it.

The initiative has two deliverables. First, EP-5 performs a release refresh with
the existing harness: freeze historical evidence, verify current releases, pin a
candidate, execute a documented matrix, retain evidence, and publish a dated
comparison. Second, EP-1 through EP-4 integrate reusable owner and round tooling
when it is released by `mori://shinzui/kenshou`. The refresh does not wait for that
automation or for adoption of the extracted harness.

Reusable harness implementation belongs in the extracted Kenshou project. This
repository owns Keiro layer bundles, cohort descriptors, the component graph,
scenario-to-owner mappings, scope declarations, findings, verification records,
and reports. Its local generic packages are transitional copies, not a place to
implement a second owner/round engine. Follow
[ADR-3](../adr/0003-kenshou-owns-the-runtime-verification-protocol.md).

Repairs remain with the runtime owners. This initiative does not edit owner
lifecycle fields, automatically rewrite Haskell defect scopes, publish a Kenshou
release, or migrate this consumer to an unpublished harness. Rei tracking is
consumer coordination; it is not a required dependency of the generic harness.
CI orchestration remains outside this plan.


## Decomposition Strategy

Keep the five existing child plans, but change their execution order and ownership.

EP-5 (`docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md`)
is the first work to execute. It owns the actual broad release comparison and
its frozen evidence inputs. It can do owner and scope checks manually, recording
sources and uncertainty. It uses existing `plan`, `execute`, `compare`, `record`,
`attest`, cohort, and cell commands; no `owners` command is assumed to exist.

EP-1 (`docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md`)
integrates released generic owner lookup with this repository's findings and
scenario references. EP-2 (`docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md`)
connects its real scope declarations and package mappings to released generic
scope reconciliation. EP-3 (`docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md`)
connects recorded Keiro observations and consumer oracles to generic disposition
derivation. EP-4 (`docs/plans/23-define-the-round-protocol-and-its-report.md`)
integrates generic round definitions, selection, and reporting, with local Rei
wiring. These are consumer integration plans, not instructions to create generic
packages here. Their former local implementation designs are superseded.

The upstream feature work has not been assigned a verified upstream plan in this
update. Before EP-1 through EP-4 can start, identify and accept the required
published APIs and this consumer's adoption of that release. Missing capabilities
must be planned in `mori://shinzui/kenshou`; do not invent release versions or
silently recreate the implementation locally. This external gate does not block
EP-5. Adoption is separately scoped work rather than an implicit part of rerunning
the runtime tests.

Relevant decisions are [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md),
[ADR-3](../adr/0003-kenshou-owns-the-runtime-verification-protocol.md),
[ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md),
[ADR-6](../adr/0006-comparison-verdicts-require-controlled-benchmark-evidence.md),
[ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md),
[ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md),
[ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md), and
[ADR-23](../adr/0023-pin-performance-gates-to-independent-preparation-and-calibration-evidence.md).
The extraction boundary is documented in
`mori://shinzui/kenshou/masterplans/1-extract-a-package-agnostic-verification-harness-into-kenshou`,
`mori://shinzui/kenshou/okf/adrs/concepts/ADR-1`, and
`mori://shinzui/kenshou/okf/adrs/concepts/ADR-18`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Report owner-record status for every kenshou finding (consumer integration) | docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md | External gate G1 | EP-5 evidence | Not Started |
| 2 | Reconcile known-defect cohort scopes with owner records (consumer integration) | docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md | EP-1; external gate G2 | EP-5 scope audit | Not Started |
| 3 | Derive fix-verification dispositions from recorded evidence (consumer integration) | docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md | EP-1, EP-2; external gate G3 | EP-5 evidence | Not Started |
| 4 | Define the round protocol and its report (consumer integration) | docs/plans/23-define-the-round-protocol-and-its-report.md | EP-3, EP-5; external gate G4 | None | Not Started |
| 5 | Run the first repair-verification round against a fixed cohort (release refresh first) | docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md | None | MasterPlan 1 coverage and cell plans | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. EP numbers above
identify rows here, not filename prefixes. MasterPlan 1 references mean the
[existing suite's registry](1-build-an-extensive-verification-suite-for-the-keiro-runtime.md#exec-plan-registry).
An unfinished coverage plan does not hide an available scenario or imply that
unimplemented coverage passed.


## Dependency Graph

Execution order is **EP-5 first**, followed by EP-1, EP-2, EP-3, EP-4 as their
external gates become satisfied. EP-5 has no hard dependency on the new tooling.
Its own first milestone checks Mori, release lookup, baseline evidence, builds,
and execution prerequisites. Concrete unavailable resources remain blockers to
the affected tests and are reported, not worked around with invented results.

G1 requires a published generic owner-record API in `mori://shinzui/kenshou` and
accepted consumer adoption of that release. G2 adds released scope evaluation;
G3 adds released disposition derivation; G4 adds released round machinery.
Each gate is satisfied by an exact released version, its upstream release tag,
and an accepted consumer check, recorded in the affected child. EP-4 also
hard-depends on EP-5 Complete so its real frozen-evidence handoff is available. A whole-child
hard dependency requires that child to be Complete. No upstream API or release
is claimed to have shipped in this update.

EP-1 through EP-4 must not become a second implementation of the extracted
harness. If an upstream capability is missing, record the canonical upstream
work reference and keep that integration pending. EP-5 can finish a documented
comparison before any of these gates is satisfied. MasterPlan completion still
requires the four integrations, not just a report.


## Integration Points

**Generic harness ownership.** The owner of reusable run, comparison, evidence,
owner-record, scope, disposition, and round machinery is
`mori://shinzui/kenshou`. This MasterPlan owns only its Keiro consumer integration.
The extracted harness must take bundle contributions or explicit configuration;
it must not import Keiro layers or hard-code this repository's directories,
package names, owner URIs, evidence target, or Rei intention. Existing local
copies may execute EP-5 before adoption; do not add new generic implementations
to them. EP-1 verifies the published extension points before later integration.

**Consumer inputs.** EP-1 owns collecting canonical references from
`docs/findings/` and the registered scenario catalog. EP-2 owns the local mapping
from `affects` URIs to cohort packages and the audited `KnownDefect` declarations.
It proposes source edits for review; it does not narrow scopes without owner
version evidence. EP-3 supplies consumer recomputers and evidence locations and
uses the generic scope evaluator. EP-4 consumes all three integrations through
published APIs. Concrete upstream types and codecs are selected from the release,
not redefined in these child plans. The consumer command assembly currently
lives in `kenshou-cli/src/Kenshou/Cli/Registry.hs`; adoption may move that entry point.

**Refresh evidence and automation handoff.** EP-5 owns
`rounds/1/refresh-inputs.json`, ordinary checked-in report input data rather than a
new evidence concept type. It freezes the historical run IDs and trust, cohort
and harness identities, exact plan/spec/policy digests, release checks, scope
audit, new run/record IDs, comparisons, and coverage omissions. EP-4 owns using
those exact inputs to validate the later generic round integration. It must not
substitute whatever history calls latest when the automation is implemented.
Any formal `rounds/1.json` uses the released upstream schema and is created only
at that integration step; the refresh inputs must not pretend to conform to an
unimplemented schema. Keep the original refresh and its dated report intact;
record later derived reports separately. The representative producer/consumer
check is EP-4 replaying EP-5's frozen evidence and accounting for any difference.

**Comparison and trust.** EP-5 distinguishes historical observations from fresh
same-harness baseline/candidate runs. Every scenario/matrix row has both outcomes
or an explicit missing, incompatible, or not-run reason. Functional outcomes,
known-defect labels, owner claims, performance, and infrastructure are reported
separately. Exit zero can mean an expected defect reproduced; inspect labels and
`knownDefect`, not just the process exit. Only confirmed evidence supports a
headline `verified-fixed`. Missing or incomplete attestation remains visible.
EP-3 derives those conclusions from evidence using the upstream engine; EP-4
renders them without introducing a competing vocabulary.

Performance verdicts require fresh paired, interleaved runs under the same
controlled environment and a recorded comparison policy. Historical workstation
timings are context. Use five pairs by default; retain samples and uncertainty.
A failed health gate, inadequate coverage, incompatible build features, or an
uncalibrated performance profile cannot yield whole-runtime acceptance. EP-5
uses existing comparison machinery and ADR-6; bounded `perf` gates additionally
follow ADR-23. Do not make the runtime release refresh depend on qualifying a
new performance product.

**Tracking and owner authority.** EP-4 owns optional consumer-side Rei wiring
under `intention_01m3w49yheevg9mzkyfab1mqy4`. Generic Kenshou need not depend on
Rei. Owners keep repair and lifecycle authority. Local findings link existing
owner records and record new failures; filing new owner reports follows
MasterPlan 1's Integration Point 11 within the execution's authorized scope.


## Progress

Coordination snapshot (2026-11-17): all five children remain Not Started; this
update did not run the runtime tests or select new dependency pins. EP-5 is the
next execution target. EP-1 through EP-4 now wait on published upstream features
and consumer adoption rather than blocking the first rerun. The October 1
snapshot and version list are historical, not candidate selection inputs.

The extracted project's checked-in plan registry says EP-1 through EP-6 Complete and EP-7
(first publication) In Progress. This is checkout evidence, not a registry-backed
claim that no later release exists. Verify Hackage and upstream tags before
choosing versions or deciding whether adoption can proceed. Mori's database was
unavailable during this update, so current registry/owner state and canonical URI
resolution could not be verified. That check remains required in EP-5's preflight.

The existing isolated October 10 Shibuya comparison is useful prior evidence,
but its reduced build and local timings do not satisfy the full runtime refresh.
No new performance or fix-verification conclusion is claimed here.


## Surprises & Discoveries

- The [October 10 report](../reports/2026-10-10-shibuya-latest-timings.md) already
  compares newer Shibuya and Kiroku releases with the baseline. It disables
  Keiro schema support, retains evidence locally without external attestation,
  and labels timings exploratory. A new candidate must report its full catalog
  and enabled features so reduced coverage cannot look like a whole-runtime pass.
- The extracted Kenshou source documents that generic packages belong upstream
  while the consumer retains its copies until a first release. The original
  EP-1 through EP-4 would have added generic tooling to the wrong repository.
- On 2026-11-17, `mori registry list`, package searches, and `mori path` failed
  because the configured Mori PostgreSQL socket was absent. The exact extracted
  checkout's manifest, README, extraction MasterPlan, and relevant ADRs were read
  directly after those lookup attempts. No registry freshness or release check
  is inferred from that fallback.

Historical discoveries from the October 1 design, to recheck during the refresh:

- Owner status has moved under the hand-maintained register. The 2026-09-29 baseline report
  counts 14 fixed, 16 reported and 2 duplicate among 32 distinct owner bug records. On
  2026-10-01, reading the owner files directly, 16 of the bug records cited from
  `docs/findings/` were `fixed`. A register written by hand goes stale between checkpoints,
  which is why EP-1 integrates a computed view.
- Some existing `KnownDefect` scope bounds were chosen without an owner version. In
  `kenshou-kafka/src/Kenshou/Suite/Kafka/Concurrency/Zombie.hs` and `BrokerOutage.hs`, the
  scopes for `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4` and `BUG-3`
  are `VersionBelow "shibuya-kafka-adapter" "0.9.0.2"`. Both owner records were `reported` at that checkpoint, with
  no `fixedVersion`. `BarrierOverwrite.hs` scopes BUG-5 below `0.9.0.2`, while the owner records
  `fixedVersion: "0.9.1.0"`. This is the concrete case EP-2 exists to catch.
- Owner-record fields are less uniform than the profile intends:
  - `affects` is sometimes a package URI (`mori://shinzui/shibuya/packages/shibuya-core`) and
    sometimes a whole project (`mori://shinzui/keiro`, which ships five packages).
  - `fixedVersion` is sometimes `unreleased`.
  - One kiroku report carries `affectedVersion: "0.8.0.1 through 0.9.0.0"`, which is free text.

  EP-1 must report these as they are; EP-2 must map project-level `affects` through the cohort
  descriptor and refuse to guess for a multi-package project.
- Owner plans cite their own repository's records by local handle or file name rather than
  canonical URI. For example,
  `mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6`
  cites local owner handles. Plan discovery must accept a canonical URI from any repository,
  and a local handle or record path only within the owning repository.
- The Mori registry lags owner bundles in more places than the two re-registered on 2026-10-01.
  After keiro and shibuya-kafka-adapter were re-registered, `mori path` still could not resolve
  `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-4`, although
  the producing report carries `bugId: BUG-4` in the owner checkout. `mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6` cites that record. EP-1 reports such records
  as `unresolved`, and the operator fix is `mori register --path <owner checkout>`.
- Owner bug-report handles live in `bugId` (`coordination.bugReports` declares
  `idField = "bugId"`), and several owners name report files by slug rather than number. Handles
  must come from frontmatter, never from file names.
- Some `KnownDefect` references are not owner records: Keiro MasterPlans, Keiro user
  documentation, a Shibuya review concept, and a kenshou plan in the selftest. EP-1 classifies
  them as `other` so they are visible and are not miscounted as bugs.
- Fix verification already happens informally. `docs/findings/27-shibuya-health-probes-ignore-terminal-lifecycle.md`
  records passing "isolated Hackage 0.10.0.0 controls" for the fixed Shibuya metrics release, in
  prose only. Rounds make that practice systematic and queryable.
- A `KnownDefect` whose scope does not apply to a cohort is not written into that run's result
  or evidence record (`applicable` in `defectDisposition`, `kenshou-core/src/Kenshou/Core/Run.hs`).
  A passing run on a fixed cohort therefore carries no link to the record it verifies. EP-3 must integrate a join through the scenario catalog, not through the run record's `knownDefects` field alone.


## Decision Log

- Decision: Kenshou owns the verification loop and never the repairs; owner records are read,
  never written.
  Rationale: MasterPlan 1's 2026-09-27 decision keeps repairs with the owning projects, and an
  owner record's lifecycle is its owner's authority. Writing "verified" into another
  repository's report would create two authorities for one fact.
  Date: 2026-10-01

- Decision: Dispositions are derived at read time from immutable run records and the scenario
  catalog; the dated round report states them. No new concept type is added to
  `docs/verification/`.
  Rationale: ADR-18 fixes the bundle's three types and derives baselines at read time. A stored
  disposition would go stale the moment a newer confirmed run arrives, and would require an
  additive release of the shared verification-evidence profile first.
  Date: 2026-10-01

- Decision: Scope reconciliation proposes `KnownDefect` changes; it never rewrites Haskell
  source.
  Rationale: Scopes live in scenario modules, and narrowing one changes what blocks. A person
  must review that change. Mapping a project-level `affects` to a package can also be ambiguous.
  Date: 2026-10-01

- Decision: Round progress is tracked in Rei through a program project created with
  `rei project create` (no `mori` reference), one child intention per round under this
  MasterPlan's intention, and `rei dependency add` from each round to the owner intentions that
  carry the fixes.
  Rationale: Owner fix intentions already live under their own repositories' intentions and
  projects; this keeps them there. A project Topic without a `mori` reference is ignored as a
  planning target under the proposed rule in `mori://shinzui/rei/okf/adrs/concepts/ADR-45`. So
  scoping owner intentions to it for rollup does not create planning-target ties with their own
  repository projects. It works with today's Rei and needs none of IR-6, IR-7 or plan 231.
  Date: 2026-10-01

- Decision: Five child plans, sequential after EP-1, with the first real round as its own plan.
  Rationale: Each plan adds one checkable layer of the join: owner state, scope, evidence,
  round. Making the first round a separate plan proves the loop on real fixes, such as the ten
  Shibuya records fixed in 0.10.0.0, rather than on fixtures alone.
  Date: 2026-10-01

- Decision: Execute EP-5 as a broad release refresh before the automation chain;
  use the existing harness and record manual owner/scope checks.
  Rationale: The release gap calls for fresh evidence now, including regressions
  outside known fixes. Four new commands are not prerequisites for running tests.
  This supersedes the October 1 sequential execution decision and EP-5's former
  hard dependency on EP-4.
  Date: 2026-11-17

- Decision: Re-scope EP-1 through EP-4 as integrations of released generic Kenshou
  features. Keep the runtime-specific inputs, evidence, policies, and Rei wiring
  here, and keep generic implementations upstream.
  Rationale: The harness has been extracted. Creating `kenshou-owners` and a second
  round engine here would recreate the coupling that extraction removed. This
  supersedes the original local package/interface ownership, while preserving the
  read-only owner authority and immutable evidence decisions. ADR-3 records the
  durable boundary.
  Date: 2026-11-17

- Decision: Rei wiring is optional consumer coordination, superseding its earlier
  role as a required round completion gate.
  Rationale: Runtime verification and the extracted generic harness do not require
  a personal tracking service to produce inspectable evidence.
  Date: 2026-11-17

Revision note (2026-11-17): prioritize a release-wide rerun and controlled
comparison, replace stale smallest-fix selection with verified current compatible
releases, and align automation ownership with the extracted Kenshou boundary.

## Outcomes & Retrospective

The coordination update defines the next executable verification work and the
upstream/consumer split. Runtime outcomes await EP-5 execution; generic tooling
integration awaits its declared external gates. No test result is implied by
this planning update.
