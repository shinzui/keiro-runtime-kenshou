---
okf_version: "0.2"
---

# Kenshou terminology

This catalog explains Kenshou's verification vocabulary to a developer who
already knows the runtime domain. Start with [scenario](scenario.md),
[cohort](cohort.md), and [run](run.md). The catalog describes Kenshou's own
meanings; runtime concepts are documented by their owning projects, such as
`mori://shinzui/keiro/okf/terminology`.

## Execution and identity

- [scenario](scenario.md) - A registered verification case with a stable identity, declared inputs and environment needs, and executable behavior.
- [cohort](cohort.md) - The resolved set of runtime component packages and sources tested by a Kenshou executable.
- [run specification](run-specification.md) - A versioned input document that selects a scenario and supplies the values and environment for one execution.
- [run](run.md) - One identified execution of a scenario whose inputs, outcome, and artifacts are saved together.
- [dimension](dimension.md) - A named verification axis whose supported values select a run's instrumentation or PostgreSQL mode.
- [knob](knob.md) - A typed, scenario-specific input that changes a workload or diagnostic setting.
- [phase](phase.md) - A timed part of a run's workload lifecycle, named warm-up, steady, or drain.

## Planning

- [tier](tier.md) - A scenario's declared execution cost class used to filter planned work.
- [suite](suite.md) - A named planning policy that selects a useful set of scenario kinds, tiers, and matrix settings.
- [component graph](component-graph.md) - The checked-in map of build and runtime dependencies used to select verification after a change.
- [run plan](run-plan.md) - A versioned schedule of selected runs with fixed specifications, reasons, and identities.

## Results and correctness

- [outcome](outcome.md) - The reported execution state of a run, distinct from whether its failure blocks a gate.
- [sealed run](sealed-run.md) - A completed run directory whose manifest fixes the files that belong to its evidence.
- [fact ledger](fact-ledger.md) - An append-only record of scenario actions and observations consumed by independent correctness checks.
- [invariant](invariant.md) - A stated property that Kenshou checks against observations from a scenario.
- [oracle](oracle.md) - An independent source of expected state used to judge a scenario's observed behavior.
- [verdict](verdict.md) - A saved judgment that a named check held, was violated, or could not be evaluated.
- [known defect](known-defect.md) - An owner-repository contract failure whose reference and expected failure labels are scoped to affected cohorts.
- [fault window](fault-window.md) - A recorded interval in which Kenshou deliberately disturbs a runtime or its environment.

## Measurement

- [paired comparison](paired-comparison.md) - A controlled performance comparison of interleaved baseline and candidate run trials.
- [baseline](baseline.md) - A reference run or set of trials against which candidate behavior is assessed.
- [benchmark-grade run](benchmark-grade-run.md) - A run with complete and healthy measurement evidence suitable for an authoritative performance comparison.
- [comparison key](comparison-key.md) - A digest of the workload and environment inputs that must match for a direct run comparison.
- [series key](series-key.md) - A digest of run compatibility inputs including the resolved cohort plan hash.
- [comparison policy](comparison-policy.md) - The versioned thresholds and evidence requirements used to judge paired performance trials.

## Observability and environment

- [telemetry arm](telemetry-arm.md) - A selected tracing or metrics mode whose effect and measurement overhead Kenshou can compare.
- [diagnosis](diagnosis.md) - A recomputable explanation of a suspected leak or stall from saved samples and captures.
- [verification cell](verification-cell.md) - A leased and resettable machine environment for controlled remote verification runs.

## Retained evidence

- [evidence record](evidence-record.md) - An OKF account of a run or comparison whose claim is fixed and whose raw artifacts are digest-pinned.
- [attestation](attestation.md) - A separate verification record reporting whether an evidence claim is confirmed, refuted, or incomplete.
