# Planner silently dropped a pinned knob outside the selected scenario

Status: fixed locally; the affected diagnostic run is excluded as a forced-GC control.
Owner: this repository's run planner.

The `kenshou plan` command accepted `--set diagnose.major-gc-interval-ms=5000`
while selecting only `keiro/outbox/soak/table-growth-reduced`. Another scenario
in the full catalog declared that knob, so the planner's global-catalog check
considered it known. The selected outbox scenario did not declare the knob.
The resulting plan contained the pin in `policy.set` but omitted it from the
nested run spec's `knobs`, emitted no warning, and executed successfully.

The clean alpha cell run `01a0f025-946f-73e8-bfc9-8f7d0b79d871`,
[digest-linked nested run](../verification/runs/keiro/2026/09/01a0f01d-96e0-747d-838f-053d4518fb4f.md), was intended as a five-minute
forced-major-GC control for [finding 3](3-keiro-steady-restart-harness-threads.md).
Its result sealed and the tree verified, but the actual workload did not force
major collections. The run repeated the earlier outcome: all eight outbox
business checks held, 621 messages yielded 621 unique broker records after ten
publisher restarts, and main Haskell threads rose from 142 to 152. The heap
probe again had no eligible post-major samples. The repeat supports the
restart-linked thread observation but cannot resolve whether major GC retires
those threads. It must not be described as a GC control.

`Kenshou.Cli.Command.Plan.planSelection` now validates each pin against the
scenarios remaining after suite and selector filtering. If none declares the
pin, planning exits with a usage error instead of silently dropping it.
Pins applying to at least one selected scenario still support mixed plans.
The outbox scenario needs an explicit major-GC knob before a valid control can
be run; a no-restart control is another path to classify finding 3.
