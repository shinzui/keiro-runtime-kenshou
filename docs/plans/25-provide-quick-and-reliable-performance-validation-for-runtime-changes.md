---
id: 25
slug: provide-quick-and-reliable-performance-validation-for-runtime-changes
title: "Provide quick and reliable performance validation for runtime changes"
kind: exec-plan
created_at: 2026-10-11T00:00:00Z
intention: intention_01m4mk12vtekw9ccq8f63h7nwq
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-11T00:00:00Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T00:05:28Z
      mode: "other"
      note: "Completed the initial six-milestone plan and clarified scoped coverage and calibration acceptance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T04:12:25Z
      mode: "update"
      note: "Close review gaps in metric completeness, calibration admission, workload phases, resume budgets, replay, and CI prerequisites."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T04:20:16Z
      mode: "implement"
      note: "Implement exact-revision requests and bounded performance planning."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T03:31:29Z
      mode: "implement"
      note: "Resume live Linux preparation and implement persistent owner reset-failure quarantine with verified recovery."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T04:15:51Z
      verdict: "approved"
      note: "Approved revised design after fixing metric completeness, calibration admission, phase compatibility, and recovery contracts; graph, cell help, ADR validation, links, and structure passed. Live acceptance remains pending."
---

# Provide quick and reliable performance validation for runtime changes

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation. Follow
`.agents/skills/exec-plan/PLANS.md`. Promote durable decisions into `docs/adr/`
when implementing them. This document authorizes a design; its unchecked progress
items do not assert that the described commands or guarantees already exist.


## Purpose / Big Picture


A runtime maintainer should submit a project's baseline and candidate commits and
receive a bounded, reproducible performance comparison without manually editing
Kenshou's active cohort, building VM images, assembling paired trials, or finding
results across directories. The output must explain what changed, what was
measured, what remains untested, whether the evidence is trustworthy, and where
the immutable evidence lives. A cohort is the complete set of runtime package
versions and sources linked into the benchmark executable. A cell is an
exclusively leased set of measurement machines with a verified reset between
trials. One pair is a baseline trial and a candidate trial under the same lease.

Build this workflow on the existing planner, Linux payload publisher, cell
sessions, comparison engine, and evidence machinery. Deliver a small calibrated
performance suite, a resumable `kenshou perf` command family, and a reusable CI
workflow. An ordinary performance request must not run full release matrices or
multi-hour soaks. It must also never turn missing required coverage, insufficient samples,
a runtime correctness failure, or a cell failure into a green performance gate.

The initial end-to-end acceptance uses the Shibuya core benchmark and its PGMQ
adapter path. The request and selection protocols work for every registered
runtime component, but uncalibrated paths explicitly remain non-gating. Extending
calibrated coverage to every runtime component is subsequent work, not an implied
claim of this first release. A caller may explicitly request a limited set of
profiles and receive a pass for that named scope. The report must separately show
affected paths outside that scope; such a pass cannot be labeled whole-change
acceptance.


## Progress


- [ ] Milestone 1: Exact-revision requests produce independently verified baseline and candidate payloads, with unrelated dependency drift rejected before leasing.
- [ ] Milestone 2: Change-aware performance planning selects calibrated configurations, explains coverage and omissions, and accounts for paired execution cost.
- [ ] Milestone 3: One resumable command executes several configuration comparisons, retains every attempt, and emits a verified aggregate result with truthful exit status.
- [ ] Milestone 4: A designated quick-run cell passes contention, isolation, recovery, health-failure, and admission-latency acceptance.
- [ ] Milestone 5: The initial core and PGMQ profiles pass A/A and injected-slowdown calibration within the measured turnaround targets.
- [ ] Milestone 6: A reusable CI entry point and operator guide reproduce the accepted workflow from an upstream change and preserve its durable evidence.

Creation handoff: this plan was grounded in the working tree on 2026-10-10 local
time. No implementation or live infrastructure changes were performed. It is a
standalone follow-on to the existing cell work, not a new child silently added to
an existing MasterPlan.

Review handoff (2026-10-10): The revised design passed repository/source review.
`nix develop -c cabal run -v0 kenshou -- plan --graph-check` passed for 27
components; `nix develop -c cabal run -v0 kenshou -- help cells` passed;
`nix develop -c just adr-validate` passed for 22 concepts. Local links, named
context paths, section/milestone structure, fenced blocks, and the JSON example
were checked, and the owner's IR-1 URI resolved through Mori. All six delivery
milestones remain unimplemented; this review did not exercise live cells or
establish the proposed calibration and latency targets.


Implementation handoff (2026-10-10): Request/source codecs, generated descriptors,
bounded `perf plan`, candidate profiles, and raw-evidence admission checks are
implemented. The real same-commit Shibuya check at
`7468580c013ca431d666502379a9ce4b6045da18` retained both explicit profiles, read
versions/directories from that commit, and produced non-gating scope-complete
planning evidence. Core and measurement tests passed (85 and 40 examples),
including resealed raw/histogram/summary corruption controls; five CLI planning
tests and schema checks passed. These are partial Milestones 1 and 2: preparation,
calibration admission verification, sessions, owner acceptance, live calibration,
and CI remain open. No live comparison or payload-cache acceptance is claimed.

Preparation implementation (2026-10-10): Added prepared/inventory codecs, strong
file-inventory verification, detached clean harness builds, per-arm source locks
and standalone solver plans, generated payload publication and verified cache
reuse. Pure inventory and artifact-integrity tests passed, and a file-backed
publisher test verifies the separate harness identity before build. Nix inventory
evaluation found 405 unique Haskell packages; legacy inputs contain 71 bound-lifted
packages, while strict preparation evaluation contains zero and retains the one
reviewed package-scoped exception. Same-source live publication/cache reuse and
candidate-only build acceptance are still pending; Milestone 1 remains open.
The first live preparation caught a non-executable checked-in source-lock script;
the CLI now invokes it through Bash, matching its existing operator usage. The
failed preparation retained its generated inputs and acquired no lease.

Further implementation (2026-10-10): Both live full-cohort preparations rejected
the pinned Nix selection of `http-client-tls 0.4.0`, which violates the released
Kiroku CLI's `<0.4` bound. Independent Cabal resolution for the compatible Shibuya
commit `7512b5c692af1c005392e4445cfa26a9be41f9ea` succeeds. Preparation now carries
that authenticated registry selection, package-description revisions and flags
into the generated Nix build, then independently checks its final versions and
flags again. The strict build and second-preparation cache acceptance remain
pending. Concurrent diagnostic preparations retained separate source/build trees
and did not change the active or released cohort files.

Partial Milestone 3 (2026-10-10): Added aggregate/result and append-only session
protocols. Synthetic controls distinguish every outcome, preserve runtime blockers
separately from statistics, and exercise 4/1/3/0 precedence, publication failure,
semantic replay, interruption, lease loss, fixed deadlines and persistent retry
counts. Core performance controls passed (45 examples), and remote performance
controls passed (11 examples, including the publisher and orchestration controls).
The reusable orchestration runner checkpoints before work, preserves runtime
blockers through a failed attempt, reuses verified completed configurations,
and makes failed durable publication exit 4. These controls use synthetic
backends; the paired cell adapter and `perf run/status/resume/verify` CLI remain
unimplemented. No calibration or live session acceptance is claimed.

Cloud prerequisite (2026-10-10): The Linux builder initially generated package
metadata successfully, then its SSH proxy closed. A direct GCP check reports
`Reauthentication failed. cannot prompt during non-interactive execution.`
The user has been asked to run `gcloud auth login`. Revised metadata generation
uses the selected description and flags, supplies absent disabled-test arguments
only with a production-dependency null assertion, and remains unverified until
authentication restores the builder. No lease was acquired.

Further Milestone 3 work (2026-10-10): Added the paired-attempt engine,
same-lease cell journal reconciliation, sealed outer health/reset checks,
create-only aggregate artifact publication with full retrieval verification,
and process/thread client locking. Twenty-one remote performance controls pass,
including invalid schedule/path rejection, bounded replacement dispatch, changed
lease rejection, missing/lying/tripped condition controls, stored-object tampering,
competing clients, and expired publication grace on resume. Ten measurement controls pass, including a sealed known
defect with exit zero. The cell adapter has compiled but has not run live. The
CLI integration, complete report graph replay, timing records and independently
verified calibration admission remain unfinished. No milestone is closed by these
synthetic controls.

