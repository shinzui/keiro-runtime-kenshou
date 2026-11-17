---
id: 24
slug: run-the-first-repair-verification-round-against-a-fixed-cohort
title: "Run the first repair-verification round against a fixed cohort"
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
      note: "Run broad release refresh before automation with frozen evidence and controlled comparisons"
---

# Run the first repair-verification round against a fixed cohort

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current as milestones are accepted.


## Purpose / Big Picture

Run a fresh release-wide verification of the Keiro runtime after the releases
since the original baseline. The result must show what still passes, which known
defects no longer reproduce, which still reproduce, what regressed, what changed
in performance, and what could not be tested. This is EP-5 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It is the first execution target and has no hard dependency on the unbuilt owner
and round commands in the other children.

Use existing harness commands and a reviewed manual owner/scope audit. Generic
new tooling belongs in `mori://shinzui/kenshou`; this plan does not implement it
or adopt an unpublished harness. The historical `released` cohort remains
unchanged. Create a separate `round-1` released candidate and a dated report
`docs/reports/<date>-round-1.md`, with frozen inputs in `rounds/1/`.


## Progress

- [ ] Milestone 1: freeze historical evidence and verify current package releases,
  owner claims, and prerequisites; retain a dated inventory and baseline run index.
- [ ] Milestone 2: pin and build a compatible released `round-1` cohort, prove its
  resolved identity and full catalog, and audit applicable defect scopes.
- [ ] Milestone 3: execute the broad functional/concurrency matrix and targeted
  diagnostic/soak controls, retaining both results and explicit coverage gaps.
- [ ] Milestone 4: run fresh paired performance comparisons with retained samples
  and explicit evidence quality, without promoting historical local timings.
- [ ] Milestone 5: record/attest publishable evidence and publish the baseline vs
  candidate report, including findings, remaining blockers, and automation inputs.


## Surprises & Discoveries

The [October 10 Shibuya exercise](../reports/2026-10-10-shibuya-latest-timings.md)
already tested newer isolated packages. It disabled Keiro schema support and
retained only local exploratory timings. It is supporting history, not proof
that the whole runtime builds or passes on the new cohort.

Mori lookup failed during the 2026-11-17 planning update because its configured
PostgreSQL socket was absent. No current release inventory or owner-state audit
has been completed. Restore the documented Mori service before selecting pins;
retain failure details if it remains unavailable.


## Decision Log

- Decision: The candidate cohort contains only released fixes; `unreleased` fixes wait for a
  later round or a head cohort.
  Rationale: A release is what services consume, and the bug-report profile reserves
  `unreleased` for a fix on the default branch only. Verifying a git pin proves a commit, not
  the artifact consumers will install. pgmq-hs BUG-1 (`fixedVersion: unreleased` on 2026-10-01)
  is therefore reported `not-yet-released` in round 1.
  Date: 2026-10-01

- Decision: Run this release refresh first using existing commands, without an
  EP-4 prerequisite. The other children integrate future released upstream tools.
  Rationale: Owner lookup and scope checks can be recorded manually; they should
  not delay a broad rerun. Generic harness implementation belongs upstream.
  Date: 2026-11-17

- Decision: Prefer current compatible normal releases across the entire cohort,
  recording any package held back and why, rather than the smallest versions
  that contain the October 1 fixes.
  Rationale: The requested comparison concerns releases since the baseline, not
  only the fixes known at the original plan's creation.
  Date: 2026-11-17


## Outcomes & Retrospective

Planning updated on 2026-11-17. Tests, new pins, and comparison results remain
pending; the October 1 release observations above must be rechecked.


## Context and Orientation

This repository assembles layer bundles for PGMQ, Kiroku, Shibuya, Kafka, Keiro,
and the runtime. Existing generic packages remain local until adoption of a
published extracted Kenshou release; this plan may use those copies. Read
`docs/planning.md`, `docs/guides/recording-evidence.md`,
`docs/guides/measuring-and-comparing.md`, and `docs/guides/running-on-gcp.md`.
The Shibuya-only runbook `docs/runbooks/validate-and-record-shibuya-release.md`
is a useful procedure, but does not cover Kafka or assembled Keiro acceptance.

The historical cohort is `cohort/released.json` plus `cohort/released.project`,
with Keiro 0.17.0.0, Kiroku Store 0.8.0.1, Shibuya 0.9.0.3, and the other exact
pins in the descriptor. `cohort/shibuya-current.*` is an isolated lane; neither
that name nor `head` establishes a current released whole-runtime candidate.
The baseline narrative is `docs/reports/2026-09-29-runtime-baseline.md`; records
are under `docs/verification/`, while sealed local runs are ignored by Git.

