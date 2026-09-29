# Running Kenshou on a GCP verification cell

Use a leased cell when a run needs the Linux machine profile, a controlled
PostgreSQL reset, or durable cell evidence. A cell submission has one
`CELL_RUN_ID` and may contain several Kenshou `RUN_ID`s. The address of one
nested run is `<cell-run-id>/<run-id>`; its fetched directory is
`<cell-run-dir>/tree/output/<run-id>`.

## Prepare the operator and payload

Work from a clean checkout in `nix develop`. Authenticate `gcloud` in the
`tan-nb-exp` project and check that the identity can read and create objects
in the cell control bucket and read objects in the results bucket. Payload
publication needs the remote `x86_64-linux` Nix builder configured by the
repository flake. For creating, upgrading, stopping, or destroying cells, use
the owner project `mori://shinzui/load-testing-infra`; its cell scripts are
under `scripts/cell/` (artifact-level URI pending). Keep its project, region,
and zone set to `tan-nb-exp`, `us-west1`, and `us-west1-a`.

The client defaults to control bucket `tan-nb-exp-cells-control` and allows
only `tan-nb-exp`. `--control-bucket` and `KENSHOU_CELL_CONTROL_BUCKET` select
another control bucket; `KENSHOU_GCP_ALLOWED_PROJECTS` is a comma-separated
project allowlist. The descriptor, not a command-line machine name, supplies
the project and zone used by `--start`.

Publish one checked, immutable payload per cohort and executable variant:

```bash
just payload-lock released
just payload-check released
kenshou cell payload publish --cohort released --out payloads/released.json
kenshou cell payload show payloads/released.json
```

`payload publish` builds the Linux closure, checks its resolved cohort against
`cohort/released.json`, exports the whole closure to a content-addressed
compressed bundle, and writes a descriptor. `payload show` checks the
descriptor and the bundle object's size. Use `--cohort head` for a head
cohort and `--variant info-table` or `--variant profiled` for diagnostics.
A dirty checkout requires the explicit `--allow-dirty` publication flag;
that identity is retained in results. A stale cohort lock is fixed by
regenerating the lock and repeating `payload-check`; a green Nix build by
itself is not a cohort check. See
[ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md).

## Probe, plan, and route

Inspect a cell and run its environment probe after an image or descriptor
change:

```bash
kenshou cell status --cell alpha
kenshou cell probe --cell alpha --payload payloads/released.json
```

The passing probe writes `.dev/cells/alpha.capabilities.json`, keyed to the
descriptor digest. Route and submit ignore an older cache. The probe records
the PostgreSQL major and `pg_partman` availability, broker and OTLP service,
and fault-hook availability; each actual run also records its own capability
facts in `fingerprint.cell`.

Plan for cell placement, then split a mixed plan by cell compatibility:

```bash
kenshou plan --all --select 'selftest/remote/correctness/cell-environment' \
  --placement cell --seed 7 --dim pg.durability=durable \
  --dim pg.version=18 --out plan.json
kenshou cell route --plan plan.json --cell alpha --cell beta \
  --payload payloads/released.json --out routed --coerce-durable
```

`plan.<cell>.json` contains admitted work. `plan.local.json` contains work
that needs local PostgreSQL server control, such as a postmaster restart.
`unroutable.json` names every remaining refusal. A cell has one PostgreSQL
major; a mismatch must route to a cell of the requested major. The opt-in
`--ephemeral-on-driver` can run server-control correctness and concurrency
work using the payload's PostgreSQL binary, but never admits a benchmark or
soak that way. The cell's single PostgreSQL server gives named
`extraPostgres` contexts separate fresh databases on that same server; the
context says `extraPostgres: "shared-server"`. A second independent server
and privileged fault injection are unavailable until the cell advertises
those capabilities. The routing policy in `policies/cell-routing.json`
currently requires `postgres.pg_partman` for a partitioned PGMQ queue.

## Run and inspect