CLI integration handoff (2026-10-10): `perf run`, `status`, `resume` and `verify`
now compile and are connected to the cell adapter and persistent runner. Inputs
freeze the store, allowed projects, cell descriptors and capabilities; run checks
both payloads and actual evidence-destination create/retrieve access before a
lease. Publication copies evidence into a separate sealed snapshot and keeps the
client lock outside it. Replay checks retained raw metrics, outer cell seals and
conditions, workload binding, comparison semantics and aggregate precedence.
Twenty-three remote performance controls and ten CLI controls pass, including
identified replacement reconciliation, compatible-cell lease switching, and a
file-backed incomplete-scope publication/replay/tampering check with no lease.
Schema checks pass. These are synthetic protocol controls, not live performance
acceptance. Complete report metadata/timings, all-attempt graph verification,
completed-report resume reuse and independent calibration admission remain open.

Report publication handoff (2026-10-10): Aggregate results now carry measured
stage times and immutable references to the pinned inputs, ordinary comparisons,
and retained cell/runtime manifests. A retrieved, create-only publication receipt
anchors the snapshot manifest and records elapsed time from fresh payload
verification through full report retrieval. Completed-session resume reuses the
verified report without publishing a new snapshot or submitting work. Focused
controls pass: 46 core, 24 remote and 10 CLI examples; schema checks pass, including
the new synthetic publication-receipt fixture. All-attempt semantic/binding audits,
owner cleanup fencing, independent calibration admission and real performance
acceptance remain open. No live timing target is inferred from synthetic tests.

Cleanup and report work (2026-10-10): Performance recovery now treats an expired
or cancelled retained lease as lost. Release inspects only the exact owner's
retained submissions and waits for owner rejection or a sealed terminal status;
an ambiguous submitted slice keeps the lease until the original cleanup timeout.
Five file-backed cleanup controls cover unpublished work, running/sealed work,
rejection, identity mismatches and active-versus-expired reattachment. The compact
report now includes retained effect intervals and thresholds, exclusions,
preparation/execution stage times and artifact links. Owner-side generic cleanup,
quarantine and live recovery acceptance remain open. Thirty remote performance
controls and ten CLI controls pass, including expired interrupted cleanup grace.

Retained-attempt audit (2026-10-11): Replay now audits every retained attempt,
including abandoned and partial attempts, against the journaled lease, the
request-derived paired schedule and seed, pinned payloads, work digests and
ordinary comparison bytes. Trial paths are relative to their attempt directory;
moving a raw A/A control's evidence preserves its comparison bytes and replay.
Terminal executor failures are checkpointed so resume does not redispatch them.
Sealed nested runtime failures are recorded before outer pair rejection and can
be recovered after interruption without duplicating or erasing blockers. Thirty-five
remote performance controls and ten CLI controls pass, including five raw pairs,
an exit-zero defect, one corrupt-pair replacement, and a retained latency regression.
These are synthetic protocol controls. Independent calibration admission,
owner acceptance, live calibration and CI parity remain unfinished.
The full remote test suite also passes (142 examples), preserving the existing
cell slicing, pairing, submission, lease and recovery controls.

Publication deadline control (2026-10-11): Report publication and receipt replay
now enforce the first execution deadline, independently of the later cleanup
deadline. Thirty-seven remote performance controls pass, including publication
attempted during cleanup grace and a publication callback completing too late.
A late report cannot produce a verified pass or an accepted publication receipt.
The repository currently reports no GitHub environments or self-hosted runners;
the user has been asked for the protected runner and authorized identity settings.
Live cloud work still awaits renewed GCP authentication.

Partial Milestone 6 (2026-10-11): Added the reusable/manual performance workflow
with distinct preparation and measurement jobs, immutable action pins, explicit
identity/builder/capability settings, existing-environment protection checks,
trusted default-branch admission, online replay and retained artifacts. Four
offline CI controls and actionlint pass. The new DOC-6 operator guide covers
request scope, all exits, recovery, publication and current acceptance gaps;
strict guide validation passes for six concepts. The workflow has not run live,
and no protected runner or environment has been configured. Calibration, owner
acceptance and real CI/local parity still block milestone completion.

Calibration admission implementation (2026-10-11): Added strict definition,
acceptance-inventory and reference codecs/schemas, create-only declaration and
publication commands, and independent receipt retrieval plus full report replay.
The verifier enforces twenty declared seeds per experiment, fixed infrastructure
retries, nineteen expected/zero opposite outcomes, retained inconclusives and
runtime blockers, batch chronology/expiry, and retry-inclusive A/A p95. Planning
and gating execution bind that admission to effective workload/policy, the actual
build toolchain/full flake lock, actual leased machine/image profile and a separate
harness source hash. Whole-configuration heartbeat covers startup, trial gaps and
comparison serialization. Catalog links
and documentation do not create a promotion hash cycle. Synthetic controls pass
(52 core performance, 38 remote performance and 12 CLI examples); all schema
checks and strict validation of 23 ADRs and six guides pass. ADR-23 records the
durable preparation, calibration, scope, recovery and publication decisions.
The full `nix develop -c just verify` passed before the final machine/image and
heartbeat changes; follow-up core/remote/CLI suites validate those changes.
No real calibration batch or Linux payload build is claimed. Owner-side cleanup,
live health acceptance, bounded admission transport, live preparation/cache controls, cell acceptance and CI parity remain unfinished.

Raw health replay implementation (2026-10-11): The owner now seals exact reset,
payload-start and payload-finish timestamps in `cell/execution-window.json`;
commit `915fb2f` in `mori://shinzui/load-testing-infra` passed 60 Rust library
examples and three CLI examples (one unrelated opt-in test remains ignored).
Kenshou freezes the owner's health policy before admission, reconstructs CPU and
disk observations from continuous role samples, and rejects missing samples,
counter reversals, maintenance, sampling errors and stale machine/image/agent
identity. It compares reconstructed values with both the reported gates and
frozen thresholds. Calibration additionally binds the full health-policy digest.
Core, remote and CLI suites pass (113, 148 and 141 examples). This is local
acceptance; upgraded Linux images and forced live failures remain unverified.
Owner general process/file cleanup, repeated-failure quarantine/recovery,
pre-staging and admission timing probes are still open.

Bounded admission and recovery (2026-10-11): Admission now checkpoints a proposed
lease ID before its conditional write and bounds transport by the reserved
allowance. A timed-out response retains that ID for read-only reconciliation;
it cannot silently claim another lease or restart the execution clock. Recovery
cancels the exact old lease before probing submission markers, collects sealed
work written immediately before interruption, and preserves its runtime failures
before a fresh comparison attempt. Publication refuses unresolved submitted work.
The remote and CLI suites pass (154 and 141 examples), including a real ten-second
claim timeout against the file store and a lost-lease runtime-failure control.
Full healthy multi-profile CLI replay, live interruption acceptance, owner cleanup
and calibration acceptance remain open; no delivery milestone is closed.

File-backed CLI and owner isolation (2026-10-11): The CLI now exercises both
initial profiles with twenty sealed raw trials under one lease, publishes a
complete report, and preserves its decisions through online/offline verification
and completed-session resume without redispatch. A second control retains a known
runtime defect with process exit zero and returns exit 1 throughout. The remote
and CLI suites pass (154 and 143 examples). Replay rejects unlinked trial/cell
directories even when their local inventory and receipt have been resealed.
Both controls also reconstruct an interrupted checkpoint after comparison
publication but before the attempt-result and root completion writes. Resume
keeps the original comparison bytes, replaces a partial result write atomically,
and dispatches no new trials; five focused CLI controls pass after that change.
Owner commit `022bcba` in `mori://shinzui/load-testing-infra` adds generic
payload-owned shared-file cleanup and supervised-unit ownership/control-group
checks, with sealed cleanup counts. Its 62 Rust library examples and three CLI
examples pass, with one unrelated opt-in example ignored. These are synthetic
protocol and local isolation controls, not live benchmark calibration. Broader
process isolation, repeated-failure quarantine with verified recovery, both-arm
pre-staging, the owner admission probe, Linux preparation/cache acceptance, live
cell acceptance, both calibration batches and CI/local parity remain unfinished.

