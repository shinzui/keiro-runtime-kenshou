# Keiro child completion crash strands its parent

Status: reproduced on the released cohort (keiro 0.17.0.0) and filed as
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-8` (`reported`, severity
`degraded`) on 2026-10-03. Owner: `mori://shinzui/keiro` (durable workflow
children). The scenario carries BUG-8 as an all-cohort `KnownDefect` on
`workflow-parent-completes-after-child-marker-crash`, because both cohorts pin
keiro 0.17.0.0 and the window's source is unchanged through keiro 0.19.0.0.

`keiro/workflow/concurrency/child-completion-crash-window` parks a parent on
`awaitChild`, then runs the child in a separate `keiro/workflow-driver`
process through `Keiro.Workflow.Child.runChildWorkflow` with an
`onJournalAppend` hook. The hook raises `SIGKILL` on the child's second
committed journal append, which for the one-step fixture child is its
`WorkflowCompleted` marker. Two ordinary resume workers then run for 120
seconds (four times the scenario's 30-second quiescence deadline).

Observed in both local runs, before and after the workers ran:

| Row | State |
| --- | --- |
| child instance (`keiro_workflows`) | `completed` |
| child link (`keiro_workflow_children`) | `running` |
| parent journal `child:<childId>:result` | absent |
| parent instance | `suspended` |

The parent never completes. The control arm, which kills the same child
runner after its first append (the step, before the completion marker),
completes its parent with the child's result in the same run, so the harness
detects a correctly healed parent. The precondition verdict
`window-reached-between-marker-and-wake` held, so the kill landed in the
intended window.

Cause, from the pinned source (`keiro-0.17.0.0`, `src/Keiro/Workflow/Child.hs`
and `src/Keiro/Workflow/Resume.hs`): `runChildWorkflow` commits the child's
completion marker inside `runWorkflowWith` and calls `childCompletionHook` in
a later transaction. A process death between them leaves:

- the child instance terminal, so `findUnfinishedWorkflowIds` never returns it
  again and no worker re-runs `runChildWorkflow` for it;
- the link row `running`, so `awaitChild`'s arm, which repairs only a
  `ChildCompleted` link with a stored result, re-arms nothing;
- the parent suspended with no due wake, so discovery never returns it.

`findRunningChildIds` lists the stranded link but is no longer a discovery
seed. Keiro's plan
`mori://shinzui/keiro/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity`
made the link transition and the parent append one transaction; this window
is the step before that transaction and is not covered by its tests.

Evidence (local, PostgreSQL 18 `durable`, under the shared host lock; not
published to the evidence bundle). The first two runs used a dirty harness
tree during development; the third used a clean tree at harness revision
`cb9f003d0dc60a3463213593855846922c2f28c0`.

| Run | Seed | Harness | Result |
| --- | ---: | --- | --- |
| `01a10018-e79a-713d-b832-07dc38133015` | default | dirty | only `parent-completes-after-child-marker-crash` violated |
| `01a1003a-a622-750b-82a4-be08f2a490e6` | 7 | dirty | only `parent-completes-after-child-marker-crash` violated |
| `01a10041-1c12-7327-b58a-812d0f118088` | 11 | clean | only `parent-completes-after-child-marker-crash` violated |
| `01a101f0-dae7-7586-8f75-9a3752190c66` | default | clean at `2f9ff05` | BUG-8 `reproduced`, `blocking=false`, exit 0 |

Reproduce:

```bash
nix develop -c cabal run kenshou -- run \
  keiro/workflow/concurrency/child-completion-crash-window \
  --dim pg.durability=durable --out runs/ep14
```

The owner record states the contract break against `mori://shinzui/keiro/okf/adrs/concepts/ADR-23`, which
requires every wake-source transition to write the instance row. Repairs for
the owner to weigh: commit the child's completion marker, the link transition
and the parent append atomically, or keep a completed child whose link is
still `running` discoverable until its hook runs. A change to `awaitChild`'s
arm alone cannot help, because the stranded parent is never run. When a cohort
pins a keiro release with the fix, narrow the `KnownDefect` scope to the
affected versions.
