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

All twenty configuration trials completed and verified under one lease. Every
nested run passed at benchmark grade with full raw samples and at least 15,000
steady samples per operation. Both consumers participated, every queue drained,
and 307,782 accepted jobs were handled exactly once with no worker or operation
errors. All 500 manifested nested files matched their sizes and SHA-256 digests.
Together with A/A, the thirty runs conserved 461,678 jobs and verified 750 files.

Clean-worktree replay from an isolated checkout of harness `71f5a9e` produced
exactly the same metrics, verdicts, saved policy, algorithm, pairs, and varied
factors as the provisional analyses. Both new comparison documents record
`harnessDirty=false`, five pairs, and no health or compatibility rejection
reason. The original dirty documents are excluded from durable publication.

The allocation and memory reductions below apply to this paced workload.
Throughput near 250 jobs/s confirms that each arm kept up with the offered
load; it does not estimate maximum sustainable throughput. The A/A p99
uncertainty remains open, and no outlier or policy limit was removed.

### Drain versus continuous workers

[Comparison `01a0f4fe-74b7-73ab-907d-a63b1ec0d2a3`](data/2026-09-30-queue-worker-execution-shape.json) is **inconclusive** overall. Its saved SHA-256 is `8573cf6d7095143d831e59c7d25d4f4000802a47f469eb90be62d1b41b35a8e0`.

Candidate/baseline ratios and 95% intervals:

| Metric | Ratio (95% interval) | Policy verdict |
| --- | --- | --- |
| Enqueue-to-handler-start p50 | 1.019 (1.007–1.032) | pass |
| Enqueue-to-handler-start p99 | 1.286 (0.637–2.595) | inconclusive |
| Handler-start throughput | 0.999998 (0.999940–1.000056) | pass |
| Enqueue p50 | 1.003 (0.976–1.031) | pass |
| Enqueue p99 | 1.222 (0.714–2.090) | inconclusive |
| Enqueue throughput | 0.999998 (0.999939–1.000056) | pass |
| Allocated bytes/op | 0.856 (0.848–0.864) | pass |
| Maximum live bytes | 1.003 (1.002–1.004) | pass |

Continuous workers allocated about 14.4% fewer bytes per operation. P50,
throughput, allocation, and maximum live bytes passed; both p99 intervals
remained inconclusive. This does not establish a p99 latency improvement.

### Ordinary versus long polling

[Comparison `01a0f4fe-7821-7681-90ab-eb17be1d2d35`](data/2026-09-30-queue-worker-polling.json) is **regression** overall. Its saved SHA-256 is `3488a92a59de61b5c756e52447441965af966c7558947b15b8b1ef3982f396b3`.

Candidate/baseline ratios and 95% intervals:

| Metric | Ratio (95% interval) | Policy verdict |
| --- | --- | --- |
| Enqueue-to-handler-start p50 | 28.951 (28.556–29.353) | regression |
| Enqueue-to-handler-start p99 | 32.802 (32.420–33.189) | regression |
| Handler-start throughput | 0.999983 (0.999948–1.000018) | pass |
| Enqueue p50 | 1.077 (1.073–1.081) | pass |
| Enqueue p99 | 1.095 (1.081–1.110) | pass |
| Enqueue throughput | 1.000010 (0.999978–1.000042) | pass |
| Allocated bytes/op | 0.398 (0.394–0.402) | pass |
| Maximum live bytes | 0.633 (0.632–0.635) | pass |

Long polling at this 100 ms interval reduced allocated bytes/op by about
60.2% and maximum live bytes by about 36.7%, while handler-start p50 and p99
regressed under the unchanged policy. Across pairs, ordinary polling had
roughly 1.9 ms p50 and 3.1 ms p99; long polling had 54.5 ms p50 and 101 ms p99.
This is a measured latency/memory tradeoff for this polling configuration,
not a claim about every long-poll interval or a new runtime-owner defect.
The fresh-job workload does not close the existing redelivery/retry findings.


### Sealed configuration arms

The links below identify the original arms used by both clean comparisons.