Cache identity correction (2026-10-11): Generated cohort names now hash the
resolved descriptor rather than the whole measurement request or arm label.
Source controls verify unchanged baseline identity across measurement settings,
unrelated candidate revisions and A/A-to-baseline use; source, compiler, index and
fixed-dependency changes invalidate it. Prepared controls replay old identities,
accept new identities and reject mixed rules or a rehashed arbitrary alias.
Fifty-five core performance controls and fourteen focused CLI controls pass.
The full `nix develop -c just verify` also passes with this correction: 116 core,
154 remote and 143 CLI examples, the remaining package tests, link proof,
23 ADRs, six guides, schemas and self-tests. Its local diagnostic log is
`.dev/perf-ep25-cache-final-verify.log`. These are local identity/replay controls;
they do not close live no-compilation cache
acceptance or any delivery milestone.

Clean CLI planning control (2026-10-11): Harness commit
`3df07298bdf2a5cef865c6102e55bd4f4937b6f6` planned the compatible Shibuya
`7512b5c692af1c005392e4445cfa26a9be41f9ea` A/A request with seeds 20261010
and 20261011. Both invocations independently verified the registered upstream,
retained two selected profiles, and produced identical baseline/candidate cohort
documents while retaining distinct request digests. The generated cohort is
`perf-f50d2378f949070073894841d882f6dee49471dd82bc27d69e136484ba18eec9`.
Local diagnostic evidence is `.dev/perf-ep25-cache-plan-1` and
`.dev/perf-ep25-cache-plan-2`. Both reports remain non-gating; planning built no
payload and acquired no lease. This verifies CLI naming, not live cache reuse.

Preparation resumed (2026-10-11 local): GCP token authentication and Linux
builder transport now work. Fresh preparation at harness `afb22ba` retained
`.dev/perf-ep25-live-preparation-2` and rejected `aeson` metadata before any
lease. The old null-input assertion incorrectly classified compiler-provided
libraries as missing production dependencies. Authenticated selection now retains
Cabal's pre-existing compiler inventory and checks production argument names,
allowing only independently identified compiler libraries to resolve as null.
Four authenticated-index controls and six pure Nix dependency controls pass;
the latter is registered in `schemas-check`. Fresh clean-harness preparation
and no-compilation cache acceptance remain pending. The user authorized the existing Linux performance machine. Cloud discovery
identified the running `nix-builder-x86` builder and the designated `alpha` cell
in `tan-nb-exp`, `us-west1-a`; connection settings are now known. The repository
still has zero GitHub environments and self-hosted runners; CI configuration
remains unfinished.


Owner quarantine and account isolation (2026-10-11 local): Commit `fd9f560` in
`mori://shinzui/load-testing-infra` persists consecutive reset failures, fences
the cell after two failures and requires a current, fence-bound recovery lease
plus freshly retrieved cold-reset/raw-health evidence before conditional clear.
Local controls reject forged passing summaries, discontinuous observations,
stale fences, changed leases, images and artifacts. Commit `990f22a` drains the
dedicated payload account after supervised-unit cleanup and restricts payload
privileges and writable paths. Sixty-nine Rust library examples and three CLI
examples pass, with one unrelated opt-in example ignored; `nix build .#cellctl`
also passes. Commit `d91f2e5` exports image artifacts through Nix before inspecting
them outside the store; controls reject duplicate, missing, corrupt and symlink
archives and unrelated cleanup targets. Upgraded image publication is running;
no upgraded-cell live acceptance is claimed. Both-arm pre-staging, the admission
probe and forced live controls remain open.

Fresh validation and Linux preparation (2026-10-11 local): Harness `232dc6c`
passes the full `nix develop -c just verify`, including 116 core, 154 remote,
143 CLI examples, remaining package tests, schemas, link proof, 23 ADRs and six
guides. The real `.dev/perf-ep25-live-preparation-3` passed authenticated compiler
argument checking and generated further Linux metadata, then the builder stopped
at 21:00 local and the transport closed during `cabal2nix-postgresql-binary`.
Preparation exited 4 and acquired no lease. The builder restarted; direct
inventory retry retains `.dev/perf-ep25-live-inventory-3.json` and its log.
Payload publication and no-compilation cache acceptance remain unverified.

Owner admission tooling (2026-10-11 local): Commits `00257b8` and `cec8b80` in
`mori://shinzui/load-testing-infra` add serial warm/stopped admission probes,
first-operation timestamps, strict result schemas and retained per-observation
evidence. Four probe controls and the image-export controls pass; the Linux hello
fixture builds. The observed admission latency conservatively includes status
polling and retrieval. No live observations have run yet. Image registration
exposed an Ubuntu login-shell logout hook that changed successful cleanup into
exit 1; owner commit `9f3979a` uses a non-login shell with an explicit tool path.
Driver and PostgreSQL 17 images are registered; the other images are building.
The builder's idle timer is temporarily stopped with a four-hour restoration
timer armed, to prevent its watchdog interrupting authenticated metadata builds.
Restore it when the builds finish. No cell idle policy was changed.

Native dependency correction (2026-10-11 local): Inventory retry passed metadata
downloads after a transient Hackage HTTP/2 failure, then rejected an infinite
recursion in `zlib`. The generated call bypassed the native argument overrides
present in the pinned upstream package set. Native inputs now resolve explicitly
from the spliced system package set; nine pure dependency controls pass, including
native name collision, missing native input and ambiguous argument rejection.
The pinned upstream source was consulted after Mori found no registered Nixpkgs
source. No version, source hash or bound was changed. Fresh Linux preparation is
still required; no milestone is closed.

## Surprises & Discoveries

2026-10-11 implementation: The generated Cabal-to-Nix function has a native
`zlib` parameter. Haskell `callPackage` resolves that name to its own Haskell
package unless it is explicitly overridden, producing an infinite derivation
cycle. The pinned Nixpkgs package-set generator explicitly passes `pkgs.zlib`.
Generated preparation now reproduces that native dependency distinction rather
than relying on the default Haskell scope.


2026-10-11 implementation: The pinned Nix GHC package set deliberately represents
`base`, `bytestring`, `containers` and other compiler-provided libraries as null.
The strict generated-overlay assertion rejected those valid production inputs.
Named production dependencies now distinguish authenticated compiler libraries,
unavailable production packages and absent disabled-test parameters. Mori had
no registered Nixpkgs source; the pinned upstream package-set and GHC configuration
were read from the authoritative NixOS repository. No dependency pin was changed.


2026-10-11 implementation: Naming a cohort from the request digest invalidated
an unchanged baseline payload whenever a seed, profile, cell or candidate changed.
Arm-specific descriptions also prevented reuse when an A/A source became an
ordinary baseline. The resolved descriptor now supplies build identity, while
the request digest continues to seal scope and execution settings. Existing
v1 preparations replay only under the exact original naming rule, preserving
historic evidence without accepting arbitrary cohort aliases.

2026-10-11 implementation: Writing an attempt comparison before its root completion
checkpoint can leave a valid comparison alongside a missing or partial result.
Recomputing it with a new analysis ID would rewrite retained evidence despite
identical trials. `kenshou-cli/src/Kenshou/Cli/Command/Perf/Session.hs` now uses
atomic comparison/result/receipt writes and reuses the original comparison only
after independent semantic replay matches. File-backed controls cover this
boundary for both a healthy run and an exit-zero known runtime defect.

2026-10-10 review: `compareMetrics` in
`kenshou-measure/src/Kenshou/Measure/Compare.hs` compares only metric names present
in every input run and matched by a policy rule. It does not require a specific
metric set or check that units agree. A missing latency metric can therefore
leave other passing metrics and a passing comparison. The new profile admission
checks must verify required metrics before accepting that comparison.

