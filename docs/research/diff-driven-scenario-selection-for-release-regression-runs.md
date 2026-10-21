---
type: Research Document
title: Diff-driven scenario selection for release regression runs
description: >-
  Assess how Kenshou can select targeted scenarios from the diff between upstream
  releases, and whether a shikumi diff classifier should decide which scenarios run.
generated:
  by: process:claude-code
  at: "2026-10-21T14:23:06Z"
researchId: RES-1
status: active
scope: >-
  The Kenshou planner delivered by EP-3 under ADR-5, the checked-in component graph,
  and the registered scenario catalog at harness commit 6514438; shikumi at commit
  5d22496 and handan at commit 8e98b0a as candidate classification machinery. Cell
  execution, performance calibration and CI orchestration are out of scope.
sources:
  - id: adr-5
    resource: mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-5
    title: Select runs from a checked-in component graph and over-select when unsure
  - id: plan-3
    resource: ../plans/3-plan-and-select-runs-from-what-changed.md
    title: Plan and select runs from what changed (EP-3)
  - id: component-graph
    resource: ../../kenshou-core/data/components.json
    title: Kenshou component graph (kenshou.component-graph/v1)
  - id: planner-source
    resource: ../../kenshou-core/src/Kenshou/Plan/
    title: Kenshou.Plan.Change, Change.Git, Change.Cohort and RunPlan modules
  - id: findings
    resource: ../findings/
    title: Runtime defects found by the suite
  - id: timing-report
    resource: ../reports/2026-10-10-shibuya-latest-timings.md
    title: Latest Shibuya workstation timings for 2026-10-10
  - id: shikumi
    resource: mori://shinzui/shikumi
    title: >-
      Shikumi user guides at project-relative docs/user/concepts.md,
      docs/user/evaluation-and-optimization.md and docs/user/caching-tracing-replay.md
      (artifact-level URIs pending)
  - id: handan-release-classify
    resource: mori://shinzui/handan/packages/handan-core
    title: >-
      Handan.Program.ReleaseClassify and Handan.Eval.Golden.ReleaseClassify at
      project-relative handan-core/src (artifact-level URIs pending)
relatedDecisions:
  - ADR-3
  - ADR-5
relatedPlans:
  - ../plans/3-plan-and-select-runs-from-what-changed.md
  - ../plans/25-provide-quick-and-reliable-performance-validation-for-runtime-changes.md
reviews:
  - kind: model
    reviewer: claude-code-subagent
    reviewed_at: "2026-10-21T14:18:30Z"
    document_timestamp: "2026-10-21T14:10:09Z"
    scope: technical-accuracy
    outcome: changes-requested
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: >-
      Independent subagent review of the first revision against ADR-3, ADR-5, docs/planning.md,
      plan 3, components.json, the Kenshou.Plan modules, the suite files, findings 17, 21 to 24
      and 36, the 2026-10-10 timing report, the shikumi user guides and handan's ReleaseClassify.
      It reproduced the closure table under the stated method but showed that the identifier
      scan missed about seventy scenarios, found two errors (a third component declares
      sub-components; the timing exercise ran three benchmark scenarios, not thirty) and several
      misleading statements (applyBudget is first-fit, the release suite is unselected and
      unbudgeted, finding 23 is a limitation, two components lack source roots, nightly skips
      soak). Every finding was corrected in the revision that follows.
  - kind: model
    reviewer: claude-code-subagent
    reviewed_at: "2026-10-21T14:23:06Z"
    document_timestamp: "2026-10-21T14:20:56Z"
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: >-
      Same reviewer re-checked the corrected revision against the same sources. It recomputed
      the over-selection table from the 335-identifier literal scan and matched every row,
      confirmed the sub-component count, the first-fit budget description, the suite framing,
      the findings attribution (stopAppGracefully and waitApp are defined in Shibuya/App.hs, a
      runner prefix), the timing-exercise description, the source-root limitation and the
      wording fixes. Two nits, the first review's reviewed_at and "up to the standard tier",
      are applied in this revision.
verified:
  - by: process:claude-code-subagent
    at: "2026-10-21T14:23:06Z"
