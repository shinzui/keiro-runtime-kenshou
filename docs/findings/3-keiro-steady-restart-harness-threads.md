# Harness thread growth during Keiro soaks

Status: investigating. The durable recovery checks passed; the leak signal is
in the harness process and its retained component is not yet identified.

The reduced `keiro/command/soak/write-side-steady-state-reduced` run
`01a0d116-079f-73e6-96e2-93ff0487d22b` used four accounts, one bonus
recipient, twenty target commands per second, a one-minute steady window,
and `soak.kill-interval-seconds=10`. It rotated SIGKILL and restart across the
process-manager, router, and projection workers six times while both writers
continued. The ignored run data is in
`runs/01a0d116-079f-73e6-96e2-93ff0487d22b/`.

All ten scenario checks passed over 1,593 account events: the source and target
logs, inline balances, async activity, no dead letters, snapshot row bounds,
and writer completion remained correct after recovery. The overall outcome was
`failed` because the main harness process's Haskell thread probe rose from 18
to 24 and was judged `leak-suspected`. Native bytes, OS threads, file
descriptors, and PostgreSQL connections were stable. The heap probe lacked
enough post-major samples, and first and last command latency p99 values of
7.50 and 11.19 ms gave an inconclusive drift verdict.

An earlier run showed the same six-thread rise. The supervisor was changed to
retire children after exit, but the rerun still grew by six threads. The count
therefore needs a more focused harness investigation before it can be
attributed to a specific retained object or upstream runtime component. The
worker leak reports also lacked sufficient duration to judge this one-minute
restart arm.

A separate one-minute `seed-verification-backlog-reduced` run with in-memory
tracing, collected metrics, and three offered commands per second completed
211 commands and passed four durable checks without child worker restarts.
Its main-process Haskell thread probe grew by 13 and was judged
`leak-suspected`; native bytes, OS threads, file descriptors, and PostgreSQL
connections were stable, while the heap probe lacked enough post-major
samples. An otherwise matching earlier run grew by eight counted threads but
was `insufficient-data` under the statistical policy. These observations show
that the main-process signal is not confined to the restart arm. They do not
establish that the two runs retain the same objects. The ignored run data is
under `runs/01a0d130-aab3-70c7-ad94-0a21d40d45fa/` and
`runs/01a0d12e-fbc4-7367-b1d0-536a84fcacea/`.

A clean released-cohort five-minute outbox soak on alpha, verified cell run
`01a0f014-6de1-70a5-bb0e-ee6a92a42336` and [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f013-99ac-7155-aa00-bab4827de47e.md), passed all eight business checks:
621 enqueued messages reached 621 distinct broker records with no backlog,
duplicate, publisher, or maintenance error. The scenario restarted one
in-process publisher ten times. Its main-process Haskell thread count rose
from 142 to 152 and was judged `leak-suspected`; native memory, OS threads,
file descriptors, and PostgreSQL connections were stable, while the heap
probe had no eligible post-major-GC samples. The exact match between restarts
and counted threads is a focused harness clue, not proof that the same retained
object caused the earlier write-side signal. A matched no-restart or forced-GC
control is needed before changing the leak policy or assigning an owner defect.

A second clean alpha outbox run, cell `01a0f025-946f-73e8-bfc9-8f7d0b79d871`
and [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f01d-96e0-747d-838f-053d4518fb4f.md), repeated all eight
passing business checks and the exact 142-to-152 thread increase after ten
restarts. It was intended as a forced-major-GC control, but [finding 48](48-plan-silently-drops-knob-pinned-for-another-scenario.md)
shows that the planner omitted the undeclared GC knob from its run spec. The
second run is a same-seed repeat, not a GC control.

The matched no-restart control, clean alpha cell
`01a0f062-ff85-74d4-ba79-b9f287a6c58e` and [digest-linked nested
run](../verification/runs/keiro/2026/09/01a0f02e-688c-7400-a8d6-c2a74ac42e44.md),
used the same seed, duration and offered rate, with
`outbox.kill-interval-seconds=0` in its resolved spec. All eight business
checks held over 621 accepted messages and 621 unique broker records. Its
main Haskell threads stayed at 141 from the first to last diagnostic window;
native memory, OS threads, descriptors and connections were stable. The
overall result was inconclusive solely because the five-minute heap probe
again captured no eligible post-major-GC points. This comparison ties the
ten-thread rise in the restart arms to restart activity, but does not yet
identify whether the retained threads belong to the harness supervisor or
Keiro publisher lifecycle.