`kenshou-cli/src/Kenshou/Cli/Registry.hs` assembles the catalog. Its
`FULL_RUNTIME_SUITES` conditional can omit most layers. Capture `list --json`
and the build flags for each arm; a successful reduced executable cannot satisfy
this plan. `suites/change.json` defaults to a bounded 45-minute subset, while
`suites/release.json` describes every kind/tier on cells. A bounded change plan
alone cannot establish release-wide coverage.

Relevant ADRs are [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md)
(resolved identity), [ADR-3](../adr/0003-kenshou-owns-the-runtime-verification-protocol.md)
(generic ownership), [ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md)
(conservative selection), [ADR-6](../adr/0006-comparison-verdicts-require-controlled-benchmark-evidence.md)
(controlled benchmarks), [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md)
(scoped labels), [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md)
(immutable evidence), [ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md)
(cell payloads), and [ADR-23](../adr/0023-pin-performance-gates-to-independent-preparation-and-calibration-evidence.md)
(calibrated performance gates).


## Plan of Work

### Milestone 1: freeze history and discover releases

Start with a clean committed harness. Record its commit, the active cohort,
toolchain, historical descriptor/report digests, and exact historical run IDs
and trust levels in `rounds/1/refresh-inputs.json`. This is ordinary report input
data, not a new verification evidence concept or a claim to implement a future
round schema. Include missing artifacts and incomplete attestations. An old
report's counts do not replace a run index. Use `history --json` per scenario;
freeze the selected records now rather than querying latest during later reporting.

Use `mori registry list`, package searches, `mori registry show <project> --full`,
and `mori registry docs <project>` to locate every cohort component's source and
docs. Resolve owner references through `mori path`. If the service is unavailable,
use its documented service startup or report that concrete prerequisite; do not
infer source APIs or release state from stale catalog data. These checks must
succeed before choosing compatibility workarounds.

For every package in `cohort/released.json`, check Hackage's preferred release
metadata and the upstream release tags from the authoritative repository found
through Mori. Include substrates, adapters, migrations, telemetry, Kafka client,
and transitive dependency changes, not just Keiro. Record checked-at time, URLs,
release/tag/revision, observed current normal version, chosen candidate, and any
mismatch or held-back version in `rounds/1/release-verification.json`. A source
checkout version or tag alone is not a published package. Check fresh registry
metadata again immediately before freezing the candidate.

Snapshot owner status, affected/fixed versions, duplicates, canonical URIs, and
scenario/finding links in `rounds/1/owner-audit.json`. Follow duplicates. Fixed,
unreleased, unknown, unresolved, and ambiguous project-level package mappings
remain distinct. Scope also includes reported defects and open local findings;
it is not filtered to `status == fixed`. Do not edit owner lifecycle fields.

### Milestone 2: resolve the candidate and prove coverage

Create `cohort/round-1.json` and `cohort/round-1.project` with exact current
compatible normal releases and a reachable Hackage index state. Verify the
complete build and package constraints from Mori-located sources. Document
solver conflicts, bound changes, and retained older versions. A package-qualified
`allow-newer` requires the evidence and used-surface control in ADR-2; an
unexplained lifted bound is not compatibility proof. Never change historical
pins merely to make the candidate solve.

Build both arms from identical harness/scenario source with the same enabled
features and intended compiler. Use clean committed per-arm states; if cohort
switching changes the tracked import, commit that configuration and retain the
diff proving no harness/oracle source changed. Record both actual commit IDs
and matching harness source digests; never override dirty fingerprints to claim
a clean build. Run the repository's build, unit, link-proof,
and cohort checks for each. Retain the complete solver plans, resolved cohort
identities, build flags, compiler settings, catalog JSON, and separately captured
executables before switching cohorts. If new APIs require harness compatibility
changes, make and validate those changes before rebuilding both arms. Report a
scenario revision or oracle change as an evidence-compatibility issue.

If a current whole-runtime cohort cannot solve, keep compatible layer lanes as
partial evidence and report the exact integration blocker. Do not disable Keiro
schemas or drop layers and then label the result a whole-runtime pass. Independent
satisfiable lanes can proceed while the blocker is diagnosed.

Manually reconcile each in-scope `KnownDefect` against the owner version and
failure labels. Record old/new scope, source, rationale, and ambiguity in
`rounds/1/scope-audit.json`; review and commit source corrections before measured
runs. Unknown fixed versions do not justify speculative bounds. A failure
outside the applicable scope remains blocking, even if its owner says fixed.

### Milestone 3: run the functional and diagnostic matrix