2026-10-10 review: Both initial benchmark modules replace configured phases with
zero warm-up, a fixed message count, and zero cooldown, and impose a 180-second
timeout. Catalog phase declarations alone cannot change their measured behavior.
Milestone 2 must either describe that behavior exactly or implement and test a
new scenario revision before calibration.


2026-10-10 implementation: Resolved knob and dimension defaults are part of the
workload digest. Hashing catalog overrides alone would leave a change to a
scenario default invisible. Calibration references are excluded from that digest
to avoid a self-referential promotion cycle.

2026-10-10 implementation: Nix package settings can be overridden after initial
construction. Inspecting initial arguments or missing derivation attributes
misreported effective bound lifting and description revisions. Final builder
argument inspection now records those settings, and strict preparation applies
bound enforcement after package overrides. The legacy Nix outputs retain their
existing behavior.

2026-10-10 implementation: The locked Nix package set and a compatible Cabal
selection can differ transitively. Constraining Cabal to the default Nix versions
rejected an otherwise compatible full cohort. Generated performance builds now
use authenticated Cabal source and description hashes, including the selected
historical description revision; subsequent inventory/bounds checks and strict
compilation remain mandatory. An absent `pkg-revision` in the installed Cabal's
plan does not mean revision zero: the selected description digest identifies it
in the authenticated index.

## Decision Log


2026-10-11: Derive new cohort identities from resolved build inputs, preserving
baseline reuse across request changes. Read legacy prepared identities only when
both arms match the exact original request-derived rule; do not mix naming rules
within a preparation. [ADR-23](../adr/0023-pin-performance-gates-to-independent-preparation-and-calibration-evidence.md)
records the separate request/build identity constraints.

2026-10-10: Reuse the existing protocol and comparison engine; place generic cell
repairs in `mori://shinzui/load-testing-infra`. Kenshou owns change selection,
workloads, statistics, and the user-facing verdict. This preserves the existing
ownership boundary and avoids a second benchmark runner.

2026-10-10: Use immutable HTTPS Git commits for candidate runtime sources and a
clean, separately identified harness commit. Local uncommitted runtime source is
outside the first gating workflow. Generate request-specific cohorts outside the
user's active checkout state, so two preparations cannot overwrite each other's
Cabal plans or alter the historical released cohort.

2026-10-10: Fix trial counts in advance, defaulting to five valid pairs. Replace
only objectively invalid infrastructure trials within a bounded allowance. Do
not keep sampling an unfavorable or inconclusive comparison until it passes;
that would change the statistical interpretation. Runtime assertion failures
remain blockers even when a later attempt succeeds.

2026-10-10: Treat turnaround targets and detection sensitivity as acceptance
criteria to measure, not current service guarantees. Keep a separate budget for
build preparation, admission, and measurement. Do not weaken statistical limits
or silently remove affected configurations to meet a time target.

2026-10-10 review: Pin calibration purpose and A/A control in the request before
selection and preparation. Require metric completeness independently of the
existing statistical calculation, and carry deadlines and retry counters across
resume. These constraints close paths by which a narrowed or restarted request
could otherwise appear to satisfy its original acceptance contract.


## Outcomes & Retrospective


Partial implementation (2026-10-11): The `perf plan/prepare/run/status/resume/verify`
command family, calibration admission/declaration commands, protected CI entry
point and operator guide are implemented. Local protocol controls cover two-profile
execution, retained exit-zero runtime defects, interrupted completion writes,
lease-loss recovery, artifact tampering and independent raw health replay. Owner
commits `915fb2f` and `022bcba` in `mori://shinzui/load-testing-infra` add sealed
execution windows and bounded supervised-unit/shared-file isolation.

All six milestones remain open. No live Linux payload/cache acceptance, designated
cell admission/isolation/recovery acceptance, eighty-comparison calibration batch
or actual CI/local parity has completed. Owner reset-failure quarantine, verified recovery and broader account/process
isolation now pass local controls; upgraded images and live acceptance remain
pending. Remaining implementation includes both-arm pre-staging, an owner
admission probe and additional CLI interruption controls. Do not promote either initial profile based on synthetic controls.

GCP authentication is restored, and the user authorized use of the existing
Linux performance machine. The builder is `nix-builder-x86` and the designated
cell is `alpha`, in `tan-nb-exp`, `us-west1-a`. Live image publication and Linux
preparation are in progress. The repository API still reports zero GitHub
environments and self-hosted runners; protected CI configuration and actual
parity remain unfinished.


## Context and Orientation


Work from the `keiro-runtime-kenshou` repository root. `kenshou-core` defines
cohorts, scenarios, immutable run specifications, and change-aware planning.
`kenshou-measure` computes measurements and statistical comparisons.
`kenshou-remote` provides payloads, leases, submissions, and verified retrieval.
`kenshou-cli` assembles these libraries with the scenario packages. A payload is
a content-addressed archive containing an executable and its runtime dependencies;
its digest identifies the actual bytes delivered to a cell.

The planner's relevant files are `kenshou-core/src/Kenshou/Plan/Change.hs`,
`kenshou-core/src/Kenshou/Plan/Change/Git.hs`,
`kenshou-core/src/Kenshou/Plan/Components.hs`,
`kenshou-core/src/Kenshou/Plan/Suite.hs`,
`kenshou-core/src/Kenshou/Plan/RunPlan.hs`, and
`kenshou-core/data/components.json`. The `suites/change.json` suite currently
selects local correctness and concurrency cases only. `docs/planning.md` describes
existing `--upstream-diff`, `--changed`, selection explanations, and conservative
selection of all affected work when a change cannot be mapped safely.

`kenshou-remote/src/Kenshou/Remote/Payload/Publisher.hs` currently restricts
publication to `released` and `head`. `scripts/payload-lock.sh` has the same
restriction. `nix/kenshou/packages.nix` loads a named descriptor and source lock;
`nix/kenshou/cohort-overlay.nix` replaces the runtime packages, and
`nix/kenshou/identity.nix` emits identity documents. The overlay currently applies
`doJailbreak`, which removes Cabal bounds during the Nix build. A successful build
therefore does not establish declared dependency compatibility. Generated cohort
support must retain an independent bounds/exception check and resolved identity
check, rather than interpreting successful Nix linking as sufficient evidence.

`kenshou-remote/src/Kenshou/Remote/Pair.hs` supplies `pairPlan` and `judgePairs`.
`kenshou-cli/src/Kenshou/Cli/Command/Cell.hs` supplies `runPair`,
`pairUnderLease`, `collectPairObservations`, and `finishPair`. The visible command
currently accepts one benchmark configuration, uses cold reset for each trial,
and writes `comparison.json`. It has per-round cell journals, but a new invocation
refuses an existing output directory; there is no complete top-level paired
resume workflow. Its validity test combines cell success and entry exit code,
so the new orchestration must distinguish runtime failures from replaceable
infrastructure failures. Session machinery lives under
`kenshou-remote/src/Kenshou/Remote/Cell/Session/`.

`policies/default.json` requires five pairs and 95% confidence, including both
relative and absolute effect thresholds. `kenshou-measure/src/Kenshou/Measure/Compare.hs`
already gives unhealthy or incomparable evidence precedence over statistics.
Retain that calculation and add profile-specific metric completeness checks
around it. Its `compareRuns` also creates a fresh comparison ID, timestamps, and
analysis-host fingerprint on every invocation; replay must compare semantic
results rather than require byte-identical newly generated comparison documents.
`docs/reports/2026-10-10-shibuya-latest-timings.md`
records 30 successful local runs but two inconclusive performance comparisons;
the paced throughput was not a capacity measurement. Its
`docs/reports/data/2026-10-10-shibuya-timings/run-pairs.py` demonstrates the
manual work to replace, not a second production engine to preserve.