The one-command path starts stopped instances if requested, acquires and
renews a lease, prepares reset-aware slices, submits, watches, fetches,
verifies, and releases:

```bash
kenshou cell run --cell alpha --start --payload payloads/released.json \
  --plan plan.json --out cell-runs/check-1 --coerce-durable
```

`--out` must be new. Keep its `session.json` and work files. The session
journal records every submission and nested run ID. A benchmark or soak is
its own slice by default; compatible correctness runs may share one slice.
Use `--granularity run` when every run needs a separate reset.

For separate processes, lease and submit explicitly, then release the same
lease ID. `--hold` keeps an otherwise idle lease alive in the foreground;
`submit` renews a held lease while it executes.

```bash
kenshou cell lease --cell alpha --start --purpose 'verification' --json
kenshou cell submit --cell alpha --lease-id LEASE_ID \
  --payload payloads/released.json --plan plan.json --out cell-runs/check-2
kenshou cell release --cell alpha --lease-id LEASE_ID
```

`cell watch --cell alpha CELL_RUN_ID` follows a submission. To recover an
interrupted client, run `kenshou cell resume --session cell-runs/check-1`;
verified slices are retained and unfinished slices are reconciled from cell
status before further work. A detached, single-slice soak uses `cell run
--detach` and later `cell resume` to collect it. A lease expiry terminates
the active cell work and yields infrastructure-failure evidence; resume
under a new lease. A busy cell returns exit 4; use `--wait SECONDS` on
`cell lease` or `cell run`. A quarantine also returns 4 with its reason;
inspect the failed reset and use the owner project's cell tools before
clearing it. A rejected submission reports its specific reason, such as an
unsupported PostgreSQL setting or a stale payload digest.

The cell reset applies allowlisted PostgreSQL settings, restarts the server,
recreates databases, and checkpoints before each slice. `--pg-setting
KEY=VALUE` may be repeated. The owner allowlist includes memory, WAL,
checkpoint, planner, worker, autovacuum, logging, `pg_stat_statements.*`,
and `auto_explain.*` settings, plus `fsync`, `synchronous_commit`, and
`full_page_writes`; its source is
`mori://shinzui/load-testing-infra` at project-relative path
`nixos/pkgs/cell-agent/src/src/reset/postgres_settings.rs` (artifact-level
URI pending). `shared_preload_libraries` is set by the owner image and is
checked against the running server for scenarios that require it; it is not
a client reset setting. `--cache-policy cold` drops the operating system's
page cache after restart, while `warm` leaves it. Reset evidence records the
applied policy, checkpoint, settings and sources. Use the same settings and
policy across paired arms.

## Compare and diagnose

For a controlled benchmark, use interleaved trials on one lease:

```bash
kenshou cell pair --cell alpha --start \
  --baseline payloads/released.json --candidate payloads/head.json \
  --plan benchmark.plan.json --policy policies/default.json \
  --out cell-pairs/released-vs-head
```

Each trial is a separate cold-reset submission. The command writes
`comparison.json`, replaces invalid pairs within `--max-replacements`, and
returns the measurement toolkit's verdict code: 0 pass, 1 regression, 3
inconclusive, 4 infrastructure failure. Use the same payload in both arms
for an A/A control. A missing minimum pair count cannot establish a
regression. The current client accepts one benchmark configuration per pair
invocation. Request at least the policy's minimum number of pairs (five in
the default policy); fewer valid pairs are inconclusive. The owner image
allows 64 PostgreSQL starts in its rate-limit window so repeated cold
resets can complete under one lease. Alpha's five-pair released A/A control
passed with ten verified cold resets and five metrics inside policy limits.

For telemetry arms, run the overhead planner's slots as separate submissions
under one lease:

```bash
kenshou cell overhead keiro/command/benchmark/throughput-latency \
  --cell alpha --start --payload payloads/released.json \
  --arms tracing=off,sdk-otlp --trials 3 --otlp-sink file \
  --policy policies/telemetry-overhead.json --out cell-overhead/tracing
```