A revision-2 forced-major-GC diagnostic, clean alpha cell
`01a0f069-e617-717d-a767-e9f4fbd5b134` and [digest-linked nested
run](../verification/runs/keiro/2026/09/01a0f055-c3bf-774f-9e85-993b6c0d5bb6.md),
used the same seed, five-minute duration, two-message/s rate and ten
publisher restarts. The resolved 5,000 ms GC knob produced 40 post-major
heap points. All eight business checks held over 621 messages, while main
Haskell threads stayed between 142 and 144 during the steady window and
finished at 143. Its heap interval straddled the growth floor, leaving the
overall verdict inconclusive. The forced collections change the runtime's
collection schedule, so this is a diagnostic control rather than a
throughput comparison. The flat thread series under frequent collection
suggests collection timing contributes to the earlier count, but does not
establish whether any object is retained or who owns it.

The twenty-minute default-rate outbox run on clean alpha, cell
`01a0f070-83c2-75cb-a4f0-515241b13d94` with [digest-linked nested
run](../verification/runs/keiro/2026/09/01a0f01e-9ec4-7335-94e8-280a36cf2eac.md), sealed and verified after 20
publisher restarts. All eight business checks held over 24,202 accepted
messages and exactly 24,202 unique broker records; there were no publisher or
maintenance errors, the backlog drained, and table and dead-tuple bounds
held. During the 20-minute steady window, main Haskell threads rose from 142
to 157, giving a `leak-suspected` diagnostic verdict and a failed overall
outcome. Native bytes, OS threads, descriptors, and connections were stable;
the heap probe again had no eligible post-major samples. The increase is
smaller than the restart count, unlike the short arms, so the current evidence
does not justify a one-thread-per-restart claim. It does show a persistent
default-collection thread-growth signal under this workload.

Reproduce with:

```bash
cabal run kenshou -- run keiro/command/soak/write-side-steady-state-reduced \
  --set soak.duration-minutes=1 --set command.accounts=4 \
  --set command.rate-per-second=20 --set router.fanout=1 \
  --set soak.kill-interval-seconds=10 \
  --set projection.prune-interval-seconds=0 \
  --dim pg.durability=durable --out runs
```

The minimal supervisor control is recorded below. The no-restart, forced-GC
and longer default-collection comparisons are complete; clean post-repair
workload confirmation and historical in-process attribution remain open.


On 2026-10-01 UTC a minimal toolkit regression reproduced retired-child
retention with only `kenshou-check-fixture-worker`, without Keiro. It creates a
weak reference, sends SIGKILL and reaps the child, performs major GC while the
supervisor remains alive, then requires the child to be unreachable. Before
repair it failed; after repair it passed. `retireChild` now forces the filtered
list spine, and stored disturbance records are evaluated before insertion so
their strict fields release child closures. The package suite passes 34
examples. This establishes a local harness bookkeeping defect, not a root-cause
assignment for every earlier in-process restart signal.

A new dirty local outbox process arm, run `01a0f845-ef94-703f-87d6-1cff0db414bf`
under `runs/ep13-outbox-process-soak/`, held all eleven business verdicts over
141 unique messages and six SIGKILLs. Its six extra broker appends were covered
by message-specific crash marks and its continuous surviving publisher's
resources were stable. Main Haskell threads still grew in this pre-repair run.
These short workstation diagnostics are excluded from controlled baseline and
throughput claims. A clean matched cell control remains required before
closing this finding.


The same-seed post-repair process smoke `01a0f84f-c814-748e-83aa-0b4b60cb8c7d`
under `runs/ep13-outbox-process-soak-fixed/` held all eleven business checks
with 141 unique messages, 148 broker records and six kills. Main Haskell
threads stayed at 145–146, all six bounded main probes were stable, and the
continuous survivor was stable. The overall result remained inconclusive
because short killed incarnations had insufficient data under the unchanged
leak policy. This supports the local supervisor repair; a clean matched
cell control and historical in-process attribution remain open.