---

# Diff-driven scenario selection for release regression runs

## Question

Running every Kenshou scenario for every upstream release takes too long. Can the
diff between two releases select a targeted subset of scenarios, and should a
shikumi language-model program classify that diff to decide what runs?

## Conclusions

- Kenshou already selects scenarios from a described change. The planner from
  EP-3 maps cohort diffs, upstream revision ranges and local edits through the
  component graph and records the path that selected every scenario[^plan-3].
- Release runs are expensive because of granularity, not because selection is
  missing. A release arrives as a cohort diff, which maps to whole components,
  and the heavily depended-on components own wide selectors such as `kiroku/**`.
- A language model must not decide membership of a release run. ADR-5 states
  that uncertainty may cost time but may never silently remove evidence, and the
  findings catalog shows defects that came from code a hunk classifier would
  plausibly call internal[^adr-5][^findings].
- Shikumi fits three roles that respect ADR-5: ranking scenarios inside the
  graph closure so budget cuts drop the least relevant ones, proposing graph
  refinements for human review, and classifying releases for triage. Handan
  already hosts a shikumi release classifier and is the right home[^handan-release-classify].
- The cheapest wins need no model: finer sub-components in the graph and
  relevance-ordered budget cuts.

## What the planner does today

`kenshou plan` accepts five change inputs and resolves them against the
checked-in graph in `kenshou-core/data/components.json`[^plan-3].

| Input | Maps to | Granularity |
|---|---|---|
| `--changed COMPONENT[,COMPONENT]` | named graph nodes | component or sub-component |
| `--cohort-from A --cohort-to B` | packages whose pin differs | whole component |
| `--since REV` | this repository's paths | path rules in the graph |
| `--upstream-diff REPO=PATH@A..B` | paths in an upstream checkout | sub-component where declared |
| `--all` | the catalog | everything |

Selection follows the transitive dependent closure, so a change to `kiroku-store`
also selects everything built on it. `--explain` prints the shortest selecting
path. An unmapped package or path selects everything with a warning. The
`change` suite selects by described change up to the standard tier, for correctness
and concurrency kinds, under a 45-minute budget. The `release` suite selects
everything, every kind and tier, with no budget, by design. The targeted path for
a release is therefore the `change` suite, or an explicit budget, fed with a
release diff, and that is what this study analyses[^plan-3].

### Measured over-selection

The table counts scenarios a whole-component change selects. The closure was
computed over the graph's component-level edges and matched against every
four-segment scenario identifier literal under `kenshou-*/src` at harness
commit 6514438. That scan found 335 identifiers: keiro 123, shibuya 61, pgmq 50,
kiroku 48, kafka 29, selftest 21 and runtime 3. An independent review reproduced
the method. The authoritative catalog is `kenshou list`, which needs a built
binary and was not run.

| Changed component | Dependent closure size | Scenarios selected (of 335) |
|---|---:|---:|
| hs-opentelemetry | 14 | 279 |
| pg-migrate | 17 | 257 |
| shibuya-core | 9 | 216 |
| kiroku-store | 12 | 192 |
| kiroku-store-migrations | 14 | 192 |
| keiro-core | 5 | 126 |
| keiro | 3 | 126 |
| keiki | 6 | 126 |
| pgmq-hs | 6 | 93 |
| shibuya-pgmq-adapter | 4 | 36 |
| keiro-pgmq | 3 | 21 |

Sub-component edges narrow the `keiro` and `shibuya-core` cases when the input
carries paths. A change confined to `keiro:outbox` selects the 17 outbox
scenarios plus its downstream closure rather than the 126 scenarios, 123 keiro
and 3 runtime, that a whole-component change selects.

### Why a release over-selects

1. **A cohort diff knows package names only.** `diffCohorts` emits a component
   reference without a sub-component, so a shibuya-core patch release behaves
   like a change to its contract, telemetry and runner at once[^planner-source].