The initial workload implementation points are
`kenshou-shibuya/src/Kenshou/Suite/Shibuya/Bench/ConcurrencySweep.hs` and
`kenshou-shibuya/src/Kenshou/Suite/Shibuya/Bench/PgmqEndToEnd.hs`.
`kenshou-cli/src/Kenshou/Cli/Registry.hs` registers commands.
`.github/workflows/ci.yaml` currently builds, tests, and checks the harness; it
does not provide runtime-project performance comparisons or a GCP authentication
step. `docs/guides/running-on-gcp.md` describes operator `gcloud` authentication
and a remote Linux builder, not a configured GitHub cloud identity. CI identity
and builder availability are explicit Milestone 6 prerequisites. Existing test
suites include `kenshou-core-test`, `kenshou-remote-test`, and `kenshou-cli-test`; confirm
their Cabal declarations before extending their module lists.

Relevant architecture decisions were read during creation. [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md)
requires resolved package/source identities, immutable Git sources, and explicit
scope for isolated layer cohorts. [ADR-3](../adr/0003-kenshou-owns-the-runtime-verification-protocol.md)
keeps versioned protocols in Kenshou and defines exit codes.
[ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md) requires
explainable dependent selection and telemetry-enabled configurations for
observability changes. [ADR-6](../adr/0006-comparison-verdicts-require-controlled-benchmark-evidence.md)
requires paired, interleaved, durable, controlled evidence. It also requires
Kiroku comparisons to account for each arm's measured stable pool optimum;
do not extend a fixed-pool profile to Kiroku capacity claims without that work.
[ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md)
keeps records immutable and baselines derived from compatible confirmed evidence.
[ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md) requires
verified Nix cohort identities. [ADR-21](../adr/0021-address-cell-runs-by-submission-and-nested-run.md)
requires both submission and nested run identities and makes cell failure
override a nested success without changing either sealed document.

The generic infrastructure owner is `mori://shinzui/load-testing-infra`, located
with `mori path`. Within that project, consult project-relative
`docs/cells/protocol.md`, `docs/cells/determinism.md`,
`nixos/pkgs/cell-agent/src/`, and `scripts/cell/` (artifact-level URIs pending).
Its request is
`mori://shinzui/load-testing-infra/okf/improvement-requests/concepts/IR-1`.
Local plans [EP-16](16-provide-leased-verification-cells-in-load-testing-infra.md)
and [EP-17](17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md)
record the existing cell implementation and live evidence. Those records include
successful A/A pairing and ordinary health observations, but some acceptance
remains open, including general contamination cleanup and forced health failures.
Do not infer that an unchecked acceptance item is implemented or tested. The
owner's admission targets are p95 at most 90 seconds warm and 180 seconds stopped;
sample transcripts in plans are not measurement evidence.


## Plan of Work


### Milestone 1: Prepare exact-revision requests and reusable payloads


Add `Kenshou.Perf.Request` and `Kenshou.Perf.Prepared` in `kenshou-core`, with
hand-written codecs and schemas `schemas/kenshou.perf-request.v1.schema.json`
and `schemas/kenshou.perf-prepared.v1.schema.json`. Introduce the
`kenshou perf plan` and `kenshou perf prepare` CLI surface in
`kenshou-cli/src/Kenshou/Cli/Command/Perf.hs` and register it in
`kenshou-cli/src/Kenshou/Cli/Registry.hs`. The plan operation resolves the request
and explains intended scope without leasing or building. Preparation resolves
both arms and builds/publishes their payloads without holding a cell lease.

A request names a canonical project URI, full baseline and candidate commits, a
cohort-template path, an explicit target-component set, a suite, a profile set,
coverage mode, purpose (`"gating"` by default or `"calibration"`), control
(`"none"` by default or `"aa"`), a seed, a cell pool, a wait budget, and an
execution budget. Resolve
sources through Mori and verify the requested commits exist in the identified
HTTPS upstream repository. Changing a mutable branch after preparation must not
change either executable. Reject unknown components, a revision belonging to the
wrong repository, local-path sources, dirty harness inputs for gating, or a
package-set mismatch before publication. Read source manifests at each commit
rather than assuming package versions and subdirectories are unchanged.

Target-component IDs are cohort descriptor IDs, not component-graph node IDs.
Expand their package lists into graph nodes for selection and inventory checks.
This version accepts one source project and revision pair: reject targets whose
package sources belong to another repository rather than applying one commit
to several repositories. Keep all non-target sources fixed by the template.
Pin normalized request fields, template contents, graph/catalog/profile/policy
digests, and resolved commits in `prepared.json`; `run` and `resume` must not
reload mutable catalog or template files as authoritative inputs.

Create generated cohort inputs beneath the preparation directory, with separate
Cabal build directories for both arms. Parameterize the Nix package function over
explicit descriptor and lock inputs while preserving existing released/head
outputs. Pass generated inputs as immutable build inputs, not edits to the
harness checkout. Extend the publisher to accept this prepared build target.
Record the clean harness commit separately from the generated cohort documents
and their digests; never mark generated inputs as proof of a clean harness. Add
complete resolved build inventories, including relevant transitive sources,
compiler, flags, and toolchain pins, to the prepared evidence. A changed build
artifact hash caused by relinking is expected; an unrelated dependency's source,
version, flag, or toolchain change is not.

Compare inventories before leasing. Only the declared target components may
change source or version. Report incompatible bounds as a preparation failure;
never introduce blanket bound lifting. If a compatible isolated layer template
is needed, name that scope in both arms and mark downstream full-runtime coverage
unavailable. A broader cohort comparison requires a separate request explicitly
declaring its additional changing components. Before choosing any new dependency
pin or workaround, use Mori for source/API discovery and check the authoritative
package registry and upstream release tags; this plan selects no new versions.

Reuse artifacts by a build key over the harness commit, full resolved input
inventory, descriptor/source-lock digests, platform, variant, and build flags.
Revalidate a cache hit's recorded identity and bundle digest. Keep build cache
writes separate from measurement and retain failed build logs. Acceptance is a
same-source request that reuses the payload on its second preparation, plus a
candidate-only edit that produces a distinct payload while all unrelated source
inputs remain equal. Concurrent preparations must leave `cohort/active.project`,
`cohort/released.json`, and each other's build plans unchanged.


### Milestone 2: Select a bounded, explicit performance scope


Add `suites/change-performance.json` and a versioned profile catalog under
`policies/performance/`, with a catalog schema under `schemas/`. A profile names a
scenario revision, effective knobs and dimensions, workload purpose, warm-up and
measurement windows, cache and durability policy, comparison policy digest,
required cell capabilities, calibrated machine profile, and supporting calibration
artifact. A profile distinguishes fixed-load latency from capacity; a paced
throughput near the offered rate cannot certify peak capacity. Initially register
candidate profiles for Shibuya core and PGMQ end-to-end, marked uncalibrated until
Milestone 5. Reuse existing metric names and policies when appropriate.

Use the existing component graph and upstream diff mapper to compute affected
scenarios before applying the fast-suite profile catalog. Account for dependent
paths and telemetry corners. Emit selected configurations, selection reasons,
unmapped inputs, unsupported/uncalibrated affected paths, and budget exclusions.
A documented exclusion from this deliberately limited suite is visible scope,
not proof for the omitted path. An affected path requiring evidence but lacking a
calibrated profile prevents full change acceptance. Documentation-only changes
may be `not-applicable` only with the repository-scoped source-root proof required
by ADR-5; an empty accidental selection is inconclusive.

Before filtering for calibration, inspect the pinned request purpose. A
calibration request can select explicit uncalibrated profiles and marks every
result non-gating; a gating request cannot. A/A control retains its explicit
profile list even for an empty source diff. Neither exception bypasses workload,
environment, metric, or source-identity checks. Test this flow from `perf plan`
through preparation, not only by toggling a flag at execution time.

Each profile enumerates required metric names, units, and minimum steady sample
counts, with a matching policy rule for every required metric. Before comparing,
verify these against every retained arm and recompute summaries from raw samples.
Missing or under-sampled required metrics make the configuration inconclusive;
unit/schema mismatches or summary/digest corruption make it invalid evidence.
Neither condition is a valid pass or a statistical retry. Test a missing p99
metric while throughput remains present and passing, a changed unit, and a
required metric with no policy rule. Apply the same checks in offline verification.

