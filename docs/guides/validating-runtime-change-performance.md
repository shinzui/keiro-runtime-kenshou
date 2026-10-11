---
type: Guide
title: Validating runtime change performance
description: Prepare exact runtime revisions, execute bounded paired comparisons, recover sessions, and verify durable performance evidence.
docId: DOC-6
tags: [performance, runtime-changes, verification-cells, evidence, ci]
generated: {by: 'codex/gpt-6.1-sol', at: '2026-10-11T09:13:18Z'}
---

# Validating runtime change performance

`kenshou perf` prepares two immutable source revisions and runs interleaved
baseline/candidate pairs on an exclusively leased verification cell. It retains
the request, generated cohorts, independent dependency inventories, raw trial
evidence, ordinary comparisons and aggregate report. This is scoped performance
evidence; it does not establish capacity, leak freedom or recovery correctness.

The command family is implemented. The initial core and PGMQ profiles are still
uncalibrated, and live build, cell, timing and CI acceptance remain open in
[Plan 25](../plans/25-provide-quick-and-reliable-performance-validation-for-runtime-changes.md).
Ordinary gating requests exclude uncalibrated profiles and return incomplete
coverage rather than a pass. Calibration admission retrieves frozen records and
replays every retained report; a catalog link alone does not enable a gate.

## Pin the request and inspect its scope

Work from a clean, committed harness in `nix develop`. Discover the source
project through `mori registry list`, `mori registry show <project> --full`, and
`mori registry docs <project>`. Use its canonical project URI and full lowercase
40-character Git commits. Register the source project on the operator machine
and CI runner; the planner verifies commits in its registered HTTPS upstream.

Create `request.json`, replacing the revision and cell placeholders:

```json
{
  "schema": "kenshou.perf-request/v1",
  "project": "mori://shinzui/shibuya",
  "baselineRevision": "<full-baseline-commit>",
  "candidateRevision": "<full-candidate-commit>",
  "cohortTemplate": "cohort/released.json",
  "targetComponents": ["shibuya"],
  "suite": "change-performance",
  "coverageMode": "selected-profiles",
  "purpose": "gating",
  "control": "none",
  "profiles": ["shibuya-core-quick", "shibuya-pgmq-quick"],
  "seed": 20261011,
  "cells": ["<designated-cell>"],
  "waitSeconds": 90,
  "budgetMinutes": 30
}
```

All target components must belong to the request's source project. This example
changes Shibuya and exercises both the core and its fixed PGMQ adapter path; an
adapter-source change requires its own owning project and target component.

```bash
kenshou perf plan --request request.json --out .dev/perf-plan-1
```

Planning acquires no lease and builds no payload. Inspect `plan.json` for selected
profiles, reasons, excluded profiles, estimates and uncovered scenarios. Inspect
`inputs.json` and both generated cohort files for pinned sources. The manifest
seals these inputs. Existing output directories are rejected.

`selected-profiles` reports acceptance for the named scope. `affected` requires
coverage of every affected scenario. `coverage` describes the requested scope;
`changeCoverage` separately describes the whole change. Unknown source paths
select conservatively. An excluded profile, unsupported affected path, budget
exclusion or missing calibration cannot silently become whole-change acceptance.

## Prepare payloads before leasing

Configure an authorized `gcloud` identity and an available `x86_64-linux` Nix
builder. Verify control-bucket create/read access and evidence-bucket create/read
access. A native Linux builder or a configured remote builder is required even
when the operator uses macOS. See [running on GCP](running-on-gcp.md) for the cell
descriptor and capability setup.

```bash
kenshou perf prepare --request request.json --out .dev/perf-preparation-1 \
  --cache .dev/perf-payload-cache --control-bucket "$CONTROL_BUCKET"
```

Preparation uses a detached clean harness checkout, generates source locks,
resolves declared Cabal bounds independently, and checks the actual Nix build
selection against those bounds. It rejects unrelated package version, source,
flag or toolchain drift before leasing. It preserves the active and released
cohorts. Preparation errors retain diagnostics under `work/`; a green build alone
is insufficient evidence that the requested cohort was built.

The output's `evidence/prepared.json` binds both payload descriptors and full
inventories. `evidence/preparation-summary.json` records cache hits and stage
times. A cache hit requires retrieving and hashing the existing payload bundle
and checking its inventory identity. Repeating preparation needs a new output
directory. Cold/repeated compilation and cache acceptance still require live
validation; no source-build duration is promised.

## Execute, recover and verify

Set `KENSHOU_GCP_ALLOWED_PROJECTS` to the approved comma-separated projects.
`KENSHOU_CELL_CAPABILITIES_DIR` selects the retained capability directory
(default `.dev/cells`). Its cell descriptors must match current cloud control
descriptors. Choose an explicit durable evidence prefix:

