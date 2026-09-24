# Keiro seed-backlog heap growth with verification disabled

Status: investigating; filed for upstream triage in
`mori://shinzui/keiro` as [GitHub issue #3](https://github.com/shinzui/keiro/issues/3)
(artifact-level Mori issue URI pending). The run establishes retained heap
growth in this combined command, store, and measurement workload; it does
not identify the retaining component.

Reduced `keiro/snapshot/soak/seed-verification-backlog-reduced` run
`01a0d0f6-822c-7427-a4c9-0a84cd11329c` began with 10,000 account events
and used `snapshot.seed-verify-sample-rate=0`. During its three-minute steady
window it completed 21,527 commands without failures. All four durable checks
passed, including the snapshot-boundary and final ledger checks. The run data
is under `runs/01a0d0f6-822c-7427-a4c9-0a84cd11329c/` (ignored by Git).

The opt-in diagnostic probe forced a major collection every ten seconds. Its
17 post-major samples grew from 13.3 MB to 92.8 MB over 160 seconds. The
detector reported `leak-suspected`: 79.5 MB growth, a 1.86 GB/hour fitted
slope, and a similar 1.92 GB/hour slope in the second half. Native memory,
Haskell and OS thread counts, file descriptors, and PostgreSQL connections
were judged stable. Because verification sampling was disabled, its async
seed-verification task cannot be the sole cause of this signal. Forced
collections perturb command latency, so this run is diagnostic evidence only.

Reproduce with:

```bash
cabal run kenshou -- run keiro/snapshot/soak/seed-verification-backlog-reduced \
  --set command.stream-length=10000 \
  --set snapshot.seed-verify-sample-rate=0 \
  --set soak.duration-minutes=3 \
  --set diagnose.major-gc-interval-ms=10000 \
  --dim pg.durability=durable --out runs
```

A first rate-one run with the default closed-loop load saturated the driver CPU
and was classified as an infrastructure failure, despite passing all four
durable checks. A controlled pair then used an open constant load of three
commands per second for two minutes, with the same 10,000-event starting
history and ten-second forced major-GC interval:

| Sampling rate | Run ID | Completed | Post-major growth | Full-window slope | Second-half slope |
| --- | --- | ---: | ---: | ---: | ---: |
| 0 | `01a0d100-8ad4-7623-b71f-251c8e530d06` | 391 | 58.8 MB | 2.30 GB/hour | 78 MB/hour |
| 1 | `01a0d0fe-3721-70b3-b8f4-eff1677fb44c` | 391 | 59.6 MB | 2.33 GB/hour | 107 MB/hour |

Both passed the durable checks and stayed below the CPU saturation gate. Each
had only 360 steady command samples, below the measurement toolkit's 1,000
sample minimum. The similar heap trends do not support assigning the signal
to sampled seed verification at this offered rate. The much smaller second-half
slopes may indicate a warming cache, but two minutes cannot establish a
plateau.

Next, run a longer controlled pair and isolate the Keiro command runner from
Kiroku's store and the Kenshou measurement recorder. Heap profiles or a
retaining-object census are needed before assigning the defect to
`mori://shinzui/keiro` or `mori://shinzui/kiroku`.