2. **Only two upstream components declare sub-components.** `keiro` has twelve
   and `shibuya-core` has three; the harness node `kenshou-harness` declares one.
   `kiroku-store`, `pgmq-hs` and every adapter are single nodes, and even the
   sub-components map to wide selectors such as `shibuya/**`[^component-graph].
3. **The budget cut is not relevance-ordered.** `buildPlan` sorts selected
   scenarios by graph distance, tier, kind and then scenario identifier.
   `applyBudget` is first-fit: it walks scenario groups in that order, skips any
   group whose cost exceeds the remaining budget, and keeps going, so cheaper
   later scenarios survive after an expensive one is dropped. Among scenarios
   with equal distance, tier and kind the order is alphabetical[^planner-source].
4. **Path-level input needs a checkout and source roots.** `--upstream-diff`
   runs `git diff` in a local checkout of the upstream repository, and its
   `REPO` name must equal the graph's `repository` field. Mori provides a
   checkout for every runtime project, but `hs-opentelemetry` and
   `hw-kafka-client` declare no source roots, so their paths map to nothing and
   a release of either still needs the cohort diff.

The 2026-10-10 Shibuya exercise shows the current shape of a release check:
three hand-picked benchmark scenarios, five paired trials each for thirty runs,
driven by a script rather than a plan, beside a separate thirty-scenario smoke
list[^timing-report].

## What shikumi offers

Shikumi makes a language-model call an ordinary typed value. A `Program i o`
derives the provider schema from Haskell records, decodes replies totally, and
returns an enumerated `ShikumiError` on failure. A sum of nullary constructors
becomes a closed string enum in the schema, `Validatable` adds post-decode rules,
and `majorityVote` arbitrates samples. Interpreters add content-addressed
caching, hierarchical tracing with deterministic replay, and typed evaluation
over labeled datasets with golden reports[^shikumi].

Handan already uses this shape for release triage. `ReleaseClassify` takes a
version, release notes and an optional diff and returns `Patch`, `Feature` or
`Breaking` with a confidence, a rationale and a recommended action. It has a
committed golden dataset, and `handan decide --gated-exit` maps a `HumanReview`
verdict to exit code 10 so automation can branch on it[^handan-release-classify].

## Alternatives considered

### A. Let a classifier decide which scenarios run

Rejected. ADR-5 chose explicit, reviewable graph edges because inferring
relationships from paths or names makes selection opaque and can silently omit
evidence; the same objection applies with more force to a model. The findings
catalog gives concrete cases. Shibuya findings 17, 21, 22 and 24 concern forced
stop, halt, finalizer and adapter-shutdown ordering, and keiro finding 36
concerns a stale outbox publisher finalizing a newer claim. The findings cite
API functions such as `stopAppGracefully` rather than modules; those functions
live under the prefixes the graph assigns to the `runner` sub-component. Edits
in those paths read as internal lifecycle refactors, which is the category a
hunk classifier is most likely to mark safe[^findings]. A wrong "skip" leaves no
trace in the evidence bundle.

### B. Refine the graph deterministically

Recommended first. Add sub-components with path prefixes and `uses` edges for
`kiroku-store`, `pgmq-hs`, `shibuya-pgmq-adapter` and `shibuya-kiroku-adapter`,
and narrow their selectors to the scenario areas they exercise. Declare source
roots for `hs-opentelemetry` and `hw-kafka-client` so their releases can use
path-level input. Feed releases
through `--upstream-diff` using the Mori checkout and the two release tags,
keeping the cohort diff as the fallback when no checkout exists. `--graph-check`
keeps build edges honest; runtime edges stay reviewed assertions as ADR-5
requires.

### C. Rank within the closure with a shikumi program

Recommended. A program takes the diff grouped by sub-component together with the
summaries of the scenarios the graph selected, and returns one record per
scenario: a closed priority (`run-now`, `nightly`, `defer`) and a one-line
rationale. Kenshou consumes that document as an ordering applied before the
budget, together with a cost-aware admission rule, because first-fit alone can
still skip a large high-ranked group while admitting cheap low-ranked ones.
Every scenario the ranking defers still runs in the broad suites: `nightly`
selects everything up to the extended tier for correctness, concurrency and
benchmark kinds on a cell, and `weekly-soak` covers soak. The plan records the
ranking rationale beside the graph reason, so selection stays explainable.
Membership is unchanged; only order and admission change.