```bash
kenshou perf run --prepared .dev/perf-preparation-1/evidence/prepared.json \
  --evidence-base-uri "$EVIDENCE_URI" --out .dev/perf-session-1 \
  --control-bucket "$CONTROL_BUCKET" --start
kenshou perf status --session .dev/perf-session-1
kenshou perf resume --session .dev/perf-session-1
kenshou perf verify --session .dev/perf-session-1
kenshou perf verify --session .dev/perf-session-1 --offline
```

Use `--start` when stopped instances may be started after lease acquisition.
The client freshly retrieves both payloads and tests evidence access before
leasing. Each configuration uses at least five matched pairs with at most two
predeclared replacement pairs. A noisy but otherwise valid pair is retained;
replacement is for invalid infrastructure evidence. Required raw metrics, units,
sample counts, effective workload, outer health gates and cold reset must match.
A sealed known runtime defect with exit zero remains a blocker even if the
performance statistics pass or its outer pair is rejected.

`session.json` checkpoints transitions, spent admission allowance, replacement
counts, lease identities and the first execution deadline. Resume keeps those
budgets. Compatible retained leases can continue; a lost lease starts a separate
configuration attempt, and evidence from different leases is not pooled.
Completed verified configurations are reused. If the comparison file was saved
just before interruption, replay preserves its original bytes and identity when
the recomputed decision matches. Comparison, attempt-result and receipt writes
use atomic replacement so an interrupted write cannot become an accepted file.
Only one client may mutate a session. Status reads local state without cloud actions.

The client retains its proposed lease ID before claiming. If the claim response
times out, resume reconciles that same ID without claiming another lease. The
execution clock conservatively starts at the proposal that acquired the first
lease, including an interrupted claim whose acceptance is confirmed later.

The execution budget includes measurement,
reset, retrieval and report publication. Its cleanup grace permits bounded
cancellation and release; it cannot extend acceptance or publication. Release
waits for the exact owned work to reach a terminal sealed/rejected state.
Recovery cancels the exact old lease before inspecting submission markers and
collects any sealed runtime failures before starting a fresh attempt. Ambiguous
work remains fenced by its lease rather than being declared finished.
The owner's generic payload-owned file cleanup and supervised-unit cleanup have
local controls. Live contamination acceptance, broader process isolation,
repeated-failure quarantine/recovery and live interruption acceptance remain open.

The report snapshot includes `result.json`, `report.md`, an inventory manifest,
retained comparisons and nested cell evidence. Create-only storage and full
retrieval verification precede an external publication receipt. The receipt binds
the manifest, aggregate and measured elapsed time. Online verification retrieves
the durable graph; offline verification checks the retained sealed graph and
receipt. Both replay every retained attempt and compare the original comparison
bytes semantically. A completed-session resume reuses its verified receipt.

## Interpret the result

| Exit | Meaning |
| --- | --- |
| 0 | Verified scoped pass, or an explicitly reported documentation-only not-applicable result |
| 1 | Performance regression or retained runtime correctness blocker |
| 2 | Malformed request or command usage |
| 3 | Inconclusive statistics, incomplete coverage or insufficient remaining execution budget |
| 4 | Infrastructure, preparation, publication or verification failure |

When outcomes coexist, infrastructure failure takes precedence over runtime or
statistical failure, which takes precedence over incomplete coverage. The JSON
retains all configuration outcomes and runtime blockers. Read `purpose`,
`gatingEligible`, both coverage fields, exclusions, intervals, thresholds and
evidence references together. Publication failure cannot yield a verified pass.
`purpose: calibration` permits exploratory uncalibrated profiles; exit 0 in that
mode is not production acceptance. A/A uses `control: aa`, equal source revisions
and explicit profiles; a different-revision comparison uses `control: none`.

Calibration requires frozen workload/policy/toolchain/machine inputs, twenty A/A
and twenty injected-slowdown comparisons per profile, recorded infrastructure
retries and verified durable timings. Workload, metric semantics, policy,
toolchain or machine changes invalidate the designation. No current profile has
completed that acceptance. For uncovered behavior or a longer workload, run a
separate explicit comparison using [measuring and comparing](measuring-and-comparing.md);
retain its scope and budget instead of silently broadening a quick request.

## Freeze and verify a calibration batch

First pin the profile to the designated cell's actual machine profile, its
effective knobs, required metrics and policy. Download the owning cell's
`descriptor.json` and `policy.json` and calculate its identities before declaring
or running the batch:

```bash
kenshou perf calibration fingerprint --descriptor descriptor.json \
  --cell-policy policy.json
```

Copy `machineProfile` into the catalog profile and definition, and
`healthPolicySha256` into the definition. A change to image identity or health
thresholds invalidates the batch. Raw health replay requires the owner's sealed
`cell/execution-window.json` and every role's `cell/observations/*.json`, with
continuous counters, fresh agent/image identity and matching observation windows.

 Retain a clean test-only slowdown