| Factor | Pair | Baseline | Candidate |
| --- | --- | --- | --- |
| execution-shape | 1 | [01a0f4a8-8e83-7594-a03b-9f70c4996d19](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a03b-9f70c4996d19.md) | [01a0f4a8-8e83-7594-a140-664aff35c181](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a140-664aff35c181.md) |
| execution-shape | 2 | [01a0f4a8-8e83-7594-ab40-df2c39eade48](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-ab40-df2c39eade48.md) | [01a0f4a8-8e83-7594-a289-644b0260cab3](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a289-644b0260cab3.md) |
| execution-shape | 3 | [01a0f4a8-8e83-7594-a0ea-69aec714e559](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a0ea-69aec714e559.md) | [01a0f4a8-8e83-7594-a31a-6e619779a65a](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a31a-6e619779a65a.md) |
| execution-shape | 4 | [01a0f4a8-8e83-7595-a635-bceb6b5e1111](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a635-bceb6b5e1111.md) | [01a0f4a8-8e83-7595-a74f-3bee6fd150aa](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a74f-3bee6fd150aa.md) |
| execution-shape | 5 | [01a0f4a8-8e83-7595-a7e3-60c531a95658](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a7e3-60c531a95658.md) | [01a0f4a8-8e83-7595-a456-cf209f482b8a](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a456-cf209f482b8a.md) |
| polling | 1 | [01a0f4a8-8e83-7594-a631-3a4785d55b23](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a631-3a4785d55b23.md) | [01a0f4a8-8e83-7594-a8ff-68aded0dcd47](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a8ff-68aded0dcd47.md) |
| polling | 2 | [01a0f4a8-8e83-7594-afec-2aa56f354871](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-afec-2aa56f354871.md) | [01a0f4a8-8e83-7594-a22f-07aa5ba7ca4c](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a22f-07aa5ba7ca4c.md) |
| polling | 3 | [01a0f4a8-8e83-7594-a595-c9d415059497](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a595-c9d415059497.md) | [01a0f4a8-8e83-7594-a301-eb41abac85eb](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7594-a301-eb41abac85eb.md) |
| polling | 4 | [01a0f4a8-8e83-7595-a31c-9540d3ad694e](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a31c-9540d3ad694e.md) | [01a0f4a8-8e83-7595-a2a0-5be37aa7f23f](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a2a0-5be37aa7f23f.md) |
| polling | 5 | [01a0f4a8-8e83-7595-a89e-edd24bb5e993](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a89e-edd24bb5e993.md) | [01a0f4a8-8e83-7595-a750-bf0430cb3f0e](../verification/runs/keiro/2026/10/01a0f4a8-8e83-7595-a750-bf0430cb3f0e.md) |

All twenty configuration arms are digest-linked investigation records. Both
formal comparisons have confirmed attestations, with all six checks passing:
manifest and linked-object digests, revision resolution, cohort/factor identity,
measurement and saved-policy recomputation, captured environment, and clean
worktrees. Confirmation preserves the inconclusive execution-shape verdict and
the polling regression verdict.

- Execution shape: [record](../verification/runs/keiro/2026/10/01a0f4fe-74b7-73ab-907d-a63b1ec0d2a3.md), [confirmed attestation](../verification/attestations/2026/10/01a0f521-d294-751f-baab-f87126f2ba9e.md).
- Polling: [record](../verification/runs/keiro/2026/10/01a0f4fe-7821-7681-90ab-eb17be1d2d35.md), [confirmed attestation](../verification/attestations/2026/10/01a0f530-c1c4-742c-b3ca-74e0e64c650c.md).

These attestations verify independent measurement and decision recomputation
(VC-2 and VC-3). Individual queue business-verdict attestation (VC-1) still needs
its own recomputer. The [child plan](../plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md)
tracks the wider fault, provision, telemetry, and full-soak acceptance work.

To generate the source plan from the repository root:

```bash
nix develop -c cabal run -v0 kenshou -- plan --all \
  --select keiro/queue/benchmark/job-throughput --placement cell \
  --dimension-policy default-only --trials 5 --seed 93013 \
  --set queue.rate=250 --set queue.duration-seconds=60 \
  --set queue.workers=2 --set queue.pool-size=8 \
  --set queue.batch-size=10 --set queue.ordering=unordered \
  --set queue.poll-interval-ms=1 --set queue.long-poll-max-seconds=3 \
  --set queue.long-poll-interval-ms=100 --set queue.execution-shape=workers --out .dev/queue-worker-comparison-source.json
```

The A/A uses `cell pair --pairs 5 --max-replacements 2` with that plan and
the same payload for baseline and candidate. The knob plan materializes five
pairs per factor, changes only that factor, assigns distinct UUIDv7 run IDs,
and executes each run as a cold cell slice. Offline `compare` uses
`--vary knob:queue.execution-shape` or `--vary knob:queue.polling` and the
five paired run paths in pair-index order. Sealed raw cell trees remain under
`gs://tan-nb-exp-cells-results/runs/CELL-RUN-ID/output/RUN-ID`.