### D. Maintain the graph with a shikumi program

Recommended. Given an import graph and a diff, a program proposes new
sub-component prefixes and `uses` edges as a pull request against
`components.json`. Humans review the proposal and `--graph-check` validates the
build edges. This is where model judgment compounds: it improves the
deterministic planner instead of sitting in the hot path of every release.

### E. Rank by historical failure correlation

Must be the evaluation baseline. The findings and the verification evidence
bundle record which scenarios failed for which component changes. A per-component
failure frequency is cheap, explainable and model-free. If a shikumi ranker does
not beat it on the same dataset, ship the baseline.

## Where the program lives

In handan, not in Kenshou. ADR-3 makes Kenshou the owner of the runtime
verification protocol, and handan is the fleet's catalog of model judgments with
one trace, one evaluation harness and one envelope format. Kenshou would read a
ranking document produced by `handan decide`, validate it against a schema, and
treat it as advisory ordering.

## Validating a classifier

- **Dataset.** Pair each finding, and each recorded failing run in the evidence
  bundle, with the upstream revision range that introduced it. The expected
  label for a scenario is whether it failed in that range.
- **Metric.** Rank quality at the budget boundary: how many scenarios that later
  failed sit above the cut. Compare against alternative E.
- **Cost control.** Cache by diff digest so re-planning the same release is free,
  and replay traces when a ranking is questioned.
- **Gate.** Treat the ranker like code: golden reports in CI through
  shikumi-eval, and a `HumanReview` style verdict when confidence is low.

## Limits of this study

- Scenario counts come from a scan of identifier literals in the layer sources,
  not from the built catalog, and include the selftest layer.
- The over-selection analysis applies to the `change` suite or any budgeted
  plan fed with a release diff. The `release` suite selects everything without
  a budget by design.
- The closure table uses component-level edges. Path-level inputs narrow the
  keiro and shibuya-core rows.
- No full `release` suite wall-clock exists in the reports. The planner's tier
  estimates are one, ten, sixty and 240 minutes, which bounds the cost but does
  not measure it.
- Whether a model ranks concurrency-sensitive scenarios well is unknown; the
  evaluation in the previous section decides it.

## Proposed next steps

1. An ExecPlan that adds the sub-components from alternative B and a ranking
   input to `kenshou plan`, applied as ordering before the budget cut and recorded
   in the run plan.
2. A `scenario-rank` judgment in handan with a golden dataset derived from the
   findings and the evidence bundle, evaluated against the failure-correlation
   baseline.
3. A decision record stating that rankings order evidence but never remove it,
   either as an amendment to ADR-5 or as a new ADR.

[^plan-3]: EP-3 and the planning guide define the inputs, the suites, the
    explain output and the fail-safe behaviour.
[^adr-5]: ADR-5 consequences: "Uncertainty costs execution time but cannot
    silently remove evidence."
[^findings]: Findings 17, 21, 22, 24 and 36 under `docs/findings/`. Finding 23
    is recorded as an implementation limitation rather than a defect and is
    excluded.
[^planner-source]: `Kenshou.Plan.Change.Cohort.diffCohorts` builds
    `ComponentRef owner Nothing`; `Kenshou.Plan.RunPlan.buildPlan` sorts by
    `(distance, tier, kind, id)` and `applyBudget` is first-fit over scenario
    groups.
[^component-graph]: `components.json` at harness commit 6514438.
[^timing-report]: Three benchmark scenarios, five pairs each, driven by
    `docs/reports/data/2026-10-10-shibuya-timings/run-pairs.py`, local placement.
    The thirty-scenario list in `scripts/shibuya-core-metrics-scenarios.txt` feeds
    the separate smoke scripts.
[^shikumi]: Shikumi concepts, evaluation and caching guides at commit 5d22496.
[^handan-release-classify]: `Handan.Program.ReleaseClassify` and its golden dataset at commit 8e98b0a.
