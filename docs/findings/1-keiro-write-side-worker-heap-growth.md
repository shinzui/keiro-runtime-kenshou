# Keiro write-side worker heap growth during a five-minute soak

Status: investigating; filed for upstream triage as
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1`. The observation is a leak signal,
not yet an isolated runtime defect.

The reduced `keiro/command/soak/write-side-steady-state-reduced` run
`01a0d0e6-050d-7746-aaf2-bf0c11368618` used sixteen accounts, four router
recipients, a target of twenty commands per second, and a five-minute steady
window. It exercised the released cohort. The harness retained its run data
under `runs/01a0d0e6-050d-7746-aaf2-bf0c11368618/` (ignored by Git).

All nine durable SQL checks passed over 9,250 account events, including exact
transfer and bonus effects, inline balances, async activity, no dead letters,
and bounded snapshot and dedup rows. The soak outcome was `failed` because
the process-manager and router child leak reports judged post-major-collection
live bytes as `leak-suspected`:

| Child | First live bytes | Last live bytes | Samples | Estimated slope |
| --- | ---: | ---: | ---: | ---: |
| Process manager | 527,680 | 26,216,704 | 11 | 301 MB/hour |
| Router | 529,680 | 21,746,240 | 33 | 220 MB/hour |

Both workers' native memory, thread counts, file descriptors, and PostgreSQL
connection counts were judged stable. The writer and projection child heap
series lacked enough post-major-collection points for a verdict. The main
process's native memory, threads, descriptors, and connections were stable;
its heap series also lacked enough major collections. The first and last
command-latency deciles had 588 and 581 samples, with p99 rising from 6.28 to
13.81 ms, so the latency-drift result was inconclusive under the 20% policy.

The Kiroku subscription bridge uses a bounded `TBQueue`, and the subscription
fetch path reads bounded batches. Those facts make an unbounded bridge queue
an unlikely explanation, but do not isolate the retained objects. The
relevant upstream projects are `mori://shinzui/kiroku` (particularly
`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` and `Worker.hs`) and
`mori://shinzui/keiro` (the process-manager and router workers). Artifact-level
source URIs for these modules are pending Mori coverage.

Reproduce with:

```bash
cabal run kenshou -- run keiro/command/soak/write-side-steady-state-reduced \
  --set soak.duration-minutes=5 --set command.rate-per-second=20 \
  --set command.accounts=16 --set router.fanout=4 \
  --set projection.prune-interval-seconds=60 \
  --dim pg.durability=durable --out runs
```

Next, compare a longer run and an isolated subscription workload with the
same event rate. If live bytes keep rising after the category size and
throughput stabilize, capture heap profiles for the two child processes and
identify the owning component and update the upstream investigation.