Create and retain separate baseline and candidate plans, because each plan pins
its own resolved cohort hash. Use cohort-diff selection to explain affected
coverage, then enumerate the full available runtime correctness/concurrency
catalog with `--all`. Explicitly retain the suite's intentional selftest
exclusions. Save a matrix keyed by scenario, revision, dimensions, knobs, seed,
and placement. Every historical scenario and every current available runtime
scenario gets an outcome or an explicit exclusion reason on each arm. New
scenarios without historical evidence are identified as new coverage.

Run standard functional cases locally with durable PostgreSQL, PostgreSQL 18 as
the primary baseline environment, PostgreSQL 17 controls where supported, and
the broker/telemetry variants the scenarios declare. Stage the matrix rather
than silently applying a time budget that drops cases. Preserve skips, timeouts,
failures, and infrastructure attempts. Use candidate cell payloads for cell-only
coverage, and prefer local Apple containers for suitable Linux build work before
remote builders. Long diagnostics and soaks still need the controlled placement
the scenario requires.

Include every known-defect reproducer and controls for the baseline report's
unresolved findings: restart thread growth (3), startup cancellation (25),
write-side drain (44), writer heap (46), lease loss (47), Kafka rebalance drain
and churn, SDK soak slopes, and assembled-runtime I5 redelivery controls. Use
checked-in specs such as `specs/keiro-write-side-extended-drain.json`; inspect
current `specs/` and layer docs for the actual controls before running them.
Do not shorten durations or omit fault windows while retaining the original
coverage claim. Missing controls are `not-run`, with the missing prerequisite.

For common scenarios, fresh same-harness baseline reruns distinguish a runtime
change from a repaired harness oracle or a changed environment. Keep three
observations separate: the frozen historical baseline, the fresh baseline
control, and the candidate. Inspect failures and known-defect disposition even
when the run exits zero. Recheck any apparently fixed fault case under its
declared repetitions; a non-reproduction with weak/local evidence is not a
confirmed fix. Preserve unmatched and incompatible observations explicitly.

### Milestone 4: compare performance under controlled conditions

Select representative existing workloads for each available layer and the
assembled runtime, including prior inconclusive or invalidated benchmark cases.
Retain the offered load, duration, warmup, raw samples, telemetry, pool sizes,
PostgreSQL durability, resource limits, machine identity, reset, and health data.
Use five baseline/candidate pairs by default, interleaved ABBA/BAAB, never
simultaneous on the same machine. Produce comparison documents using the existing
`compare` command and checked-in policies, after `summarize --verify` for every arm.

Historical measurements and the October 10 workstation report provide context;
performance deltas need fresh paired controls on the same benchmark cell.
Report throughput, latency percentiles, resource slopes where measured,
uncertainty, and pass/regression/inconclusive/infrastructure verdicts. Check
minimum samples and required metrics, not just a summary exit code. Noisy local
trials remain exploratory. A cohort-wide change cannot isolate a single package's
causal contribution; report the full resolved dependency delta.

The existing bounded `perf` flow can be used when its request matches the
experiment, but its current calibration and coverage checks still apply. An
uncalibrated profile cannot become gating by being selected. This refresh does
not require developing new benchmark orchestration or calibration tooling.
Missing controlled benchmark evidence leaves performance acceptance incomplete.

### Milestone 5: retain evidence and publish the comparison

Record publishable runs and both comparison arms under the existing evidence
contract, then attest from a clean verifier checkout per the recording guide.
Use the configured evidence target; do not invent a bucket or silently treat
unpublished runs as confirmed. Retain local manifests and run IDs even when
publication or replay is incomplete. Update the frozen input index with new
record IDs and artifact digests without rewriting sealed run data.

Write `docs/reports/<date>-round-1.md`. It must contain the complete old/current/
selected package delta and exceptions; the exact build and feature inventories;
a scenario/matrix table showing historical, fresh baseline, and candidate
outcomes; owner records and label-specific conclusions; controlled performance
results and their limits; new failures; and all omitted/incompatible coverage.
Owner status, measured outcome, and evidence trust are separate columns. Count
`verified-fixed` only for compatible confirmed evidence; other passes are local,
unverified, or not-reproduced observations. Unresolved records and absent labels
are unverifiable, not fixed.

Create local findings for new blocking failures, reuse canonical owner records
where available, and follow MasterPlan 1's Integration Point 11 before filing a
new owner report. Use this initiative's canonical origin:
`mori://shinzui/keiro-runtime-kenshou/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds`.
Keep repair outside this repository. Rei updates, if performed in the authorized
execution, use the existing intention `intention_01m3w49yheevg9mzkyfab1mqy4`;
Rei automation is not an acceptance prerequisite for this refresh.