For the initial scenarios, start with the existing count-bound, zero-warm-up
behavior and record it explicitly in each candidate profile. Validate the actual
steady count and phase boundaries in retained samples. If calibration requires
warm-up or a longer window, change the relevant scenario module and its revision,
including the fixed 180-second timeout and allowed knob ranges where necessary;
prove warm-up samples are excluded before rerunning calibration. Reject profiles
whose requested phases the selected scenario revision does not honor.

Use `coverageMode: "affected"` by default: every affected path requiring evidence
must have an admitted calibrated profile or the aggregate is incomplete. Permit
`coverageMode: "selected-profiles"` only with an explicit nonempty profile list.
That mode judges completion of the requested profiles and separately reports
`changeCoverage` for all affected paths. It never silently narrows an affected-mode
request. The initial acceptance and example caller use selected-profiles mode;
the CI check name must say which profiles it accepted. Test that changing modes
changes the request digest and cannot be used while resuming an existing session.

Estimate cost using both arms, required pairs, per-trial reset/settle and sealing,
and a bounded infrastructure-replacement allowance. The default request allows
30 minutes of execution after payloads are ready and no more than two replacement
pairs per configuration. Admission waiting is separately bounded. Admit complete
configurations; never cut a pair or drop dimensions silently. If required work
cannot fit, the planning result identifies deferred coverage and the eventual
result cannot be a complete pass. Acceptance tests cover a direct change, a
transitive dependent, telemetry, unmapped source changes, a proven documentation
change, and a request exceeding the budget.


### Milestone 3: Execute and recover a complete comparison session


Extract reusable paired execution from `kenshou-cli/src/Kenshou/Cli/Command/Cell.hs`
into `kenshou-remote/src/Kenshou/Remote/Perf/Runner.hs` and put durable orchestration
state in `kenshou-remote/src/Kenshou/Remote/Perf/Journal.hs`. Keep `cell pair`
backward compatible. Add `kenshou perf run`, `status`, `resume`, and `verify`.
The runner consumes the prepared request and catalog-pinned plan. It groups
compatible configurations onto one cell lease, executes them serially, and
resets between every arm. Different PostgreSQL majors require compatible cells;
never move the arms of one pair to different cells or leases. Use only one cell
at a time in the initial orchestrator, with a deterministic pool ordering and
bounded waits; building a global scheduling service is outside this plan.

On first `run`, persist a cumulative admission-wait allowance; after the first
lease acquisition, persist a fixed execution deadline. Execution time includes
resets, trials, sealing, retrieval, publication, and any subsequent lease waiting;
only initial admission precedes that deadline. Report total elapsed time
separately. Resume retains spent allowances, all replacement counts, and the
original deadline, including client downtime. Acquiring a new lease does not
reset them. Reserve a separately reported bounded cleanup grace period that
can seal/cancel owned work but cannot collect additional measurement pairs.
Test repeated interruption and lease loss near the deadline; neither may extend
the request's measurement budget or start an unbudgeted fresh comparison.

Keep the existing cold-reset default for authoritative pair execution. If a
profile measures warmed application behavior, run identical declared warm-up
phases after reset and exclude warm-up samples. Do not conflate a VM being warm
with the operating-system or database cache policy. Persist a precomputed ABBA
or BAAB schedule, matched seeds, requested pair count, policy digest, and all
submission identities before side effects. A new comparison uses five valid
pairs unless its profile's validated policy requires more.

Classify attempts using both the cell effective outcome and nested assertions.
An infrastructure-invalid pair may be replaced up to the predeclared limit; both
old arms remain in the evidence. An assertion failure in either arm, incomplete
work, wrong result, or new blocking runtime defect blocks acceptance and is not erased
by replacement. Never use shell exit zero alone: a reproduced known defect may
also have exit zero. A noisy but otherwise valid pair is not an infrastructure
retry. Collect the fixed valid-pair count and calculate once; a longer follow-up
is a separately identified request, not silent optional stopping.

A resume verifies the request, payload, policy, journal, and sealed digests before
reconciling submissions with the cell. After lease loss, retain sealed pairs from
the old lease as a separate comparison attempt and start a fresh complete paired
comparison for the interrupted configuration; do not aggregate across changed
lease/host environments to obtain five pairs. Already completed configuration
comparisons remain reusable. An ambiguous submission is observed by its existing
ID before any new work is submitted. There must be no duplicate active execution.

Add schemas `schemas/kenshou.perf-plan.v1.schema.json`,
`schemas/kenshou.perf-session.v1.schema.json`, and
`schemas/kenshou.perf-result.v1.schema.json`, with compatible golden fixtures.
Write a versioned aggregate result and a compact Markdown report. Each
configuration retains the ordinary `comparison.json`; the aggregate records all
attempts, valid/invalid pair counts and reasons, workload scope, effect intervals,
thresholds, exclusions, stage timings, and immutable evidence references. Preserve
separate performance verdict, runtime blockers, coverage state, and infrastructure
state. Exits are 0 only for complete accepted scope (or explicit proven
not-applicable), 1 for a valid regression or runtime blocker, 2 for malformed
input, 3 for inconclusive/incomplete scope, and 4 for infrastructure/preparation
failure. If infrastructure failure and a runtime blocker coexist, return 4 and
retain the blocker explicitly; no condition is hidden by aggregation.

For mixed configurations use precedence 4, then 1, then 3, then 0 after request
validation; malformed input exits 2 before execution. Thus a proven regression
plus incomplete coverage exits 1 and retains both findings. A recovered transient
infrastructure attempt remains visible but does not itself force exit 4 once a
complete healthy comparison replaces it within the declared limits. Unresolved
infrastructure failure does force exit 4.

Offline replay must match selected input IDs/digests, policy, metric values and
intervals, reasons, and verdict. Preserve the original sealed comparison bytes
and identity; a fresh computation's generated ID, clock timestamps, and
analysis-host fingerprint are not equality criteria. Recovery reuses an already
verified comparison instead of overwriting it with a fresh ID. Test replay on a
different analysis host after cell shutdown.

Acceptance uses file-backed protocol tests to interrupt before submission, during
an arm, after sealing, and before report publication. Each recovery must retain
original attempts and digests, avoid duplicate active runs, and produce the same
comparison for the same sealed inputs. Test mixed results across configurations,
known-defect exit zero, and a runtime failure followed by a passing attempt.


### Milestone 4: Prove that quick-run cells are isolated and available


Implement generic owner changes in `mori://shinzui/load-testing-infra`, following
that project's instructions, at project-relative `scripts/cell/`,
`nixos/pkgs/cell-agent/src/`, and `infra/cells/` (artifact-level URIs pending).
Keep a canonical cross-reference to this plan in owner commits:
`mori://shinzui/keiro-runtime-kenshou/plans/25-provide-quick-and-reliable-performance-validation-for-runtime-changes`.
Inspect current owner code and recorded acceptance first; close missing items
without duplicating already demonstrated behavior. This milestone is an explicit
cross-repository dependency; Kenshou's software can be tested before it passes,
but the feature cannot be advertised as an accepted performance gate.

Designate a cell for short comparisons during development hours; route soaks to
other capacity or outside that window. Reuse the owner's idle-stop policy and
existing lifecycle commands. Reuse baseline payloads and pre-stage both arms
before measurement starts, outside timed windows. Avoid image rebuilds, compilers,
cache garbage collection, and bulk artifact transfers during measurement. Keep
monitoring collection bounded to the run window; profiles and dashboard exports
remain optional diagnostics while raw benchmark samples remain mandatory.

Prove exclusive leasing under two simultaneous requests, including an upgrade
contender. Contaminate the runner with surviving child processes and owned files,
and contaminate database state/settings; the next reset must remove the declared
contamination and verify requested settings without harming unrelated processes.
Inject maintenance/background-load and storage-pressure gate failures, missing
health observations, stale agent identity, lease loss, and consecutive reset
failures. Each must prevent authoritative success; repeated reset failures must
quarantine the cell. A recovery must not clear quarantine without the owner's
verified recovery procedure. Seal failure evidence when feasible and expose
publication failure honestly when not feasible.

