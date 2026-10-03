# Keiro command writers grow live heap in a low-rate twenty-minute soak

Status: observed on the clean released cohort; attribution pending between the Kenshou writer role and the Keiro/Kiroku command path. No new owner-project bug report is filed until a writer-only control or heap profile distinguishes them.

The verified alpha cell run `01a0efd2-64be-7086-9386-fb0e76fe715f` contains the [digest-linked nested run `01a0ef66-959b-7285-87b6-1b2924e04d1e`](../verification/runs/keiro/2026/09/01a0ef66-959b-7285-87b6-1b2924e04d1e.md). It used the clean released payload, durable PostgreSQL 18, a twenty-minute steady window, 100 accounts, four router recipients, and a target of 20 commands per second. All ten business checks passed after quiescence: 2,276 transfer debits matched every subsequent transfer stage and 2,209 bonus events produced 8,836 credits; balances, async activity, and dead-letter checks passed.

Both command-writer child reports judged post-major-GC heap growth `leak-suspected` over the 1,200-second window. Writer 0 grew 62,062,616 live bytes and writer 1 grew 66,952,920, each with eleven eligible major-GC samples and a lower confidence bound above the diagnosis floor. Their native-memory, Haskell-thread, OS-thread, file-descriptor, and PostgreSQL-connection probes were stable. Earlier five-minute and default-rate twenty-minute reports lacked enough writer major-GC samples, so this is a new scoped observation, not evidence that the writer began leaking only at the lower rate.

The same run flagged router heap growth, which is already linked to `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3` in [finding 1](1-keiro-write-side-worker-heap-growth.md). That owner report does not yet explain the command-writer signal. `Kenshou.Suite.Keiro.Fixture.Roles.commandWriter` consumes a lazy `Workload.workerOps` stream with a very large count, which is a plausible harness retention path, but source inspection alone cannot establish retained objects. A controlled writer-only run or heap profile, followed by a comparable replay if the harness changes, is required before owner attribution.

The revised default-rate twenty-minute cell replay `01a0eff0-e271-71e1-afbe-3ee4ffb0faba` also classified both writer child heaps as `LeakSuspected`; its fixed post-load drain did not quiesce, so it does not isolate the writer from downstream backlog. It strengthens the need for a writer-only control without changing the attribution status.

## Isolation controls (2026-10-03)

Scenario revision 3 adds a `soak.topology=writers-only` mode that starts only
the two command writers and no saga, router or projection worker. It also
adds `writer.submit-mode=generate-only`, in which each writer expands and
forces every workload command and event identifier at the same pacing but
never calls the store. Writer `snapshot.policy` and
`snapshot.seed-verify-sample-rate` are now knobs. The checked-in cell specs
reuse the earlier seed and the 20 commands/s, twenty-minute settings:

- `specs/keiro-write-side-writers-only.json` removes downstream load.
- `specs/keiro-write-side-writers-only-no-snapshot.json` additionally
  disables snapshots and seed verification. Those are the command-hydration
  paths of [finding 2](2-keiro-seed-backlog-heap-growth.md).
- `specs/keiro-write-side-generate-only.json` exercises only the harness's
  workload, latency CSV and control-channel path.

The owner marked finding 2's report,
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-2`, a duplicate of
`mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`: the Kiroku publisher
position thunk, fixed in `kiroku-store` 0.9.0.1. Every command writer opens a
Kiroku store, and both the released and head cohorts still pin `kiroku-store`
0.8.0.1, so BUG-3 is the leading runtime candidate. It is not established.

Read the three results together:

- Growth that persists in `generate-only` points at the Kenshou writer role.
- Growth only when commands are submitted points at the Keiro or Kiroku
  command path. A comparable run on a cohort carrying `kiroku-store` 0.9.0.1
  or later would then test BUG-3 directly. That retest belongs to the later
  post-fix verification pass, not this baseline.
- Growth that disappears without snapshots or seed verification narrows the
  signal to the hydration path.

Only one-minute local functional smokes ran, on a busy shared workstation,
and they are not leak evidence. Attribution remains pending the quiet-cell
runs.
