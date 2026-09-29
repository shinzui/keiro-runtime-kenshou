# Leased verification cells

A cell runs a prepared verification plan on an exclusively leased machine set.
The payload identifies the Nix-built executable and the runtime cohort it
contains. Cell results are sealed in the results bucket and can be fetched and
verified again later.

Build and publish a payload descriptor:

```bash
kenshou cell payload publish --cohort released --out payloads/released.json
kenshou cell payload show payloads/released.json
```

`payload show` validates the descriptor and checks that the bundle object
exists with the recorded byte size before printing the descriptor as JSON.

Probe a cell after publishing a payload that contains the environment
scenario:

```bash
kenshou cell probe --cell alpha --payload payloads/released.json
```

The probe runs under a lease, verifies the sealed result, and writes
`.dev/cells/alpha.capabilities.json`. Route and submit use this cache to check
optional capabilities such as `pg_partman`. The cache is tied to the cell
descriptor and is refreshed by running the probe again.

Inspect a cell and run a plan in one process:

```bash
kenshou cell status --cell alpha
kenshou cell run --cell alpha --payload payloads/released.json \
  --plan plan.json --out cell-runs/alpha-1 --coerce-durable
```

The run command acquires a lease, prepares compatible runs for the cell,
submits them in reset-aware slices, follows the cell status, fetches and
verifies sealed output, then releases the lease. `--out` must name a new
directory. Keep that directory to resume an interrupted session:

```bash
kenshou cell resume --session cell-runs/alpha-1
```

Use `cell lease`, `cell submit`, `cell watch`, `cell fetch`, `cell verify`, and
`cell release` when the steps need separate processes. `cell fetch` needs the
results bucket and cell run ID; it writes a verified tree and an index beside
it. `cell verify` also accepts `gs://BUCKET/runs/CELL_RUN_ID` and checks a
sealed run without an existing session directory.

Compare a local run directory with a fetched nested cell run directory:

```bash
kenshou cell parity --local runs/LOCAL_RUN_ID \
  --cell cell-runs/CELL_RUN_ID/tree/output/NESTED_RUN_ID \
  --out parity.json
```

The report lists equal fields, expected placement differences, and unexpected
differences. The command exits 1 if a scenario input or verdict differs. Use
`--volatile result.summaries.verdicts.FIELD` only for a known path inside a
verdict summary.

Measure a benchmark with interleaved baseline and candidate trials on one
leased cell:

```bash
kenshou cell pair --cell alpha --start --baseline payloads/released.json \
  --candidate payloads/head.json --plan benchmark.plan.json \
  --policy policies/default.json --out cell-pairs/run-1
```

Each trial is a separate cell submission with a fresh reset. The command
keeps one lease across the schedule, replaces invalid pairs within its budget,
and writes `comparison.json`. Use the same payload for both arms as an A/A
control before comparing different cohorts.
`--start` starts stopped instances named by the verified cell descriptor; it is
also available on `cell lease` and `cell run`.

Measure telemetry overhead under one lease:

```bash
kenshou cell overhead keiro/command/benchmark/throughput-latency \
  --cell alpha --payload payloads/released.json \
  --arms tracing=off,sdk-otlp --trials 3 --otlp-sink file \
  --out cell-overhead/tracing
```

Each arm slot is a separate cold-reset submission. The command links verified
nested run directories into its `runs/` tree, retains the cell sessions,
reuses the overhead planner's retry and replacement-block rules, and writes
`overhead-report.json`. `--resume` continues the saved invocation under a
new lease; `--analyse-only` recomputes the report without submitting work.

Route a plan across cells with different PostgreSQL majors:

```bash
kenshou cell route --plan plan.json --cell beta --cell alpha \
  --payload payloads/released.json --out routed --coerce-durable
```

The output contains `plan.<cell>.json` for admitted runs, `plan.local.json`
for work requiring local server control, and `unroutable.json` for remaining
refusals. Cell order is preference order. Routing and submission read a
capability cache from `.dev/cells/<cell>.capabilities.json` when present;
`KENSHOU_CELL_CAPABILITIES_DIR` selects another directory. A cache for an old
descriptor is ignored. An unknown capability produces a warning, and an
explicitly unavailable capability prevents admission.

The control bucket defaults to `tan-nb-exp-cells-control`; pass
`--control-bucket` to select another. The client accepts only cells in the
projects named by `KENSHOU_GCP_ALLOWED_PROJECTS` (default `tan-nb-exp`).

For a running cell, use the owner IAP script through the verified descriptor:

```bash
kenshou cell debug --cell alpha ssh monitoring -- systemctl is-active opentelemetry-collector.service
kenshou cell debug --cell alpha journal
kenshou cell debug --cell alpha tunnel monitoring 8888 18888
```

`journal` reads the last 100 driver agent lines. `tunnel` holds an SSH port
forward until interrupted; while it runs, the collector metrics endpoint is
at `http://127.0.0.1:18888/metrics`. Keep a lease held during a longer debug
session so the cell does not idle off. The command locates the owner checkout
with Mori, or uses `KENSHOU_LTI_DIR` when set.

For profiling, publish a `profiled` payload and pass `--rts=-p` to `cell run`.
The cell includes the generated `.prof` files under `tree/output/profiles/` in
the sealed result, subject to its 128 MiB profile collection limit.
