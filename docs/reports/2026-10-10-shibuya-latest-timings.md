# Latest Shibuya workstation timings for 2026-10-10

Local comparison verdicts are core **inconclusive**, PGMQ **pass**, and Kiroku **inconclusive**.

Five paired trials per scenario completed successfully against the historical released cohort. The candidate includes the requested latest Kiroku adapter and store. These are exploratory local timings; each scenario records `authoritative: false` for local placement.

| Scenario | Baseline throughput (msg/s) | Latest throughput (msg/s) | Baseline p50 (ms) | Latest p50 (ms) | Baseline p99 (ms) | Latest p99 (ms) | Local policy verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| Core async:4 | 200.019 | 200.008 | 2.111 | 2.398 | 2.740 | 3.355 | inconclusive |
| PGMQ adapter | 190.091 | 189.469 | 508.559 | 511.181 | 993.526 | 994.050 | pass |
| Kiroku adapter/store | 199.905 | 199.902 | 1.644 | 1.665 | 11.420 | 5.915 | inconclusive |

The table reports the median of five run-level measurements for each arm. The policy estimates and confidence intervals below use paired ratios, which differ from ratios of these medians. At an offered rate of 200 messages/second, throughput describes this fixed workload rather than maximum capacity. Latency uses the intended send time, including schedule lag. Core includes a 1 ms synthetic handler. PGMQ uses a one-second standard empty-read polling interval, so its tail latency reflects that setting. Kiroku records completion at the handler record or acknowledgement reply and separately checks durable checkpoint progress before finishing the run.

## Versions and build identity

| Package | Baseline | Latest cohort |
|---|---|---|
| `shibuya-core` | 0.9.0.3 | 0.10.0.1 |
| `shibuya-metrics` | 0.9.0.3 | 0.10.0.1 |
| `shibuya-pgmq-adapter` | 0.16.0.0 | 0.16.1.0 |
| `pgmq-core` | 0.6.1.0 | 0.6.1.1 |
| `pgmq-hasql` | 0.6.1.0 | 0.6.1.1 |
| `pgmq-effectful` | 0.6.1.0 | 0.6.1.1 |
| `pgmq-migration` | 0.6.1.0 | 0.6.1.1 |
| `shibuya-kiroku-adapter` | 0.5.1.2 | 0.6.0.0 |
| `kiroku-store` | 0.8.0.1 | 0.10.0.0 |
| `kiroku-store-migrations` | 0.4.0.0 | 0.7.0.0 |
| `pg-migrate` | 1.1.0.0 | 1.2.0.0 |

Owners: `mori://shinzui/shibuya`, `mori://shinzui/shibuya-pgmq-adapter`, `mori://shinzui/pgmq-hs`, `mori://shinzui/kiroku` and `mori://shinzui/pg-migrate`. Release selection was checked against Hackage and upstream release tags; the [release verification record](data/2026-10-10-shibuya-timings/release-verification.json) includes the final Hackage check. The baseline descriptor remains unchanged. The candidate index state is `2026-10-10T19:40:06Z`; the baseline uses `2026-09-20T13:44:47Z`. Other resolved dependencies also changed; see the [complete package version differences](data/2026-10-10-shibuya-timings/package-version-differences.json). This compares cohorts and cannot attribute a difference to Shibuya alone.

Both executables use harness `f5eb20031eef1ed16ca21db626bfb9292b0249b0`, GHC 9.12.4, Cabal `-O1`, and `+RTS -N4 -T`. The candidate disables Keiro schema support to resolve the new Kiroku migration set; the baseline retains it. Captured build plans and separately copied executables prevent a later Cabal build from relabeling the earlier executable. Both cohorts passed 61 core and 34 Shibuya tests, including live PostgreSQL migration checks.

## Workload and comparison

- Apple M1 Max workstation, Darwin aarch64, 64 GiB memory; four Haskell runtime capabilities.
- Five pairs per scenario, alternating baseline-first and candidate-first order (ABBA design); no simultaneous benchmark trials.
- 5,000 messages at 200 messages/second per trial; full raw samples retained; no warm-up phase in these count-bound scenarios.
- Core: configured async:4, unordered, uniform:16 partitions, 1 ms handler delay.
- PGMQ: async:4, batch 10, pool 10, standard:1 polling, no prefetch, 256-byte payload.
- Kiroku: live subscription, serial handler, batch 100, no consumer group.
- Adapter runs: disposable PostgreSQL 18.6 with fsync, synchronous commit and full-page writes enabled; pg_stat_statements preloaded identically.

The existing policies require at least three pairs, retained full samples, interleaving, a 95% interval, at most 50% relative interval width, a 5% throughput regression limit and a 10% p99 latency regression limit. There was ambient workstation CPU activity, captured before every trial. Numeric summary grade is `benchmark`, but scenario methodology remains non-authoritative for local placement. These policy verdicts do not establish release acceptance on a controlled cell.

| Scenario / metric | Candidate ÷ baseline estimate | 95% interval | Status |
|---|---:|---|---|
| core / `op.publish-to-finalize.latency.p99` | 1.0770 | [0.9602, 1.2079] | inconclusive |
| core / `op.publish-to-finalize.throughput` | 1.0001 | [1.0000, 1.0001] | pass |
| pgmq / `op.publish-to-finalize.latency.p99` | 1.0016 | [0.9988, 1.0043] | pass |
| pgmq / `op.publish-to-finalize.throughput` | 1.0019 | [0.9987, 1.0052] | pass |
| kiroku / `op.publish-to-finalize.latency.p99` | 0.5707 | [0.1666, 1.9548] | inconclusive |
| kiroku / `op.publish-to-finalize.throughput` | 1.0000 | [1.0000, 1.0000] | pass |

## Retained evidence

All 30 measured runs passed. Each completed exactly 5,000 operations, passed `summarize --verify`, and retained a manifest whose listed byte counts and SHA-256 hashes were checked. The [exercise record](data/2026-10-10-shibuya-timings/exercise.json) contains run IDs, directories, sealed-manifest hashes, timings, numeric summaries, methodology, captured cohort identities and ambient CPU snapshots. The directory also contains the three comparison documents, exact input specs and trial driver.

Raw runs remain under `runs/shibuya-2026-10-10-paired/`. A local compressed archive includes measured and calibration raw runs, captured plans, driver logs and validation logs:

- Archive: `.dev/shibuya-timing/2026-10-10-shibuya-local-timings.tar.gz`
- Archive digest: `sha256:a5011d4bcb5f9f7d8c68f5855642aec9527f18a8a554d14b96b1f8e13e1ccb1e`

This exercise retained evidence locally. It did not upload records or produce an external attestation. To publish immutable evidence, follow [RB-1](../runbooks/validate-and-record-shibuya-release.md) with the intended evidence project and bucket.

The captured executables are in `.dev/shibuya-timing/`. With that directory and the archived capture files restored in the repository, replay the driver through the locked development environment:

```bash
nix develop -c python3 docs/reports/data/2026-10-10-shibuya-timings/run-pairs.py paired shibuya-timing-replay
```

Use a fresh output root when replaying; the original run directories are sealed.