Add or complete the owner's latency probe and run at least 20 warm and 20 stopped
admission observations. Measure from lease/start request to accepted submission,
report p50/p95 and every failed attempt, and separately record readiness/reset
latency to the first measured operation. Acceptance is p95 at most 90 seconds warm
and 180 seconds stopped, with no overlapping benchmark processes. Store the
underlying timing samples and sealed fixture references in a dated Kenshou report.
A missed target remains open work with a breakdown; example output cannot close
this milestone. Verify retrieval and digests after the cell is stopped.


### Milestone 5: Calibrate the initial benchmarks and time-to-verdict


Calibrate Shibuya core and PGMQ end-to-end separately on the designated cell,
using the exact profiles selected in Milestone 2. Ensure each does enough work,
retains full samples, observes steady behavior, and does not saturate the load
generator. Capture planned operations, actual completions, schedule lag, errors,
and any backlog. A profile may choose a longer window to control checkpoint or
polling noise; a short run that misses important behavior remains exploratory.
Pin the comparison policy and minimum meaningful relative and absolute effects
before running the acceptance experiment. Do not use the default policy's metric
limits as evidence that a workload can detect those limits.

Run 20 complete A/A comparisons per profile, where both arms use the same
payload. Require at least 19 passes, zero regressions, and at most one
inconclusive result. Separately use a clean test-only candidate revision that
adds a deterministic delay at the real operation boundary; preserve the workload,
knobs, harness, and unrelated dependencies. The calibration profile records the
injected mechanism and the target effect beyond both policy thresholds. Run 20
comparisons and require at least 19 detected regressions, zero passes, and at
most one inconclusive result. Infrastructure-failed comparisons are reported and
repeated under a fixed, recorded retry cap; never drop statistical outcomes.
Report these as observed calibration counts, not a proven population false-positive
rate or a universal 95% detection guarantee. Retain the injected source and its
full commit identity without merging the slowdown into a runtime release.

For each accepted profile, require p95 at most 15 minutes from verified payloads
ready to a verified durable comparison report on an uncontended warm cell,
including lease admission, resets, five pairs, sealing, retrieval, and report
publication. Use the 20 A/A exercises for these timing samples and show failures
and cache state. Separately report a cold preparation and a repeated preparation;
the repeated preparation must reuse unchanged payloads and perform no compilation.
Do not promise a universal source-build duration. The aggregate suite remains
bounded at 30 minutes; if two accepted profiles exceed that together, the report
must expose the additional budget needed rather than omit one.

Investigate missed calibration or latency targets and revise workload design
with a new profile revision, followed by a fresh predeclared acceptance batch.
A profile becomes gating only after both sensitivity and timing acceptance pass
and links to the immutable calibration evidence. Invalidate that designation when
scenario revision, relevant knobs, metric semantics, policy, toolchain, or machine
profile changes. Calibration does not establish capacity, leak freedom, recovery,
or unmeasured downstream behavior.

Provide explicit request `purpose: "calibration"` so these experiments can plan,
prepare, and execute profiles before they are calibrated. It runs the same
comparison calculation but marks the aggregate `purpose: "calibration"` and
`gatingEligible: false`. Its
exit code retains the ordinary outcome mapping, but even exit 0 is not a
production acceptance result. Ordinary CI
requests reject this mode, and a report cannot become gating merely by editing
its purpose; promotion requires the catalog revision and verified acceptance
evidence. Record a finite infrastructure retry cap before each calibration batch.

Calibration records bind the workload definition digest, required metrics,
policy, toolchain, machine profile, and frozen acceptance batch. Keep this
workload digest separate from the catalog entry's calibration-evidence link,
avoiding a self-referential digest. Promoting an unchanged workload by attaching
verified calibration evidence does not invalidate that evidence; changing a
bound workload input does.


### Milestone 6: Publish evidence and integrate runtime-project CI


Add `.github/workflows/performance-change.yaml` with a reusable workflow entry
and a manual dispatch path. Accept canonical project identity, immutable baseline
and candidate revisions, cohort template, profiles, and time budgets. Invoke the
same CLI used by developers, keep build and measurement stages separate, and
expose the result JSON and Markdown summary as workflow artifacts plus durable
object-store links. Require explicit caller configuration for an authorized GCP
identity and an available Linux builder. The current CI has neither a cloud
authentication step nor an established performance runner, so verify their
availability before live acceptance and record missing access as an unmet
prerequisite. Use a protected runner with preconfigured `gcloud` authentication
or caller-supplied workload identity federation configuration, which exchanges
GitHub's job identity for short-lived GCP credentials. Do not invent account
names or place credentials in logs. Candidate code is executable
input: keep cloud-enabled execution limited to trusted invocations, with no
privileged `pull_request_target` checkout of untrusted candidate code.

Publish the aggregate report and its manifest with create-only object semantics
in an explicitly chosen evidence bucket, retaining references to both outer cell
and nested run manifests. A result promising durable evidence cannot return 0
when publication or verification fails. Reuse the existing recorder and attester
for explicit promotion to `docs/verification`; ordinary quick runs must not
commit records into the harness checkout or automatically promote a baseline.
Baseline source is explicit in this first workflow. Historical attested baseline
selection remains a separate policy, and old timing numbers are never reused as
one arm of a new paired comparison.

Write `docs/guides/validating-runtime-change-performance.md`, update
`docs/planning.md` and `docs/guides/running-on-gcp.md`, and register the guide in
the existing guide bundle with a stable DOC handle and log entry. Explain result
scope, preparation failures, all exits, budget exhaustion, calibration expiry,
resume, publication, and escalation to a separate longer comparison. Update the
stale README status only where it describes this delivered behavior.

Demonstrate a request using commits from `mori://shinzui/shibuya`, with the core
and adapter profile coverage reported separately, through the reusable workflow
and the local command. A small example caller can be checked into this repository;
rollout to additional upstream repositories is not required to complete this
plan. The two entry points must share request semantics, digests, result schema,
and exit behavior. Distill the new generated-cohort identity, calibration, and
aggregate-gating decisions into the relevant existing ADRs or newly allocated
records using the repository's profiled ADR workflow before completion.


## Concrete Steps


All commands below run from the Kenshou repository root unless stated otherwise.
These first commands inspect existing support; they do not start cloud resources.

```bash
mori registry show shinzui/load-testing-infra --full
mori registry docs shinzui/load-testing-infra
mori path mori://shinzui/load-testing-infra
nix develop -c cabal run -v0 kenshou -- plan --graph-check
nix develop -c cabal run -v0 kenshou -- help cells
```

The following is the proposed interface to implement, not an existing command.
Create a request using full commits from a fetched, Mori-resolved upstream
checkout. Replace `BASE_SHA` and `CANDIDATE_SHA` with the actual 40-character
commits; `prepare` must reject these placeholder strings. The target-component
IDs must exist in the selected cohort template. The initial profile names are
created by this plan.

```json
{
  "schema": "kenshou.perf-request/v1",
  "project": "mori://shinzui/shibuya",
  "baselineRevision": "BASE_SHA",
  "candidateRevision": "CANDIDATE_SHA",
  "cohortTemplate": "cohort/released.json",
  "targetComponents": ["shibuya"],
  "suite": "change-performance",
  "coverageMode": "selected-profiles",
  "purpose": "gating",
  "control": "none",
  "profiles": ["shibuya-core-quick", "shibuya-pgmq-quick"],
  "seed": 20261010,
  "cells": ["alpha"],
  "waitSeconds": 90,
  "budgetMinutes": 30
}
```

For the live rehearsal, select two source-compatible commits; do not assume any
new Shibuya release is compatible with `cohort/released.json`. Use an explicitly
scoped compatible template when needed. Profiles requesting PostgreSQL 18 can
use alpha only after verifying its current descriptor and capabilities; cell
names do not permanently establish capabilities.

```bash
nix develop -c cabal run -v0 kenshou -- perf plan \
  --request perf-request.json --out .dev/perf-example-plan
nix develop -c cabal run -v0 kenshou -- perf prepare \
  --request perf-request.json --out .dev/perf-example-prepared
nix develop -c cabal run -v0 kenshou -- perf run \
  --prepared .dev/perf-example-prepared/evidence/prepared.json \
  --evidence-base-uri gs://kenshou-evidence-tan-nb-exp/performance \
  --start --out cell-pairs/perf-example
nix develop -c cabal run -v0 kenshou -- perf status \
  --session cell-pairs/perf-example
nix develop -c cabal run -v0 kenshou -- perf resume \
  --session cell-pairs/perf-example
nix develop -c cabal run -v0 kenshou -- perf verify \
  --session cell-pairs/perf-example
```