commit and review its deterministic delay at the real operation boundary. Its
declared latency effect must exceed both the policy's relative and absolute
thresholds. Keep that candidate outside runtime releases.

Create a `kenshou.perf-calibration-definition/v1` document using
`schemas/kenshou.perf-calibration-definition.v1.schema.json`. Bind one profile's
machine/image profile and health-policy digest, workload digest, the prepared
compiler/platform/toolchain digest, the planning
inputs' `harnessSemanticsSha256`, both source commits, the injected mechanism and
target effect. Declare twenty unique seeds, a finite infrastructure retry cap
(at most twenty), and an explicit expiry. Publish before any acceptance trial:

```bash
kenshou perf calibration declare --definition definition.json \
  --uri "$CALIBRATION_DEFINITION_URI"
```

The returned URI, digest and storage timestamp anchor the frozen batch. Run one
profile per calibration request, with its declared seed. Retain all twenty A/A
and twenty slowdown slots, including every infrastructure retry. A completed
statistical result cannot be replaced with a more favorable result. Every attempt
needs a durable publication receipt; a missing receipt cannot be hidden as a
retry. A slot's A/A timing includes its retained retries. The acceptance check
requires nineteen expected verdicts, zero opposite verdicts, at most one
inconclusive verdict, no runtime blockers, and nearest-rank p95 at most 900 seconds.

Create the complete receipt inventory using
`schemas/kenshou.perf-calibration-acceptance.v1.schema.json`; its two arrays follow
the declared seed order. Publish it and construct a reference document with the
definition/acceptance URIs and SHA-256 digests:

```bash
kenshou perf calibration publish --acceptance acceptance.json \
  --uri "$CALIBRATION_ACCEPTANCE_URI"
kenshou perf calibration verify --reference reference.json \
  --prepared .dev/single-profile-preparation/evidence/prepared.json
```

Publishing an inventory does not certify it. Verification retrieves every report
graph, replays its ordinary comparisons and checks batch identities, counts,
retry bounds and timings. Planning repeats that verification before admitting a
catalog reference. Gating execution and online verification also recheck it.
The full flake lock and compiler/platform/variant bind the toolchain. The harness
source hash deliberately excludes catalog calibration links and documentation;
attaching evidence can therefore promote an unchanged workload without creating
a digest cycle. Other tracked Haskell, Cabal, Nix or Python source changes
conservatively require a fresh batch. These are protocol controls; neither initial
profile has completed a real acceptance batch.

## Configure reusable CI

`.github/workflows/performance-change.yaml` accepts the same request JSON through
`workflow_call` or manual dispatch. It separates payload preparation from cell
measurement, replays the durable report online, preserves CLI exits, publishes a
job summary, and uploads preparation/session artifacts. GitHub artifacts assist
recovery; the durable object-store manifest and receipt remain the evidence root.

The caller must configure an existing environment with required reviewers and
deployment branch restrictions, and a protected self-hosted Linux X64 runner
with a recent Node 24 capable Actions runner. Preflight checks existing protection
before scheduling cloud work. Invocations are limited to default-branch pushes
and manual dispatches. Use a full trusted Kenshou commit from its master history
as `harness-revision`; it is independent of the upstream candidate revision.

Supply `runner-labels` as a JSON array including `self-hosted`, `Linux`, `X64` and
the actual protected label; supply `environment` by its existing name.
`execution-json` has these fields:

| Field | Required value |
| --- | --- |
| `authMode` | `preconfigured` or `workload-identity` |
| `gcpProject`, `gcpIdentity` | Authorized project and exact active account or service-account email |
| `workloadIdentityProvider` | Full provider resource for federated authentication |
| `allowedProjects` | Explicit project allowlist array |
| `controlBucket`, `evidenceBaseUri` | Explicit buckets and safe `gs://bucket/prefix` destination |
| `linuxBuilder` | `native` on an x86_64 Linux runner, or its configured Nix builder specification |
| `capabilitiesDirectory`, `cacheDirectory` | Runner-owned absolute directories outside the cleaned checkout |
| `start` | Boolean allowing stopped cell startup, default false |

Provision Nix, `gcloud`, Mori's registered runtime source, capability evidence,
builder access and bucket permissions on every eligible runner. The workflow
does not provision infrastructure or infer credentials. Federation uses the
caller provider and service account; preconfigured mode checks the active
account. Credential files and payload build trees are excluded from artifacts.
CI refuses calibration requests and budgets above thirty minutes or admission
allowances above ninety seconds. A missing or inconsistent replay is exit 4.

The repository currently has no configured GitHub environment or self-hosted
runner. Live CI/local parity is pending those settings and restored cloud access.
Do not treat this workflow's presence as evidence of a completed performance gate.
