# Leased verification cells

A cell runs a prepared verification plan on an exclusively leased machine set.
The payload identifies the Nix-built executable and the runtime cohort it
contains. Cell results are sealed in the results bucket and can be fetched and
verified again later.

Build and publish a payload descriptor:

```bash
kenshou cell payload publish --cohort released --out payloads/released.json
```

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