The command writes `overhead-report.json` and keeps each fetched tree below
`cell-sessions/`; `runs/<run-id>` links to its verified nested directory.
Use `--resume` with the same cell, payload, sink, and reset settings to
continue an interrupted invocation. `--analyse-only` rebuilds its report
without a cell lease. Treat a report with too few valid blocks as
infrastructure failure, not a telemetry result.

For diagnostics, publish the `info-table` or `profiled` payload variant and
submit it with `--rts OPTS`. Choose the variant before publication; runtime
flags alone do not add a missing executable build option. `--otlp-sink null`
discards exported spans, while `file` requests a fresh per-run collector trace
artifact at `traces/otlp.jsonl`. A
scenario's `sdk-otlp` arm receives the cell collector endpoint when its
scenario declares the endpoint knob.

## Fetch and record evidence

Fetch by cell run ID even after its VMs have stopped:

```bash
kenshou cell fetch --results-bucket tan-nb-exp-cells-results \
  CELL_RUN_ID --out fetched/CELL_RUN_ID
kenshou cell verify fetched/CELL_RUN_ID
kenshou cell parity --local runs/LOCAL_RUN_ID \
  --cell fetched/CELL_RUN_ID/tree/output/RUN_ID --out parity.json
```

The fetch verifies a sealed manifest and writes `cell-run.json`, which
links reset and health evidence and gives each nested run's effective
outcome. An unsealed results prefix is incomplete and is refused as
evidence. Use `cell verify gs://tan-nb-exp-cells-results/runs/CELL_RUN_ID`
to verify directly from storage. For diagnosis of an unpublished work
directory, use the owner project's IAP access; diagnostic copies are not
sealed evidence.

Record a verified nested run after inspecting its effective outcome in
`cell-run.json`. The recorder verifies the outer cell manifest, links it
beside the nested manifest, and uses infrastructure failure as the effective
outcome when the cell reports one. Its durable URI starts at the
submission's `output` prefix:

```bash
kenshou record fetched/CELL_RUN_ID/tree/output/RUN_ID \
  --data-base-uri gs://tan-nb-exp-cells-results/runs/CELL_RUN_ID/output \
  --project tan-nb-exp --purpose investigation --verify-only
kenshou attest RUN_ID --project tan-nb-exp
```

The outer manifest must already be published at
`gs://tan-nb-exp-cells-results/runs/CELL_RUN_ID/manifest.json`; the recorder
checks its digest and size without replacing it. Cell-owned GCS objects do not
carry the recorder's SHA-256 metadata, so verify-only fetches and hashes their
bytes. Attestation fetches both
manifests and recomputes the nested scenario verdict separately from the
cell's effective outcome. See
[recording evidence](recording-evidence.md) and
[ADR-21](../adr/0021-address-cell-runs-by-submission-and-nested-run.md).

## Soaks, costs, and failures

Reduced `-reduced` soaks are extended-tier runs and can run locally or on a
cell. Multi-hour forms are soak-tier, cell-placed runs. Submit one slice
with `--detach`; a later gated stage can name the earlier stage's durable
`gs://<results-bucket>/runs/<cell-run-id>/output/<run-id>/run-result.json`
as its gate input. Keep the cell lease budget and the scenario timeout long
enough for the full stage.

A running default cell is provisionally about US$1 per hour; a stopped
cell continues to incur disk charges. Storage charges are expected to be
small beside compute. These are plan estimates, not billing-export
measurements; no actual billing figure has yet been recorded for this
guide. Stop an idle cell through the owner project's `scripts/cell/stop.sh`
when it is no longer needed, or rely on its configured idle policy.

If a client exits during upload, inspect the session journal and cell
status, then resume. A result prefix without a final manifest is unsealed
and cannot be recorded. On agent restart the owner attempts to seal the
surviving prefix as infrastructure-failure with `agent-restarted` evidence.
Use cell status, watch, reset evidence, and the owner agent journal to
identify whether a failure came from the lease, reset, payload, or scenario.
