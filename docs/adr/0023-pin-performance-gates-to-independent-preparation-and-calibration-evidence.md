---
type: Architecture Decision Record
title: Pin performance gates to independent preparation and calibration evidence
description: Scoped runtime performance gates bind independently checked payload inputs, frozen calibration batches and replayable comparisons under persistent budgets.
docId: ADR-23
status: Accepted
date: 2026-10-11
timestamp: 2026-10-12T03:43:53Z
generated: {by: 'codex/gpt-6.1-sol', at: '2026-10-12T03:43:53Z'}
originatingPlan: docs/plans/25-provide-quick-and-reliable-performance-validation-for-runtime-changes.md
---

# Pin performance gates to independent preparation and calibration evidence

## Context

A payload's cohort identity proves which runtime packages were linked, as defined
in [ADR-20](0020-pin-cell-payloads-to-verified-cohort-identities.md). Comparing two
runtime commits also requires independently checking their package manifests,
declared dependency bounds and complete build selections. A solver or build that
silently changes unrelated packages cannot isolate the effect of the candidate.

A statistical pass is not whole-change acceptance when coverage is missing,
runtime assertions fail or publication cannot be verified. A benchmark policy's
thresholds also do not establish that its workload reliably detects those effects.
Recovery must preserve deadlines and observations rather than restart an experiment
with a fresh allowance.

## Decision

Generate immutable per-request cohorts without editing active/released cohorts.
Keep the harness revision separate from the runtime source revisions. Resolve
Cabal bounds independently, carry authenticated package descriptions and flags
into the strict Nix selection, and compare the actual complete inventories before
leasing. Only the requested target's source/version may differ between arms;
unrelated packages, flags and toolchain inputs must remain fixed. Cache reuse
requires bundle retrieval and byte/inventory checks.

Treat Nix compiler-provided libraries separately from absent dependencies. The
pinned package set represents GHC bundled libraries as null derivations; retain
Cabal's pre-existing compiler package identities and permit those null arguments
only for the independently selected compiler inventory. Inspect generated
production dependency names before resolution, rejecting absent or otherwise
disabled production inputs while allowing unused disabled-test arguments. This
does not authorize bound lifting or a different compiler selection.

Derive generated cohort names from the resolved descriptor, independently of the
measurement request and arm label. Seeds, cell selection, budgets and an unrelated
candidate revision must not invalidate an unchanged baseline build. The complete
build key still binds the harness revision, descriptor, source lock and both
inventories; the request digest independently binds execution scope. Existing
prepared reports retain their original names and are accepted only when both arms
match the original request-derived naming rule and pinned source manifests.

Admit each performance profile through a frozen acceptance batch, not a catalog
flag. Bind its workload, required metrics, policy, compiler/platform/toolchain,
machine profile and harness semantics. Declare seeds and infrastructure retries
before trials. Replay all retained A/A and slowdown reports, including retries,
and require the declared statistical and timing acceptance. A known runtime
failure invalidates calibration. No initial profile is considered calibrated
until its actual live acceptance is recorded.

Exclude the calibration link from the workload digest and the harness commit
from the stable toolchain digest. Bind the full flake lock and a separate hash of
tracked executable/build sources. Catalog promotion and documentation changes
can then preserve an unchanged workload; source, toolchain, policy, metric or
machine changes require fresh evidence.

Persist the request, selected scope, first execution deadline, admission spent,
replacement identities and runtime blockers. Never pool pairs across lost leases.
Replay completed and abandoned attempts against their journaled leases, scheduled
seeds, payloads and raw metrics. Keep original comparison bytes. Requested-scope
coverage and whole-change coverage remain separate report fields.

Keep statistical outcomes, runtime blockers, infrastructure and coverage separate.
Aggregate precedence is infrastructure failure (4), regression/runtime failure (1),
inconclusive/incomplete (3), then verified scoped pass (0). Malformed usage is 2.
Calibration-purpose results remain non-gating, including exit zero.

Publish with create-only semantics, retrieve every artifact and retain a receipt
binding the snapshot and elapsed time. Publication must fit the original execution
deadline; cleanup grace cannot grant acceptance time. Release only the exact owned
work after a terminal sealed/rejected state. Protected CI uses the same CLI with
explicit identity, Linux builder and environment settings, and independently
replays its durable report.

## Consequences

Uncalibrated or uncovered paths remain incomplete rather than green. Frozen
calibration verification adds preparation/read costs and requires all attempts to
have durable evidence. Conservative source hashing can require a fresh batch after
changes outside a particular scenario. Synthetic protocol checks do not establish
cell latency, isolation, sensitivity or live CI acceptance. Those remain separate
observable outcomes in the originating plan.