Finalize `rounds/1/refresh-inputs.json` with the report digest and every evidence
reference. EP-4 later validates generic round integration against these frozen
inputs; it may not silently replace them with newer history. A report can be
complete while the runtime is failing, but required blocked/unrun matrix work
keeps the relevant milestone open and must be stated in the MasterPlan handoff.


## Concrete Steps

Run from this repository root inside `nix develop`. These commands use existing
interfaces; there is no prerequisite `kenshou owners` command. First establish
Milestones 1 and 2 and commit the candidate and scope audit. Then, with
`rounds/1/plans/` already created, generate distinct functional plans:

```bash
just use-cohort released
cabal build all
just cohort-check
cabal run -v0 kenshou -- list --json > rounds/1/released-catalog.json
cabal run -v0 kenshou -- plan --all --max-tier standard --placement local \
  --exclude selftest/kernel/correctness/always-fail \
  --exclude selftest/kernel/correctness/errors \
  --kind correctness --kind concurrency --dimension-policy pairwise \
  --knob-policy declared-variants --out rounds/1/plans/released-functional.json
check-jsonschema --schemafile schemas/run-plan.v1.schema.json rounds/1/plans/released-functional.json
# Commit pending cohort/planning inputs before measured execution.
cabal run -v0 kenshou -- execute --plan rounds/1/plans/released-functional.json --out .dev/round-1/released
just use-cohort round-1
cabal build all
just cohort-check
cabal run -v0 kenshou -- list --json > rounds/1/candidate-catalog.json
cabal run -v0 kenshou -- plan --all --max-tier standard --placement local \
  --exclude selftest/kernel/correctness/always-fail \
  --exclude selftest/kernel/correctness/errors \
  --kind correctness --kind concurrency --dimension-policy pairwise \
  --knob-policy declared-variants --out rounds/1/plans/candidate-functional.json
check-jsonschema --schemafile schemas/run-plan.v1.schema.json rounds/1/plans/candidate-functional.json
# Commit pending cohort/planning inputs; prove harness/oracle source is unchanged.
cabal run -v0 kenshou -- execute --plan rounds/1/plans/candidate-functional.json --out .dev/round-1/candidate
```

These plans use the unbounded default policy rather than the change suite's
45-minute budget. Inspect skips and the actual estimate before execution and
split work by supported placement. These commands are the standard local
functional slice, not the benchmark, cell-only, long-soak, telemetry-corner, or
PostgreSQL-control coverage. Plan and retain those slices separately from the
matrix. Use `kenshou compare --help` for the installed command's paired input
syntax and follow the measurement guide. Capture exact invocations in the index.


## Validation and Acceptance

Accept each milestone only with its named artifacts and observable evidence.
The historical cohort descriptors, baseline report, and committed evidence must
remain unchanged. The candidate must pass resolved cohort and full catalog
checks, or the report must explicitly remain a partial comparison with a build
blocker. Every historical and currently available scenario has a matrix row;
no skip or expected-defect exit is counted as a pass. Functional controls,
diagnostic/soak coverage, and performance have separate completion statements.

Another reader can follow the report to exact run IDs, sealed artifacts,
comparison policies, package sources, and attestations. Headline fix claims have
confirmed compatible evidence. Performance claims have fresh controlled pairs,
raw samples, and uncertainty; incomplete or uncalibrated work remains visible.
The report and frozen inputs exist without adding generic packages or commands
here. Update the MasterPlan registry only after all required milestone evidence
exists; publication of a partial report alone does not complete this plan.


## Idempotence and Recovery

Never overwrite sealed runs, historical records, or a frozen cohort mid-round.
Resume `execute --resume` only with the identical plan and arm. New attempts get
new run IDs and keep the failed attempts visible. After freezing the candidate,
a newly discovered release belongs to a later round, not a moving `round-1`.
Switch back with `just use-cohort released`, rebuild, and run `just cohort-check`;
record the final active state. Save process IDs for any test services started,
and stop only owned processes with the project's stop commands. If a cell or
publication fails, retain its artifacts and mark that slice incomplete.


## Interfaces and Dependencies

No new generic interface is introduced. Inputs are the existing catalog, cohort
protocol, planner, executor, comparison engine, cells, and evidence commands.
Outputs are `cohort/round-1.{json,project}`, report input/audit data and exact
plans under `rounds/1/`, sealed raw runs, existing-format evidence records, local
findings, and `docs/reports/<date>-round-1.md`. EP-5 owns these frozen inputs;
EP-4 later consumes them to validate released generic tooling. A formal round
schema or owner engine belongs upstream and is not required to run this plan.
