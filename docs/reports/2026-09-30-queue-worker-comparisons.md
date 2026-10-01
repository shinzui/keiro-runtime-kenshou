# Controlled queue worker and polling comparisons

This investigation uses `keiro/queue/benchmark/job-throughput` revision 3 on
leased alpha with durable PostgreSQL 18 and the pinned released cohort. It
compares execution shape and polling mode within that cohort; it does not
measure a release change or maximum sustainable throughput.

Every trial uses the clean Linux payload built from harness
`9c2c9b8224aa9a7525dc8d5b746204aa56f8fcd1`, bundle SHA-256
`ae76437ffec5c83a861a4f2658c4cedfcc4477f8caeb00ca834e88589edc1433`,
cohort solver-plan SHA-256
`3cd821029b55222b1236939f5f2586b4bf1ce57e0d4f81164bef7fdd00fe81c9`.
The offered load is 250 jobs/s for a 60-second steady window, two consumers,
pool size eight, batch size ten, unordered jobs, and both telemetry dimensions
off. Each trial receives a cold reset. PostgreSQL uses
`checkpoint_timeout=30min` and `max_wal_size=16GB` in both arms.

Five same-seed pairs run in ABBA order under the unchanged
[default policy](../../policies/default.json): 95% confidence,
10,000 bootstrap iterations with the Student-t envelope, benchmark grade,
and all health and compatibility gates. The short windows contain no
checkpoint cycle; these results characterize this paced workload only.

## A/A control

Session `01a0f4b4-a322-763c-a398-deb1a80999a4` completed ten verified cell
slices under one lease. Every nested run passed, retained full raw samples,
and reached benchmark grade with no operation failures. Each operation had
at least 15,000 steady samples. Across all phases, 153,896 enqueued jobs were
handled exactly once, both consumers participated, and every queue drained.
All 250 manifested nested files matched their sizes and SHA-256 digests.

[Comparison `01a0f4c5-50b5-73e4-bb15-2eea4f2f137c`](data/2026-09-30-queue-worker-aa.json)
is **inconclusive** overall. Enqueue and handler-start throughput, p50,
allocation per operation, and maximum live bytes passed. Both p99 intervals
cross policy limits because the fifth pair had higher tails. Handler-start
p99's candidate/baseline ratio is 0.874 with interval 0.600–1.272; enqueue
p99 is 0.890 with interval 0.638–1.241. No health or compatibility reason
invalidated the pairs, and no policy was relaxed. This control does not
establish p99 repeatability.

The saved comparison SHA-256 is
`de6d62e3582a5ea6d8d45d94dc1163a54f844a3b911d0c51ba604719da1793e0`.
Its `control` axis is preserved as a report artifact; the current evidence
recorder supports comparisons whose factor values differ, so it cannot
create an A/A comparison concept. The individual sealed runs can be recorded
without changing that axis or inventing different values.

All ten arms are now digest-linked investigation records. They have not yet
received independent business-verdict attestations.

| Trial | Arm | Sealed run record |
| --- | --- | --- |
| 1 | baseline | [01a0f4a8-8e83-7594-a83d-cb3604b6995f](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a83d-cb3604b6995f.md) |
| 2 | candidate | [01a0f4a8-8e83-7594-a4fa-d8bfcb892f26](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a4fa-d8bfcb892f26.md) |
| 3 | candidate | [01a0f4a8-8e83-7594-a07e-006809658925](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a07e-006809658925.md) |
| 4 | baseline | [01a0f4a8-8e83-7594-a304-72cc62d29ea9](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a304-72cc62d29ea9.md) |
| 5 | baseline | [01a0f4a8-8e83-7594-ab91-f155443ddce8](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-ab91-f155443ddce8.md) |
| 6 | candidate | [01a0f4a8-8e83-7594-a02d-592fb7c56b5c](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a02d-592fb7c56b5c.md) |
| 7 | candidate | [01a0f4a8-8e83-7594-a100-440e56951a4c](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a100-440e56951a4c.md) |
| 8 | baseline | [01a0f4a8-8e83-7594-a1b0-b815f3f1f17e](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a1b0-b815f3f1f17e.md) |
| 9 | baseline | [01a0f4a8-8e83-7594-a4a4-095f502faf1c](../verification/runs/keiro/2026/09/01a0f4a8-8e83-7594-a4a4-095f502faf1c.md) |
| 10 | candidate | [01a0f4a8-8e83-7594-a7fc-c54d2aeb5596](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a7fc-c54d2aeb5596.md) |

## Configuration comparisons

The ten execution-shape trials compare bounded drain with continuous
workers, keeping ordinary polling in both arms. The ten polling trials
compare ordinary polling with long polling, keeping continuous workers in
both arms. Ordinary polling is 1 ms; long polling has a 3-second maximum and
100 ms interval. All other knobs and dimensions agree within each pair.
The source plan has five distinct seeds; each pair reuses its source seed.

These trials are in progress. Results must retain the A/A p99 uncertainty,
independent business verdicts, and the unchanged policy before any conclusion
is recorded. The [child plan](../plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md)
tracks the wider coverage and acceptance work.

To generate the source plan from the repository root:

```bash
nix develop -c cabal run -v0 kenshou -- plan --all \
  --select keiro/queue/benchmark/job-throughput --placement cell \
  --dimension-policy default-only --trials 5 --seed 93013 \
  --set queue.rate=250 --set queue.duration-seconds=60 \
  --set queue.workers=2 --set queue.pool-size=8 \
  --set queue.execution-shape=workers --out .dev/queue-worker-comparison-source.json
```

The A/A uses `cell pair --pairs 5 --max-replacements 2` with that plan and
the same payload for baseline and candidate. The knob plan materializes five
pairs per factor, changes only that factor, assigns distinct UUIDv7 run IDs,
and executes each run as a cold cell slice. Offline `compare` uses
`--vary knob:queue.execution-shape` or `--vary knob:queue.polling` and the
five paired run paths in pair-index order. Sealed raw cell trees remain under
`gs://tan-nb-exp-cells-results/runs/CELL-RUN-ID/output/RUN-ID`.