Configure the control/results buckets explicitly using the existing
allowed-project checks. `--evidence-base-uri` names the aggregate report's durable
destination; the example uses the existing evidence project, and `perf run` must
check the caller's actual access before leasing, since preparation does not
receive that destination. Persist the resolved destination
in the session. The normal output directory
contains `request.json`, `prepared.json`, `plan.json`, `session.json`,
`result.json`, `report.md`, and per-configuration comparison and attempt trees.
Machine-readable stdout is JSON; progress goes to stderr. A passing example
reports `performanceVerdict: "pass"`, `coverage: "complete"` for the requested
scope, a separate `changeCoverage` with omitted affected paths,
`blockingRuntimeFailures: []`, verified evidence references, and exit 0. A
not-applicable response names its source-root proof and never uses the word pass
for an unexecuted benchmark.

Use targeted tests during implementation, then the repository gate once the
integrated change is ready. Register new schemas and fixtures in
`justfile`'s `schemas-check` recipe.

```bash
nix develop -c cabal test kenshou-core-test kenshou-remote-test kenshou-cli-test
nix develop -c just schemas-check
nix develop -c just guides-validate
nix develop -c just adr-validate
nix develop -c just verify
```

Run live acceptance only after local contracts pass. Record actual commands,
request digests, owner image revisions, run IDs, report URIs, timings, and outcomes
in a dated file under `docs/reports/` and summarize acceptance in Progress. The
owner's new admission probe is to be implemented at project-relative
`scripts/cell/measure-accept-latency.sh` in `mori://shinzui/load-testing-infra`
(artifact-level URI pending); invoke it there with `alpha warm 20` and
`alpha stopped 20` after reviewing its semantics. Never copy a plan's illustrative
latency transcript as observed evidence.


## Validation and Acceptance


Each milestone must pass its own observable acceptance before its Progress item
is checked. Deterministic tests must prove that a request with the wrong source
revision, stale lock, unrelated dependency drift, dirty harness, or unsupported
scope fails before a lease is acquired. Golden protocol fixtures must distinguish
not-applicable, incomplete coverage, runtime failure, performance regression,
statistical inconclusive, and infrastructure failure. Unknown graph mappings and
expired calibration must never yield a pass through empty selection.

A same-payload A/A request uses `control: "aa"` in the request, which retains
the explicit selected profiles even though the source diff is empty. Reject
combining it with different baseline/candidate revisions. For the calibration
batch also set `purpose: "calibration"` before planning and preparation. Normal
no-change requests remain not-applicable only when proved. These fields are
retained in every request digest and report; execution cannot change them.
Use distinct baseline/candidate arm labels even when both reference the same
payload, and the existing `VaryControl` comparison axis. The slowdown
calibration uses an ordinary different-revision request and records its test-only
purpose. Calibration artifacts are validated independently of the production
runtime's release history.

Exercise required-metric omission, unit drift, unsupported warm-up, calibration
promotion without a digest cycle, immutable prepared selection, a changed
purpose on resume, and persistent deadline/retry limits in deterministic tests.
These are acceptance conditions for Milestones 1–3, not checks deferred to the
live calibration batch.

The live proof must include the owner admission/isolation/failure experiments,
20 A/A and 20 slowdown comparisons per initial profile, and an interrupted client
that resumes without duplicating work. A storage-tampering test must make
`perf verify` identify the changed artifact and refuse success. Verify both raw
samples and derived comparisons; a matching JSON schema alone is insufficient.
Recompute a finished report after the cell has stopped, retaining the same
verdict and evidence identities. The reusable workflow must demonstrate its
non-success handling as well as a pass, and must publish available failure
evidence when a normal step exits nonzero.

Full completion requires both initial profiles calibrated, required owner
acceptance closed, the time targets met on the declared machine/profile, and
operator/CI parity demonstrated. An unimplemented owner dependency or unexplained
latency miss is unfinished work. Broader family coverage remains explicitly
limited in the final report; performance acceptance is always scoped to the
selected calibrated workloads and their declared measurable effects.


## Idempotence and Recovery


Preparation directories are request-specific and their inputs are immutable once
prepared. An identical retry may reuse verified artifacts; differing input to the
same destination is refused. Do not alter `cohort/active.project`, overwrite the
released baseline, or reuse mutable Cabal plan files across arms. The live session
creates a new output directory; subsequent work uses `resume`. Atomic journal
writes precede submissions, and create-only publication prevents overwriting
sealed objects. Preserve unsuccessful attempts and their diagnoses.

On timeout or cancellation, stop admitting new configurations, request cancellation
of owned active work, allow bounded sealing, and release only the currently owned
lease generation. Budget exhaustion without adequate evidence yields incomplete
or inconclusive status, not success. Lease loss, missing health evidence, or an
unrecoverable publication failure yields infrastructure failure. Resume under a
new lease starts a separate comparison attempt for an unfinished configuration.
Do not mutate sealed input trees to attach later cell outcomes or new reports.

Keep build/preparation failure and cell failure recovery separate. Retry only
classified transient operations with explicit limits. No automatic reset of the
user's checkout, automatic baseline promotion, or automatic release-record commit
belongs in this workflow. Cell image repair and quarantine recovery follow the
owner project's lifecycle commands and preserve previously sealed results.


## Interfaces and Dependencies


`Kenshou.Perf.Request` owns `PerfRequest` and its schema. `Kenshou.Perf.Prepared`
owns `PreparedComparison`, holding request/harness identity, arm inventories,
source and payload digests, and declared varying components. Add
`Kenshou.Perf.Plan` for profile resolution and coverage, and
`Kenshou.Perf.Result` for `PerfResult` with per-configuration decisions and the
aggregate exit mapping. These protocol types live in `kenshou-core` and do not
import the CLI or remote execution modules.

`Kenshou.Remote.Perf.Runner` consumes a `PreparedComparison` and performance plan;
`Kenshou.Remote.Perf.Journal` records orchestration state using the existing cell
session types. The CLI supplies file paths, object-store handles, cell selection,
and output rendering. `kenshou-measure` remains the only owner of statistical
comparison. `kenshou-evidence` remains the owner of explicit historic record and
attestation operations. Update the appropriate `.cabal` exposed/test modules and
schema fixtures when adding these modules. Existing payload, run, and comparison
schema versions remain unchanged unless their wire contract actually changes;
introduce an additive new version rather than silently redefining old identity
fields to accommodate generated inputs.

The first version has no new mandatory external library. It uses the locked Nix
and Cabal environment, Git, Mori, existing storage adapters, and the owner cell
protocol. Locate dependency source with Mori before relying on an API. Never
search or traverse `/nix/store` or the filesystem root. Infrastructure control
remains in `mori://shinzui/load-testing-infra`; benchmark workload source remains
in the owning Kenshou layer. Runtime source projects are discovered from the
cohort's canonical Mori URIs, including `mori://shinzui/shibuya` and
`mori://shinzui/shibuya-pgmq-adapter` for the first acceptance scope.

Implementation commits follow Conventional Commits on the current branch unless
the user requests another branch, and include an `ExecPlan:` trailer pointing to
this repository's plan path. Cross-repository commits use the canonical plan URI
instead. Keep this document's provenance append-only through the skill scripts;
update living sections with acceptance evidence rather than recording routine
commands as progress.

Revision note (2026-10-10): Reviewed the plan against the local planning
specification, cited ADRs, source, and Mori-resolved infrastructure documentation.
Added required-metric validation, request-time calibration/control semantics,
phase/timeout compatibility, persistent recovery budgets, semantic replay rules,
and explicit CI prerequisites. Corrected the evidence-access preflight stage and
clarified component mapping and aggregate precedence. Implementation milestones
remain open; no live performance or infrastructure acceptance is claimed.
