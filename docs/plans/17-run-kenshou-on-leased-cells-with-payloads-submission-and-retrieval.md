---
id: 17
slug: run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval
title: "Run kenshou on leased cells with payloads, submission and retrieval"
kind: exec-plan
created_at: 2026-09-20T17:15:36Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:36Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T21:08:38Z
      mode: "update"
      note: "Adopted relevant Haskell Jitsurei CLI patterns and the bounded Settei configuration contract."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:53:09Z
      mode: "update"
      note: "Consolidated Progress into delivered outcomes and remaining acceptance"
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-25T12:11:39Z
      mode: "update"
      note: "Aligned the client submission shape with EP-16's draft embedded payload descriptor."
---

# Run kenshou on leased cells with payloads, submission and retrieval

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Everything the verification suite can do today happens on the machine where someone types `kenshou run`. That is fine for correctness checks and useless for benchmarks and soaks: a laptop has other work, a different CPU from one week to the next, a PostgreSQL with `fsync` off, and nobody keeps its results. The sibling plan `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` builds the other half: named, long-lived sets of Google Cloud machines called cells that are leased exclusively, reset to a declared state before every piece of work, given that work at run time as a content-addressed Nix closure, and that publish whatever the work writes under an immutable, digest-sealed prefix in a Google Cloud Storage bucket. The cell knows nothing about kenshou. This plan is the kenshou side of that protocol.

After this plan a maintainer can do four new things from this repository. They can build the single `kenshou` executable with Nix for `x86_64-linux`, against either pinned runtime cohort, prove that the Nix build links exactly the package versions the cabal build links, and publish it as a payload named by its SHA-256 digest (`kenshou cell payload publish --cohort released`). They can take any run plan produced by `kenshou plan`, lease a cell, submit the plan, follow its logs, and receive verified results with one command and no SSH (`kenshou cell run --cell alpha --payload payloads/released.json --plan plan.json --out cell-runs`); the same steps exist separately as `kenshou cell lease`, `submit`, `watch`, `fetch`, `verify`, `release` and `status`. They can compare a candidate cohort with a baseline cohort as interleaved trials inside one lease on one freshly reset machine (`kenshou cell pair`), which is the remedy for the checkpoint-phase noise that made the old harness vary by twenty percent from run to run. And they can prove that the cell changes nothing about a verdict: the same correctness scenario with the same seed passes identically on a laptop and on a cell, with every intentional difference named in a parity report (`kenshou cell parity`).

Every kenshou run that executed on a cell remains an ordinary kenshou run directory, fetched byte for byte, verified against both the cell's manifest and kenshou's own, and addressable in durable storage as `gs://<results-bucket>/runs/<cell-run-id>/output/<run-id>/`, which is what `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` links evidence records to.


## Progress

- [ ] Deliver the content-addressed Kenshou payload and `kenshou cell` lifecycle, paired comparisons within a lease, and equivalent local/cell correctness evidence; verify the acceptance commands in Validation and Acceptance.

## Surprises & Discoveries

- EP-16's draft `cell.submission/v1` embeds a full `cell.payload/v1` descriptor. The client must include `schema`, `narHash`, `closurePaths`, and `system` alongside the bundle digest, store path, and command. The producer description already required these fields, while its earlier illustrative submission omitted them. The draft schema and examples are in `mori://shinzui/load-testing-infra` at project-relative path `schemas/cell/` (artifact-level URI pending), commit `396ff30`; agent acceptance is pending.


## Decision Log

- Decision: The payload is delivered exactly as the completed cell plan specifies: one zstd-compressed `nix-store --export` stream of the whole closure, named by its SHA-256 and loaded on the driver with `nix-store --import`. No binary cache and no `nix copy`.
  Rationale: The drafting brief suggested `nix copy` from a bucket-backed cache; `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` evaluated that and rejected it (Nix has no released `gs://` store, the S3 route needs long-lived secrets on every VM). Where the brief and that plan differ, that plan wins, and one immutable object with one digest is also the simplest evidence identity.
  Date: 2026-09-20

- Decision: The Nix build pins every runtime cohort package itself, from `cohort/<name>.json` plus a generated hash lock, composed after the shared `mori://shinzui/haskell-nix` channel so that it wins; the shared channel supplies only third-party compatibility patches.
  Rationale: Verified while drafting: the haskell-nix revision the Seihou module pins (`7b696dc`) locks keiro 0.16.0.0, kiroku-store 0.8.0.0 and shibuya-core 0.9.0.0, while the released cohort is keiro 0.17.0.0, kiroku-store 0.8.0.1 and shibuya-core 0.9.0.3; the channel wraps every first-party package in `doJailbreak`, so a Nix build would silently link the older versions. The channel also offers exactly one version per package, while this suite must build a released cohort, a head cohort and any earlier baseline side by side. This deliberately departs from `mori://shinzui/mori/okf/adrs/concepts/ADR-24` and `mori://shinzui/rei/okf/adrs/concepts/ADR-18`, which forbid local first-party pins in service repositories; here the cohort is the subject under test, and the identity gate below replaces the rule those records protect. Recorded as a new ADR.
  Date: 2026-09-20

- Decision: A green Nix build proves nothing about the cohort; the payload is accepted only when its generated `kenshou.cohort-identity/v1` passes `kenshou cohort check` against the same descriptor the cabal plan is checked against.
  Rationale: Nix runs no solver and bounds are stripped, which is the failure both cited ADRs record. Checking the Nix identity and the cabal plan against one descriptor makes them transitively equal for every cohort package.
  Date: 2026-09-20

- Decision: Under Nix the identity's `planHash` is computed from the cohort lock, the compiler and the nixpkgs and haskell-nix revisions, and the identity gains an optional member `resolver` (`cabal` by default, `nix` here).
  Rationale: Integration Point 2 defines the hash over cabal's `plan.json`, which does not exist in a Nix build. In a pure Nix evaluation those four inputs determine every dependency version, so their digest is an honest plan identity. `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` already tells consumers to compare cohorts by `components` and to treat the hash as supporting evidence.
  Date: 2026-09-20

- Decision: A cell run identifier names one submission; a kenshou run executed on a cell is addressed by the pair `<cell-run-id>/<run-id>`; `kenshou cell fetch` mirrors the bucket tree byte for byte so that `tree/output/<run-id>/` is an ordinary run directory.
  Rationale: One `kenshou execute` of a run plan produces many run directories, each with its own UUIDv7, inside the submission's output directory. Mirroring keeps both manifests verifiable and makes `kenshou record <dir>/tree/output/<run-id> --data-base-uri gs://<results-bucket>/runs/<cell-run-id>/output` correct without any special case, because the evidence plan computes object names as `<data-base-uri>/<run-id>/<relative path>`.
  Date: 2026-09-20

- Decision: The cell's fingerprint, reset evidence and health observations are linked to run results, not merged into `run-result.json`. What is known at run time goes into `fingerprint.cell`; everything else is referenced, with digests, from a derived `cell-run.json` that also carries each run's effective outcome.
  Rationale: `run-result.json` is sealed by kenshou's manifest on the cell and again by the cell's manifest before the cell writes its own health verdict, so merging afterwards would break both digests. The brief's word "merged" cannot be honoured literally without destroying the evidence chain. An infrastructure failure reported by the cell overrides the recorded outcome in the derived document, which is what consumers read.
  Date: 2026-09-20

- Decision: The payload's command is `["bin/kenshou", "cell", "exec"]`, a hidden verb that prepares the process environment from the cell's environment file and then runs the plan with `Kenshou.Plan.Execute.executePlan`.
  Rationale: Integration Point 9 says the entry point is `kenshou execute`, but the cell appends two positional arguments while `kenshou execute` takes `--plan` and `--out`, and nothing in `kenshou execute` reads `CELL_ENV_FILE`. The adapter keeps the substance (the plan is executed by the planner's executor, unchanged) and costs the cell nothing, because the command is a field of the payload. Reported to the MasterPlan as a wording fix.
  Date: 2026-09-20

- Decision: The PostgreSQL major version is satisfied by choosing the cell. `kenshou cell submit` refuses a run whose `pg.version` differs from the cell's major, `--skip-incompatible` drops such runs with a recorded reason, and `kenshou cell route` splits one plan into one plan per cell.
  Rationale: The cell plan fixes the major per cell at creation. `route` also separates what cannot run on any cell: it writes `plan.<cell>.json` per cell, `plan.local.json` for runs that must stay on a laptop, and `unroutable.json` with reasons.
  Date: 2026-09-20

- Decision: One lease carries many submissions ("slices"). Correctness and concurrency runs with identical reset parameters share a slice; every benchmark and soak run is its own slice.
  Rationale: The cell resets once per submission. A benchmark needs the deterministic boundary (databases dropped, settings applied, restart, `CHECKPOINT`, declared cache policy) before every trial, and a tripped health gate must taint one trial, not a whole suite. Correctness runs are isolated well enough by the kernel's fresh database per run, and one reset per dozens of runs keeps a smoke suite fast.
  Date: 2026-09-20

- Decision: A scenario whose PostgreSQL requirement (primary or extra) sets `needsServerControl` stays local: `prepareForCell` rejects it with `NeedsServerControl` and `kenshou cell route` writes it to `plan.local.json`. The opt-in `--ephemeral-on-driver` runs it on the cell's driver against the PostgreSQL 17 and 18 servers bundled in the payload, labelled `postgresPlacement: "driver-ephemeral"`.
  Rationale: Restarting or killing a postmaster is impossible on the cell's server, which the cell owns and which has no control hook. Co-locating a server with the harness is acceptable for a crash-correctness check on Linux and never for a measurement, so it is explicit, recorded, and refused for benchmarks and soaks. A control hook on the cell's PostgreSQL role agent is requested from the cell plan.
  Date: 2026-09-20

- Decision: The kernel's `extraPostgres` (the assembled runtime's two bounded contexts) is satisfied on a cell in a degraded form: every named server resolves to its own fresh database on the cell's one PostgreSQL server, through one connection-string variable per name, and the context document says `extraPostgres: "shared-server"`.
  Rationale: A cell has one PostgreSQL machine. Two databases in one server is the fallback the assembled-runtime plan itself names; it keeps the end-to-end invariants, the soaks and backend-kill faults runnable on a cell, while scenarios that restart one context's postmaster fall under the previous decision. A second PostgreSQL role is a request to the cell plan, not a blocker.
  Date: 2026-09-20

- Decision: Cell health reaches a running scenario through the measurement toolkit's `KENSHOU_HEALTH_NOTICES` file, written by a mapper thread inside `kenshou cell exec`; the cell's own `cell/health.json`, evaluated after the run, stays authoritative through the effective-outcome rule.
  Rationale: The toolkit's gates can only act on what they see before a run result is sealed, and the cell's verdict only exists afterwards, so both channels are needed and they can only agree or be stricter together. The mapper reads what the payload can reach without privileges (the driver's metadata server, and the cell's rolling observations if the cell exposes them), which is why a documented channel for those observations is requested from the cell plan.
  Date: 2026-09-20

- Decision: What a particular cell can do beyond its descriptor (whether its PostgreSQL offers `pg_partman`, which broker implementation and version it runs, whether it offers a fault hook) is learned by a probe run, cached as `kenshou.cell-capabilities/v1`, recorded in every run's `fingerprint.cell`, and matched against the data file `policies/cell-routing.json` when a plan is prepared.
  Rationale: The pgmq plan's partitioned-queue scenarios end `errored` without `pg_partman`, and the client package must not know layer knobs. A rule file ("when knob `pgmq.queue-kind` is `partitioned`, require capability `postgres.pg_partman`") keeps the knowledge as data that the layer's owner can extend.
  Date: 2026-09-20

- Decision: Paired comparisons and telemetry overhead measurements share one primitive, `cellRunChild`, which runs one run specification as one submission inside an open cell session and links the fetched run directory where the caller expects it.
  Rationale: `kenshou overhead` does not emit a run plan; the telemetry plan split it into `planOverhead`, `executeOverhead` and `analyseOverhead` with an injectable `runChild` precisely so that slots can execute elsewhere. Supplying that hook reuses its block validity, retries and analysis unchanged.
  Date: 2026-09-20

- Decision: The client speaks the Cloud Storage JSON API directly through a small `ObjectStore` record with a Google backend and a directory backend, and the test suite contains an in-process fake cell.
  Rationale: Leases need generation preconditions and the server's clock, which the record exposes explicitly; the directory backend makes the lease race, submission, fetch and verification testable on a laptop and in CI with no cloud access and before the real cells exist.
  Date: 2026-09-20

- Decision: `kenshou cell payload publish --via-builder` delegates the export and upload to the cell repository's `scripts/cell/payload-publish.sh`; the `--iap` debugging paths shell out to its `scripts/iap-ssh.sh`. Neither is copied.
  Rationale: Both encode hard-won workarounds (copy-back of large closures over the tunnel fails; macOS OpenSSH breaks `gcloud compute ssh`). The MasterPlan decided that GCP infrastructure is extended in `mori://shinzui/load-testing-infra` rather than copied. The checkout is located with `mori path shinzui/load-testing-infra` or `KENSHOU_LTI_DIR`, and nothing in the happy path needs it.
  Date: 2026-09-20

- Decision: `kenshou cell exec` sets `KENSHOU_CELL_FAULT_HOOK` only when the cell's environment file names a hook (optional member `faultHook`), and calls it with `heal-all` when the plan ends. The payload ships no hook of its own, so until the cell provides one the cell-only injectors report themselves unavailable, exactly as on a laptop.
  Rationale: Packet filtering, traffic shaping and memory limits need root, and the payload runs as the unprivileged user `cellrun`; filling a disk needs no root but would trip the cell's own storage-pressure gate and turn the run into an infrastructure failure. Only the cell's agent can inject such faults and suppress the matching gate for a declared window. The completed cell plan has no hook, so this is an integration request, written so that the client needs no change when the hook appears.
  Date: 2026-09-20

- Decision: `KENSHOU_CLOCK_SKEW_BOUND_MICROS` is left unset on a single-driver cell and set from `chronyc -c tracking` on a multi-driver cell.
  Rationale: The correctness toolkit's default (`same-host`, 1000 microseconds) is right when every kenshou process runs on one driver, which is how kenshou starts. With several drivers the bound must be measured; chrony runs on every cell VM, and its tracking figures are readable without privileges.
  Date: 2026-09-20

- Decision: The four milestones are the MasterPlan's, with unchanged meaning. Environment mapping lives in Milestone 2; the operator guide, costs and failure handling close Milestone 4. Milestone 3 alone needs the measurement and telemetry toolkits, so it may be done after Milestone 4 if they are late.
  Rationale: The MasterPlan lists `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` as a soft dependency; only the paired schedule, `kenshou compare` and the overhead entry points of `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` come from them.
  Date: 2026-09-20


- Decision: Register the `cell` family in the Execution command group, apply EP-2's nested intent-based option groups, accept explicit standard input only for JSON plan/routing documents, and contribute an embedded `cells` help topic.
  Rationale: The cell surface is the largest command family in the executable and mixes leases, binary payloads, JSON work, remote progress and machine output. The shared conventions make it discoverable without weakening binary-input safety or automation output.
  Date: 2026-09-20

- Decision: Reuse EP-2's Settei configuration seam for repeatable cell-client defaults, but keep payload/wrapper variables and run-plan contents outside it.
  Rationale: Cell store/project/bucket selection and local checkout paths are operator configuration with useful precedence and provenance; the submitted plan, payload identity, lease/session state, and variables injected by `cell exec` are protocol documents or transport and must remain explicit. Settei's secret setting also keeps the GCS token out of explanations.
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository or its neighbours.

### Where this plan sits

`keiro-runtime-kenshou` (`/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`) verifies the keiro runtime, a cohort of Haskell libraries for event sourcing and messaging on PostgreSQL. The coordinating document is `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this is child plan 17. It hard-depends on three plans and you must confirm their Progress sections are complete, and read their Interfaces and Dependencies sections for exact signatures, before starting: `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` (package `kenshou-core`, the executable `kenshou`, run specifications, run directories, manifests, exit codes, and the flags and variables `--cohort-identity` / `KENSHOU_COHORT_IDENTITY`, `--cell-fingerprint` / `KENSHOU_CELL_FINGERPRINT`, `--pg-url-env`, `--placement cell`), `docs/plans/3-plan-and-select-runs-from-what-changed.md` (`kenshou plan`, `kenshou execute`, the documents `kenshou.run-plan/v1` and `kenshou.plan-summary/v1`, the module `Kenshou.Plan.Execute`), and `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` (the cells, implemented in another repository). Transitively it needs `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` (the flake, `cabal.project`, the cohort files and `Kenshou.Core.Cohort`). Milestone 3 also needs `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` and `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md`. If a dependency differs from what is restated below, the dependency's own plan wins; record the difference in Surprises & Discoveries and adapt.

### Terms

A Nix store path is an immutable directory under `/nix/store` produced by a build; its closure is that path plus everything it refers to at run time, which is exactly what must be copied for a program to run on another machine. `nix-store --export` writes a closure as one byte stream and `nix-store --import` loads it elsewhere. A flake is a Nix project with pinned inputs and named outputs; `flake.nix` in this repository is generated by the house scaffolding tool Seihou and must not be edited by hand, while `flake.module.nix` is ours. `callCabal2nix` turns a `.cabal` file into a Nix build; `callHackageDirect` builds a named Hackage release from a tarball hash. A Haskell package-set extension is a function that overrides entries of nixpkgs' Haskell package set; extensions compose, and the later one wins. `doJailbreak` deletes version bounds before the build, which is why Nix never complains about a wrong version. A cohort is the exact set of runtime package versions a build links; `cohort/released.project` pins Hackage releases, `cohort/head.project` replaces chosen components by git commits, and `cohort/<name>.json` (`kenshou.cohort/v1`) describes the same thing for machines. A cohort identity (`kenshou.cohort-identity/v1`) is what a build actually resolved. The remote builder is a Google Cloud VM named `nix-builder-x86` that builds `x86_64-linux` derivations for macOS workstations and powers itself off when idle.

Google Cloud Storage (GCS) holds objects in buckets. Every object has a generation number that changes on each overwrite; a write can carry the precondition `ifGenerationMatch=0` ("only if the object does not exist") or `ifGenerationMatch=<n>` ("only if nobody changed it since generation n"), and the service answers HTTP 412 when it fails. A lease is a time-limited exclusive claim kept alive by a heartbeat; it lapses by itself when the holder dies. Quarantine marks a cell unfit until a person clears it. A reset is what returns a cell to a declared state before work starts. A health gate is a check whose failure means the environment, not the software under test, misbehaved. IAP (Identity-Aware Proxy) is Google's authenticated tunnel to machines without public addresses; here it is a debugging path only. A checkpoint is PostgreSQL flushing dirty pages so that its write-ahead log can be recycled; whether one lands inside a measurement window was the dominant noise source of the previous harness. ABBA is an ordering of candidate and baseline trials in which each arm is first equally often, cancelling slow drift. RTS options are flags for GHC's run-time system; `-T` enables the statistics the measurement toolkit samples.

### The cell protocol this plan consumes

The source of truth is `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` and, once implemented, `docs/cells/protocol.md` and `schemas/cell/` in `mori://shinzui/load-testing-infra` (`/Users/shinzui/Keikaku/bokuno/load-testing-infra`; the artifact-level URIs of those files are pending, so the project URI and path are given). Read the protocol document before writing any codec. The parts relied on are these.

There are two buckets per GCP project. The control bucket (`tan-nb-exp-cells-control`) is mutable and holds `cells/<cell>/descriptor.json` (`cell.descriptor/v1`: project, zone, instance names by role, machine and disk shapes, PostgreSQL major, bucket names, agent protocol version), `cells/<cell>/policy.json`, `cells/<cell>/lease.json` (`cell.lease/v1`), `cells/<cell>/quarantine.json`, `cells/<cell>/state.json`, payload bundles at `payloads/sha256/<hex>.nar.zst`, and per submission, under `cells/<cell>/submissions/<cell-run-id>/`, the objects `work` (opaque bytes), `submission.json` (`cell.submission/v1`, written last with the does-not-exist precondition, which is what the agent watches for), `status.json` (`cell.status/v1`: phases `accepted`, `resetting`, `fetching`, `running`, `publishing`, `sealed`, and at the end the outcome and the manifest's digest), `rejected.json` with a reason, and numbered log chunks `log/stdout.<n>` and `log/stderr.<n>`. The results bucket (`tan-nb-exp-cells-results`) is immutable: the agent may create objects and never overwrite, and a retention policy protects them from operators.

A lease is acquired by writing `lease.json` with the does-not-exist precondition. On HTTP 412 the client reads the lease and its metadata; the lease is expired when the object's `updated` time plus `ttlSeconds` plus thirty seconds is earlier than the storage service's own clock (taken from a response's `Date` header, never from the client), and an expired lease is taken over by rewriting with the observed generation as precondition, which again succeeds for exactly one contender. After winning, the client reads `quarantine.json` and, if it exists, releases and reports the quarantine. Renewal rewrites the object with the known generation every `ttlSeconds / 3`; losing that compare-and-swap means the lease is lost. Release deletes with the generation precondition. Cancellation sets `cancelRequested`. While work runs, the agent polls the lease every five seconds and kills the work when the lease changes, is cancelled or expires.

A submission embeds a complete `cell.payload/v1` descriptor (`schema`, `kind: "nix-nar-bundle"`, the bundle's URI, SHA-256 and size, `storePath`, `narHash`, `closurePaths`, `system`, and a `command` array whose first element is relative to the store path), the digest of the work file, an `env` map, a `reset` block (`postgres.major`, `postgres.databases`, `postgres.settings` from an allowlist of memory, WAL, checkpoint, durability, planner, autovacuum and logging settings; `cachePolicy` `cold` or `warm`; `broker.wipe`), `limits` (`wallClockSeconds`, `memoryMaxBytes`, `outputMaxBytes`), `requires` and free-form `labels`. The agent rejects what it cannot honour (`unsupported-payload-kind`, `unsupported-postgres-setting`, `postgres-major-unavailable`, `run-id-already-used`, `lease-mismatch`, `payload-digest-mismatch`), resets, imports the bundle, and runs `<storePath>/<command...> <work-file> <out-dir>` as the unprivileged user `cellrun` under a systemd unit with a memory limit below the machine's memory. The process environment is the submission's `env` plus `CELL_ENV_FILE`, `CELL_RUN_ID`, `CELL_SCRATCH_DIR`, `CELL_DRIVER_INDEX` and `CELL_DRIVER_COUNT`. The environment file is `cell.environment/v1`: the cell name, run and lease identifiers, `postgres` (`major`, `host`, `port`, `database`, `user`, `connectionString`), `broker` (`bootstrapServers`, `adminUrl`, or null), `otlp` (a `null` sink and a `file` sink, each with `grpc` and `http` URLs, or null), `metrics` and `drivers`. The exit status is recorded verbatim and never interpreted.

The published tree, layout version 1, is `gs://<results-bucket>/runs/<cell-run-id>/` with `manifest.json` (`cell.artifact-manifest/v1`, written last; its presence seals the run; it lists every other object with path, SHA-256, size and media type, and names the payload, lease and outcome), `submission/submission.json`, `submission/work`, `output/...` (the output directory verbatim), `logs/stdout.log`, `logs/stderr.log`, `logs/agent.log`, `metrics/export.jsonl.zst`, `metrics/window.json`, `cell/result.json` (`cell.run-result/v1`: outcome `completed`, `infrastructure-failure` with reasons, `cancelled` or `timed-out`, plus `entryExitCode`), `cell/fingerprint.json`, `cell/reset-evidence.json` and `cell/health.json`. The manifest's own digest also appears in the final `status.json`. The cell has no outcome meaning "slower" or "test failed".

Four properties of that protocol shape this plan and are handled explicitly. Payloads are NAR bundles, not a binary cache. There are two buckets. A cell run identifier names one submission while kenshou produces many runs per submission. And the PostgreSQL major is a property of the cell, fixed at creation (`cell-alpha` has 18, `cell-beta` 17), so the `pg.version` dimension is satisfied by choosing which cell to lease.

One mismatch must be resolved before Milestone 2's real-cell acceptance. The kernel's contract for an external PostgreSQL server is that every run creates a database named after its run identifier plus a template beside it and drops both at the end, which needs a role with the `CREATEDB` privilege that may connect to databases it has just created. The cell image inherits `nixos/modules/postgres.nix`, whose role `benchmark` has no `CREATEDB` and whose `pg_hba.conf` line is `host benchmark benchmark <cidr> trust`, that is, one database only. The fix belongs to the cell repository (`ensureClauses.createdb = true` on the role and `host all benchmark <cidr> trust` in `nixos/modules/cell-postgres.nix`) and is made there under the cell plan's trailers. `kenshou cell exec` checks the privilege first and fails fast with reason `cell-postgres-role-cannot-create-databases` so that the mismatch can never look like a test failure.

### The kernel and planner contracts relied on

A scenario is identified by `<layer>/<component>/<kind>/<name>`, declares a tier (`smoke`, `standard`, `extended`, `soak`), a placement (`local`, `cell`, `either`), knobs, the dimension values it supports and its environment requirements (`EnvRequirements` with `postgres :: Maybe PostgresRequirement {schemas, settings, needsServerControl}` and `kafka :: Bool`). The four dimensions are `telemetry.tracing`, `telemetry.metrics`, `pg.durability` (`fsync-off`, `durable`) and `pg.version` (`17`, `18`). A run is identified by a lowercase UUIDv7 and writes `<out>/<run-id>/` with `run-spec.json`, `run-result.json`, `manifest.json` (`kenshou.artifact-manifest/v1`, written last; a run directory is complete if and only if it exists), `samples/`, `series/`, `verdicts/`, `diagnosis/` and `logs/`. Outcomes are `passed`, `failed`, `errored`, `inconclusive` and `infrastructure-failure`; exit codes are 0, 1, 4, 3 and 4, and 2 for a usage error. A run specification's `environment` has `placement` (`local` or `cell`), `machineProfile`, `postgres` (either `{"mode": "ephemeral", "settings": {...}}` or `{"mode": "external", "connectionStringEnv": "VAR"}`; settings are rejected on an external server), and the opaque sections `kafka` (owned by `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md`, which defines an external-brokers form) and `telemetry`. Against an external server the kernel cannot change settings, so it verifies them: `server_version_num` must match `pg.version`, and `fsync` and `synchronous_commit` must match `pg.durability`; a mismatch is `infrastructure-failure`. `cohortExpectation.planHash`, when present, must equal the running binary's identity or the run is skipped as `infrastructure-failure` with reason `cohort-mismatch`. The JSON the cell supplies through `KENSHOU_CELL_FINGERPRINT` is embedded verbatim under `fingerprint.cell`. Documents redact passwords. New verbs are added as `CliCommand` values in `kenshou-cli/src/Kenshou/Cli/Registry.hs`, and a package contributes self-test scenarios through a `LayerBundle` whose layer is `selftest`. Schema files are named `schemas/kenshou.<name>.v<N>.schema.json`.

The visible cell client reuses `Kenshou.Core.Cli.Config` from EP-2. Define `Kenshou.Remote.Config.cellClientConfig` with `cell.store`, `cell.control-bucket`, `gcp.allowed-projects`, `load-testing-infra.path`, and optional secret `gcp.token`; map them explicitly to `KENSHOU_CELL_STORE`, `KENSHOU_CELL_CONTROL_BUCKET`, `KENSHOU_GCP_ALLOWED_PROJECTS`, `KENSHOU_LTI_DIR`, and `KENSHOU_GCS_TOKEN`. Built-ins remain below ordered strict-YAML `--config` files, then those environment bindings, then named cell flags. Effective non-secret values that affect a submission are written into `cell-session.json`; the token value is never serialized. `KENSHOU_PAYLOAD_*`, `KENSHOU_COHORT_IDENTITY`, `KENSHOU_HARNESS_*`, `KENSHOU_CELL_FINGERPRINT`, `KENSHOU_HEALTH_NOTICES`, fault-hook, clock-skew, and database variables remain protocol transport outside Settei. Run plans, payload descriptors and routing policies stay explicit `InputSource` documents and may not be supplied by ambient configuration.

Three kernel inputs exist specifically for a binary that did not come from a cabal checkout. A cell has no `dist-newstyle/cache/plan.json`, so the cohort identity is read from the file named by `KENSHOU_COHORT_IDENTITY` (or `--cohort-identity`), a `kenshou.cohort-identity/v1` document; without it `kenshou run` refuses to start, because a result without an identity is not evidence. A Nix-built binary cannot run `git`, so `fingerprint.kenshou.revision` (the full 40-character commit of this repository) and `dirty` come from `KENSHOU_HARNESS_REVISION` and `KENSHOU_HARNESS_DIRTY`; the evidence plan refuses to record a run without them. And `EnvRequirements.extraPostgres :: [(Text, PostgresRequirement)]` names further, independently restartable PostgreSQL servers (only the assembled-runtime plan uses it, for its two bounded contexts); the run specification carries a matching `environment.extraPostgres` object keyed by the same names, the fingerprint records one entry per server under `fingerprint.extraPostgres`, and in external mode every name needs its own connection string (`--pg-url-env NAME=VAR`, or `connectionStringEnv` inside the named entry).

Four sibling toolkits define inputs that only this plan can supply on a cell. The correctness toolkit (`docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md`) runs its cell-only injectors (`net-reject`, `net-drop`, `net-delay`, `disk-fill`, `memory-limit`) through the executable named by `KENSHOU_CELL_FAULT_HOOK`, called as `inject <fault> <json>` (prints a token), `heal <token>` and `heal-all`, and reports them unavailable when the variable is unset; its ledgers merge facts across processes using a clock-skew bound that defaults to `same-host` with 1000 microseconds and is overridden by `KENSHOU_CLOCK_SKEW_BOUND_MICROS`. The telemetry plan (`docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md`) does not emit a run plan for `kenshou overhead`; it exposes `planOverhead` (pure), `executeOverhead :: OverheadHooks -> OverheadPlan -> FilePath -> IO OverheadState`, whose hook `runChild :: RunSpec -> FilePath -> IO ExitCode` defaults to spawning `kenshou run`, and `analyseOverhead`, and it expects a slot's run directory at `<out>/<run-id>/` with a complete `manifest.json`; its knob `otel.endpoint` (text, empty meaning "spawn the built-in sink") names an external collector. The Kafka plan (`docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md`) runs Apache Kafka in KRaft mode locally, while the cell's broker role is a digest-pinned Redpanda container; both speak the Kafka protocol, the run specification's `environment.kafka` object selects the backend `ExternalBrokers` with a `brokers` list (addresses on `127.0.0.1:9092` are refused), and `withKafkaEnv` records the backend and broker version in the run result. The pgmq plan (`docs/plans/8-cover-pgmq-hs-in-isolation.md`) has partitioned-queue scenarios, selected by the knob `pgmq.queue-kind`, that probe for the PostgreSQL extension `pg_partman` and end `errored` with a remediation message when it is absent. Finally, the assembled-runtime plan (`docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) names every reduced soak `<name>-reduced` (tier `extended`, placement `either`) and places the multi-hour forms on a cell (tier `soak`, placement `cell`); each long stage is gated by the knob `soak.gate-run-result`, the path of the earlier stage's `run-result.json`, which on a cell must be a file the driver can read.

A run plan (`kenshou.run-plan/v1`) has `planId`, `cohort {name, planHash}`, `policy`, and `runs`, each with `ordinal`, a pre-assigned `runId`, `estimateMinutes`, `trial {group, arm, index, of}` for benchmark groups, `reasons` and a complete `spec`. `Kenshou.Plan.Execute.executePlan :: ExecuteOptions -> IO PlanSummary` runs the entries in order, one `kenshou run` child per entry, and writes `run-plan.json`, `plan-summary.json`, `specs/<ordinal>.json` and the run directories into the output directory; `Kenshou.Plan.Summary.summaryExitCode` maps the worst outcome to the contract exit code. The measurement toolkit offers `Kenshou.Measure.Compare.Ordering.pairedSchedule :: PairedOrdering -> Int -> Word64 -> [TrialSlot]` (ABBA or BAAB, with a shared `pairSeed` per pair), the command `kenshou compare --baseline DIR --candidate DIR ... --policy FILE --vary cohort`, which answers `infrastructure-failure` whenever machine profiles differ between arms or any input run was not evaluated, and a host-notice hook: when `KENSHOU_HEALTH_NOTICES` names a JSON-lines file of `kenshou.health-notice/v1` objects (`source`, `severity` `soft` or `hard`, `at`, `detail`), a notice inside the run's window becomes a health observation.

### How house repositories build Haskell with Nix, verified on disk

House flakes are thin flake-parts shells over a revision-pinned `github:shinzui/haskell-nix-dev` (GHC 9.12.4) generated by the Seihou module `nix-haskell-flake` 0.24.0 (`mori://shinzui/seihou-modules`, `/Users/shinzui/Keikaku/bokuno/seihou-modules/modules/haskell/nix-haskell-flake`). By default they provide development shells only. Two module variables matter: `nix.builtin-package` (the bootstrap plan already sets it to `false`, because there is no root package) and `nix.haskell-nix` (the bootstrap plan leaves it `false`; this plan sets it to `true`), which adds the module-owned, revision-pinned input `inputs.haskell-nix`. That input is `mori://shinzui/haskell-nix` (`/Users/shinzui/Keikaku/bokuno/haskell-nix`), the shared patch registry. It exports `lib.haskellExtensions.hackage` and `.github` (compatibility patches for hasql, hs-opentelemetry, crypton and others, plus first-party packages from Hackage tarballs or from locked GitHub revisions), and `lib.mkChannelExtension { channel, disableProfiling, disableHaddock }` for non-default build settings; profiling and Haddock are off for the whole set by default because profiling is contagious across dependency edges. Its first-party lock covers the keiki, keiro, kiroku, pg-migrate, pgmq-hs and shibuya families; it carries `shibuya-pgmq-adapter` as a hand-written registry entry (0.14 at the revision the Seihou module pins, 0.16.0.0 at the repository's head, which is what the cohort wants), only unbreaks nixpkgs' `ephemeral-pg` 0.2.1.0 (the cohort needs 0.3.1.0), and has no entry for `shibuya-kafka-adapter`, `kafka-effectful`, `hw-kafka-streamly` or `hw-kafka-client`. Every first-party entry is `dontCheck (doJailbreak ...)`.

The closest packaging precedents are `mori://shinzui/okf` (`/Users/shinzui/Keikaku/bokuno/okf/flake.module.nix`: a multi-package repository with no root `.cabal` file, `callCabal2nix` per package directory on a set extended by the shared channel) and the unregistered `kiroku-bench` project (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench/flake.module.nix`), which produced the old harness's binary by applying `disableLibraryProfiling`, `disableSharedExecutables` and `disableSharedLibraries` but had to skip `justStaticExecutables`' final check because some dependency left a reference to the compiler in the linked binary; with that reference the closure is gigabytes, without it a few hundred megabytes. `mori://shinzui/mori-app` (`/Users/shinzui/Keikaku/bokuno/mori-project/mori-app/flake.module.nix`) shows the remedy for a package directory that refers to files outside itself: evaluate the `.cabal` file from the subdirectory, but build with `src` set to the whole repository and `sourceRoot = "source/<subdir>"`. `hw-kafka-client` links the C library through `extra-libraries: rdkafka`, which `callCabal2nix` maps to nixpkgs' `rdkafka`.

In `mori://shinzui/load-testing-infra`, `scripts/upload-images.sh` shows how to build for `x86_64-linux` from a macOS workstation: address the attribute by its full path (`.#packages.x86_64-linux.<name>`, because the shorthand resolves to the current system), let the configured remote builder do the work, and, because copying a large result back over the IAP tunnel has failed at 1.4 GB, recover with `nix eval --raw` to learn the output path and continue on the builder, uploading from the builder to the bucket. `scripts/setup-nix-builder.sh` documents the builder: instance `nix-builder-x86`, Ubuntu with Determinate Nix, started on demand by the workstation's SSH configuration. `scripts/iap-ssh.sh` (subcommands `ssh`, `scp`, `recv-file`, `tunnel`; variables `ZONE`, `SSH_USER`, `SSH_KEY`; retries on transient tunnel failures) is the only supported SSH path; it refuses any project but `tan-nb-exp`. That repository's `CLAUDE.md` states the project-isolation policy (every resource in `tan-nb-exp`, every `gcloud` call with `--project`), which this client honours by refusing a cell whose descriptor names a project outside `KENSHOU_GCP_ALLOWED_PROJECTS` (default `tan-nb-exp`). The lessons of the old harness that this plan acts on: results collected to a laptop over a tunnel were fragile and unretained; mutable shared configuration leaked from one run into the next; a two-core driver saturated before PostgreSQL did; one roughly 270-second checkpoint per 600-second window decided the result.

### ADR context

There is no local ADR corpus until `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` creates `docs/adr/` as a profile-governed OKF bundle (OKF is the house format of Markdown files with YAML frontmatter, validated by the `okf` tool against a Dhall profile). When you start, scan its filenames and read the records about cohort identity, the protocol ownership and environments. Cross-repository decisions that shape this plan: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` treats only structural checks and controlled candidate-against-control workloads as authoritative performance evidence, which is why Milestone 3 pairs arms inside one lease instead of comparing numbers across days. `mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence and an explicit run identity, which is why fetched trees are never modified and cell evidence is linked. `mori://shinzui/mori/okf/adrs/concepts/ADR-24` and `mori://shinzui/rei/okf/adrs/concepts/ADR-18` record that Cabal selects a cohort by `index-state` while Nix selects it by a revision in another repository, that the divergence fails silently because bounds are stripped, and that the proof is to read the versions off one's own evaluated package set; this plan adopts the proof and departs from their "never pin locally" rule for the reason in the Decision Log. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact URI is pending: `mori://shinzui/shibuya` at `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` is the precedent for binding evidence to exact commits and a plan hash.

Two decisions of this plan deserve new ADRs: "The cell payload pins the runtime cohort from the cohort descriptor, and an identity check rather than a green Nix build proves it", and "A kenshou run on a cell is addressed as `<cell-run-id>/<run-id>`; cell evidence is linked to sealed results and never merged into them, and a cell infrastructure failure overrides nested outcomes". Allocate each handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, add a log entry with `okf log add`, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

All paths are relative to `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` unless they begin with `/`. Files outside the new package that this plan touches are `.seihou/config.dhall` and the regenerated `flake.nix` and `flake.lock`, `flake.module.nix`, `Justfile`, `.gitignore`, `kenshou-cli/kenshou-cli.cabal` and `kenshou-cli/src/Kenshou/Cli/Registry.hs` (one dependency, one import, one element in `bundles`, one in `commands`), `kenshou-core/src/Kenshou/Core/Cohort.hs` and its schema (one optional member), `schemas/`, `policies/cell-routing.json`, `docs/guides/`, `docs/adr/` and `mori.dhall`. New schema files are named `schemas/kenshou.<name>.v<N>.schema.json`, the convention the bootstrap plan established and the kernel plan adopted.

### Milestone 1 — the content-addressed kenshou payload

Scope: Nix package outputs and their publication. At the end `nix build .#kenshou-released` produces a working `kenshou` for the local system, the same attribute under `packages.x86_64-linux` builds on the remote builder, `just payload-check released` and `just payload-check head` prove that the Nix builds link the cohorts the descriptors name, and `kenshou cell payload publish --cohort released --out payloads/released.json` leaves one object `payloads/sha256/<hex>.nar.zst` in the control bucket and one `kenshou.payload/v1` document on disk. Nothing in this milestone needs a cell; only the last step needs the bucket.

Enable the shared channel. Add `` `nix.haskell-nix` = "true" `` to `.seihou/config.dhall`, run `seihou run nix-haskell-flake`, and commit the regenerated `flake.nix` and `flake.lock` (never edit them by hand). In `flake.module.nix` add `pkgs.zstd` and `pkgs.google-cloud-sdk` to `haskellProject.extraDevPackages` and the line `imports = [ ./nix/kenshou ];` at the top level of the module. Remember that Nix evaluates only files tracked by git: `git add` every new file under `nix/` before building.

Lock the cohort for Nix. The descriptor gives versions and commits but Nix also needs content hashes, so `scripts/payload-lock.sh <cohort>` reads `cohort/<cohort>.json` with `jq` and writes `nix/cohort-locks/<cohort>.lock.json`. For a package whose component source is `hackage` it fetches `https://hackage.haskell.org/package/<name>-<version>/<name>-<version>.tar.gz` twice with `nix-prefetch-url`: once flat (that is the `pkg-src-sha256` cabal records, kept as `tarballSha256`) and once with `--unpack`, converted with `nix hash convert --to sri` (that is what `callHackageDirect` wants). For a `git` component it runs `nix flake prefetch --json github:<owner>/<repo>/<rev>` once per component and records `hash`. The script is deterministic and re-running it without a descriptor change produces an identical file.

```json
{
  "schema": "kenshou.cohort-nix-lock/v1",
  "cohort": "head",
  "descriptorSha256": "4b1f…",
  "packages": {
    "kiroku-store": { "source": "hackage", "version": "0.8.0.1", "sha256": "sha256-…", "tarballSha256": "9c0e…" },
    "shibuya-core": { "source": "git", "owner": "shinzui", "repo": "shibuya", "rev": "a26d60609f118f8ca5357c6c16f02317e10fb819",
                      "subdir": "shibuya-core", "version": "0.9.0.3", "hash": "sha256-…" }
  }
}
```

`nix/kenshou/cohort-overlay.nix` is a function `{ pkgs, lock, infoTable ? false }: hself: hsuper: { ... }` that produces one entry per locked package: `callHackageDirect { pkg; ver; sha256; } { }` for Hackage, and for git `callCabal2nix name "${src}/${subdir}" { }` with `src = pkgs.fetchFromGitHub { owner; repo; rev; hash; }` evaluated once per repository and revision, switched to the whole-repository `src` plus `sourceRoot` form when a package's directory contains symbolic links that point outside it. Every entry is wrapped in `dontCheck (doJailbreak ...)`, as the shared channel does, because the runtime packages' own tests need PostgreSQL and are not this build's business. The module asserts `builtins.hashFile "sha256" ../../cohort/<name>.json == lock.descriptorSha256` and fails with the message "cohort lock is stale; run just payload-lock <name>". If a repository is private and `fetchFromGitHub` cannot reach it from the builder, use `builtins.fetchGit { url; rev; allRefs = true; }`, which is fetched on the workstation with the operator's credentials, and record it.

`nix/kenshou/packages.nix` builds the set and the executable for one cohort and one variant:

```nix
{ inputs, pkgs, lib, cohort, variant }:   # variant: "default" | "info-table" | "profiled"
let
  lock = builtins.fromJSON (builtins.readFile (../cohort-locks + "/${cohort}.lock.json"));
  channel = inputs.haskell-nix.lib.mkChannelExtension { channel = "hackage"; disableProfiling = variant != "profiled"; };
  infoTables = _: hsuper: lib.optionalAttrs (variant == "info-table") {
    mkDerivation = args: hsuper.mkDerivation (args // {
      configureFlags = (args.configureFlags or [ ])
        ++ [ "--ghc-option=-finfo-table-map" "--ghc-option=-fdistinct-constructor-tables" ];
    });
  };
  names = lib.filter (n: lib.hasPrefix "kenshou-" n && builtins.pathExists (../.. + "/${n}/${n}.cabal"))
            (builtins.attrNames (builtins.readDir ../..));
  local = hself: _: lib.genAttrs names (n:
    pkgs.haskell.lib.compose.dontCheck (hself.callCabal2nix n
      (lib.cleanSourceWith { name = "${n}-source"; src = ../.. + "/${n}"; filter = _: _: true; }) { }));
  hp = pkgs.haskell.packages.ghc9124.override {
    overrides = lib.composeManyExtensions [
      infoTables
      (channel pkgs.haskell.lib.compose pkgs)
      (import ./cohort-overlay.nix { inherit pkgs lock; })
      local
    ];
  };
in { inherit hp lock; }
```

The package list is discovered the way `cabal.project` discovers it (`kenshou-*/*.cabal`), so later plans add packages without touching Nix, and each package's source is copied to its own content-addressed store path so that a documentation commit does not rebuild Haskell code. The executable is `hp.kenshou-cli` passed through `disableLibraryProfiling`, `disableSharedExecutables` and `disableSharedLibraries` (plus `enableExecutableProfiling` for the `profiled` variant), then `justStaticExecutables`. If that last step fails because the binary refers to the compiler, find the chain with `nix why-depends` and remove it, first by setting `enableSeparateDataOutput = true` on the kenshou packages (a `Paths_` module that embeds the data directory of a library output is the usual cause), otherwise with `remove-references-to` in `postFixup`; if two hours do not resolve it, fall back to the three `disable*` steps alone as `kiroku-bench` did, and record the closure size in Surprises & Discoveries. The final derivation wraps the binary with `makeWrapper`, using `--set-default` so that an operator can still override, for the inputs a payload must carry with it because nothing on a cell can compute them: `KENSHOU_COHORT_IDENTITY` (the identity file below, captured at build time because a cell has no cabal plan), `KENSHOU_HARNESS_REVISION` and `KENSHOU_HARNESS_DIRTY` (the full 40-character commit and the dirty flag, because a Nix-built binary cannot run `git`: `inputs.self.rev` and `false` for a clean tree, otherwise `lib.removeSuffix "-dirty" inputs.self.dirtyRev` and `true`), `KENSHOU_PG17_BIN` and `KENSHOU_PG18_BIN` (`${pkgs.postgresql_17}/bin`, `${pkgs.postgresql_18}/bin`) and `KENSHOU_PAYLOAD_IDENTITY`. Child processes started with `kenshou worker` inherit all of them. The RTS options `-N -T` come from the executable's cabal stanza; do not repeat them. The wrapper changes with every commit and the Haskell derivations do not, so a new commit costs an export and an upload, not a compile.

`nix/kenshou/identity.nix` renders `share/kenshou/cohort-identity.json` in the exact shape of `kenshou.cohort-identity/v1`: `cohort`, `compiler` (`"ghc-${hp.ghc.version}"`), `cabalVersion` (the string `nix`), `os` and `arch` (from `pkgs.stdenv.hostPlatform.parsed`, spelled as `System.Info` spells them), `indexState` and `descriptorSha256` copied from the descriptor, and `components` grouped as the descriptor groups them, where each package's `version` is read from the evaluated set (`hp.${name}.version`, never from the lock, so that an overlay that failed to apply is visible) and its `source` is `hackage` with `tarballSha256` or `git` with location, revision and subdirectory. `planHash` follows the bootstrap plan's recipe as closely as a Nix build allows: one line `<name> <version> <src> -` per locked package with `<src>` rendered `hackage:<tarballSha256>` or `git:<location>@<rev>#<subdir or ->`, plus the lines `compiler ghc-9.12.4`, `resolver nix`, `nixpkgs <inputs.nixpkgs.rev>` and `haskell-nix <inputs.haskell-nix.rev>`, sorted bytewise, joined with newlines, hashed with SHA-256 and rendered `sha256:<hex>`. It can never equal a cabal hash, and it is the same on macOS and Linux. Add the optional member `resolver` (`"cabal"` or `"nix"`, absent meaning `cabal`) to `CohortIdentity`, its codec and its schema; this is an additive change to a document owned by the bootstrap plan, so update Integration Point 2 in the MasterPlan first. The same file also yields `share/kenshou/payload-identity.json` (`kenshou.payload-identity/v1`: cohort, variant, system, compiler, the two input revisions, and the list of kenshou packages with their versions). The identity attribute set is also exposed as `passthru.cohortIdentity` so that it can be read without building.

`nix/kenshou/default.nix` is the flake-parts module that maps cohorts `released` and `head` and the three variants to `packages.<system>.kenshou-<cohort>` and `kenshou-<cohort>-<variant>`, with `packages.default = kenshou-released`. The variants mirror the cabal project variants of `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md`, which left the Nix side to this plan: `info-table` compiles every non-boot package with allocation-site tables and still links the ordinary run-time system (run it with `+RTS -hi`); `profiled` builds profiled libraries for the whole closure and is the explicit heavy option (expect the first build to take hours on the two-core builder). The closure-type and event-log modes of that plan need no variant.

The equality gate is the recipe `payload-check`: evaluate `.#packages.x86_64-linux.kenshou-<cohort>.cohortIdentity` to a file, then run `kenshou cohort check` with `KENSHOU_COHORT_IDENTITY` pointing at it and the cohort's descriptor (confirm the flag spelling with `kenshou cohort check --help`). Since `just cohort-check` already checks the cabal plan against the same descriptor, passing both makes the two builds equal for every package the descriptor names, which includes the `effectful` and `hs-opentelemetry` components. When the gate reports a version difference for a third-party component, add that package to the descriptor's lock the same way; do not loosen the gate. `kenshou cell payload publish` runs the gate itself and refuses to publish on any mismatch.

Create the package. `kenshou-remote/kenshou-remote.cabal` follows the house shape (cabal-version 3.0, `common warnings`, `GHC2024`, the default extensions the kernel uses) with a library and the test suite `kenshou-remote-test`. `kenshou-remote/src/Kenshou/Remote/Store.hs` is the seam everything else is tested through:

```haskell
data Precondition = NoPrecondition | DoesNotExist | GenerationIs !Int64
data ObjectMeta = ObjectMeta {generation :: !Int64, size :: !Int64, updated :: !UTCTime, contentType :: !Text}
data PutOutcome = Written !ObjectMeta | PreconditionFailed

data ObjectStore = ObjectStore
  { getObject :: Bucket -> ObjectName -> IO (Maybe (LazyByteString, ObjectMeta))
  , statObject :: Bucket -> ObjectName -> IO (Maybe ObjectMeta)
  , putObject :: Bucket -> ObjectName -> Text -> Precondition -> LazyByteString -> IO PutOutcome
  , putFile :: Bucket -> ObjectName -> Text -> Precondition -> FilePath -> IO PutOutcome
  , downloadTo :: Bucket -> ObjectName -> FilePath -> IO (Maybe ObjectMeta)
  , deleteObject :: Bucket -> ObjectName -> Precondition -> IO Bool -- False: precondition failed
  , listObjects :: Bucket -> Text -> IO [(ObjectName, ObjectMeta)]
  , serverTime :: IO UTCTime
  }
```

`Kenshou.Remote.Store.Gcs.newGcsStore :: TokenProvider -> IO ObjectStore` speaks the JSON API with `http-client` and `http-client-tls`: media upload to `/upload/storage/v1/b/<bucket>/o?uploadType=media&name=<name>&ifGenerationMatch=<n>`, resumable upload in 8 MiB chunks for files above 8 MiB, `GET /storage/v1/b/<bucket>/o/<name>` for metadata and with `alt=media` for content, paged `GET .../o?prefix=`, `DELETE` with the precondition, HTTP 412 mapped to `PreconditionFailed`, retries with backoff on 429 and 5xx, and `serverTime` from the `Date` header of a metadata request. A `TokenProvider` is, in order of preference, the variable `KENSHOU_GCS_TOKEN`, the metadata server on a Google VM, or `gcloud auth print-access-token` cached for forty-five minutes; tokens are never logged. `Kenshou.Remote.Store.File.newFileStore :: FilePath -> IO ObjectStore` keeps objects and a generation counter in a directory under an exclusive lock file. `KENSHOU_CELL_STORE=file:<dir>` selects it everywhere, which is how tests and the fake cell run.

`Kenshou.Remote.Payload.Nix` wraps the external tools with `typed-process`: `nixBuild :: FlakeRef -> IO (Either PayloadError StorePath)`, `nixEvalJson`, `closureInfo` (`nix path-info --json -r`), and `exportBundle :: StorePath -> FilePath -> IO BundleInfo`, which runs `nix-store --export $(nix-store -qR <path>) | zstd -19 -T1` into a temporary file while hashing the compressed bytes. `Kenshou.Remote.Payload` defines the descriptor and `publishPayload :: ObjectStore -> PublishOptions -> IO (Either PayloadError PayloadDescriptor)`: refuse a dirty work tree unless `--allow-dirty`; run the equality gate; build; export; upload to `payloads/sha256/<hex>.nar.zst` with `DoesNotExist`, treating a failed precondition with an equal size as "already published"; write the document. With `--via-builder <instance>` it instead runs `<lti>/scripts/cell/payload-publish.sh <repo>#packages.x86_64-linux.<attr> bin/kenshou cell exec` with `BUILDER_INSTANCE` set and parses the `cell.payload/v1` it prints, so that the export and the upload happen on the builder. The descriptor:

```json
{
  "schema": "kenshou.payload/v1",
  "cohort": "released",
  "variant": "default",
  "flakeAttr": "packages.x86_64-linux.kenshou-released",
  "harness": { "revision": "869c38d0…", "dirty": false },
  "cohortIdentity": { "schema": "kenshou.cohort-identity/v1", "resolver": "nix", "planHash": "sha256:7e41…" },
  "cohortCheck": { "status": "consistent", "packagesChecked": 44 },
  "cell": { "schema": "cell.payload/v1", "kind": "nix-nar-bundle",
            "bundle": { "uri": "gs://tan-nb-exp-cells-control/payloads/sha256/9f2c…e1.nar.zst", "sha256": "9f2c…e1", "bytes": 96468992 },
            "storePath": "/nix/store/<hash>-kenshou-released", "narHash": "sha256-…", "system": "x86_64-linux",
            "command": ["bin/kenshou", "cell", "exec"] },
  "createdAt": "2026-10-05T10:02:11Z"
}
```

The bundle digest identifies the delivered bytes; `storePath` and `narHash` identify the content, and two exports of one closure with different zstd versions may differ in the former and never in the latter. `kenshou cell payload show FILE` prints a descriptor and re-checks that the object exists with the stated size.

### Milestone 2 — `kenshou cell` lease, submit, watch and fetch

Scope: the whole client and the cell-side adapter. At the end `kenshou cell run` takes a plan to verified results on a real cell, and the same code passes an end-to-end test on a laptop against the fake cell.

`Kenshou.Remote.Cell.Docs` holds a Haskell type with hand-written codecs for each document the client touches: `CellDescriptor`, `Lease`, `Quarantine`, `CellPayload`, `Submission` (with `ResetBlock` and `Limits`), `CellStatus`, `Rejected`, `CellEnvironment`, `CellRunResult` and `CellManifest`. Decoders ignore unknown members (the cell may add fields); encoders emit exactly what the cell's schemas allow. Copy the cell repository's examples from `schemas/cell/examples/` into `kenshou-remote/test/golden/cell/` with a `SOURCE` file naming the commit they came from, and test that each decodes and that encoding our own values validates against the copied schemas with `check-jsonschema`.

`Kenshou.Remote.Cell.Lease` implements the algorithm restated in Context, step for step, because it must interoperate with the Rust client `cellctl`:

```haskell
data LeaseRequest = LeaseRequest {owner :: Text, purpose :: Text, ttlSeconds :: Int}
data AcquireOutcome = Acquired LeaseHandle | Busy Lease | Quarantined Quarantine
acquireLease :: ObjectStore -> CellRef -> LeaseRequest -> IO AcquireOutcome
renewLease :: ObjectStore -> CellRef -> LeaseHandle -> IO Bool -- False: the lease is lost
releaseLease :: ObjectStore -> CellRef -> LeaseHandle -> IO Bool
reattachLease :: ObjectStore -> CellRef -> LeaseId -> IO (Maybe LeaseHandle) -- for resume and release by identifier
requestCancel :: ObjectStore -> CellRef -> Bool {- force -} -> IO Bool
withHeartbeat :: ObjectStore -> CellRef -> LeaseHandle -> (IO Bool {- still held? -} -> IO a) -> IO a
```

Lease and cell run identifiers are UUIDv7 values from the kernel's generator. `withHeartbeat` renews every `ttlSeconds / 3` on a labelled thread and flips the flag on the first lost renewal; callers check it before every submission and abandon the session when it is false. Two modes exist. A held lease (default TTL 120 seconds) needs the client alive and frees the cell within two and a half minutes of a crash. A detached lease (`--detach`) takes a TTL equal to the session's wall-clock budget plus ten minutes and no heartbeat, so that a twenty-four-hour soak does not need a laptop to stay awake; `kenshou cell resume --session DIR` re-attaches later and releases early.

`Kenshou.Remote.Cell.Prepare` is pure and is where a plan meets a cell.

```haskell
data RejectReason
  = PlacementLocalOnly | UnknownScenario | PgVersionMismatch {wanted :: Int, cellHas :: Int}
  | DurabilityNotDurable | NeedsServerControl Text {- "primary" or the extra server's name -}
  | NeedsBrokerButCellHasNone | KafkaMappingUnavailable | MissingCapability Text | PayloadLabelUnknown Text
data Granularity = GranularityAuto | GranularityPlan | GranularityRun
data ResetParams = ResetParams {postgresMajor :: Int, settings :: Map Text Text, cachePolicy :: CachePolicy, brokerWipe :: Bool, collectTraces :: Bool}
data Slice = Slice {index :: Int, payload :: PayloadLabel, reset :: ResetParams, entries :: NonEmpty PlannedRun, wallClockSeconds :: Int}
data Routed = Routed {perCell :: Map CellName RunPlan, local :: Maybe RunPlan, unroutable :: [(PlannedRun, RejectReason)]}

prepareForCell :: Registry -> CellDescriptor -> Maybe CellCapabilities -> [RoutingRule] -> Map PayloadLabel PayloadDescriptor -> PrepareOptions -> RunPlan -> Prepared
routePlan :: Registry -> NonEmpty (CellDescriptor, Maybe CellCapabilities) -> [RoutingRule] -> RunPlan -> Routed
sliceRuns :: Granularity -> [PreparedRun] -> [Slice]
submissionFor :: CellRef -> LeaseId -> PayloadDescriptor -> Slice -> WorkInfo -> Submission
```

For each planned run `prepareForCell` looks the scenario up in the registry and applies these rules. A scenario placed `local` is rejected. If the scenario requires PostgreSQL and does not need server control, the run will use the cell's server: its `pg.version` must equal the descriptor's major (otherwise `PgVersionMismatch`), its `pg.durability` must be `durable` (otherwise `DurabilityNotDurable`, unless `--coerce-durable` is given and the scenario supports `durable`, in which case the dimension is rewritten and the change recorded); the settings the scenario requires and the settings of the plan's ephemeral environment, together with `--pg-setting` flags and `fsync=on`, `synchronous_commit=on`, `full_page_writes=on`, move into `ResetParams.settings`, and the run's environment becomes `{"mode": "external", "connectionStringEnv": "KENSHOU_CELL_PG_URL"}`. Extra servers take the degraded, shared-server form: for every name in `extraPostgres` the run's `environment.extraPostgres.<name>` becomes `{"mode": "external", "connectionStringEnv": "KENSHOU_CELL_PG_URL_<NAME>"}` (the name upper-cased, `-` replaced by `_`), all variables will point at the cell's one server, where the kernel gives each name its own fresh database, and the extra requirements' settings join the reset block (conflicting values for one setting are a usage error). If the primary or any extra requirement needs server control, the run is rejected with `NeedsServerControl`, because the cell's server cannot be stopped by a payload; with `--ephemeral-on-driver`, and only for kinds `correctness` and `concurrency`, such a run instead keeps all its environments ephemeral and the payload's bundled servers provide either major. `route` sends rejected runs of this kind to `plan.local.json`. If it needs Kafka and the descriptor lists no broker instance, it is rejected; if the Kafka plan is not implemented yet, the reason is `KafkaMappingUnavailable`. Finally the routing rules are applied: `policies/cell-routing.json` is a list of `{ "when": { "knob": NAME, "equals": VALUE } | { "scenario": SELECTOR }, "requires": CAPABILITY, "why": TEXT }`, seeded with the rule that knob `pgmq.queue-kind` equal to `partitioned` requires `postgres.pg_partman`; a run that matches a rule whose capability the cell's cached capabilities deny is rejected with `MissingCapability`, and when no capabilities are cached the run is accepted with a warning that names `kenshou cell probe`. The planner itself needs no change: plan with `kenshou plan --placement cell`, then let `route` or `submit --skip-incompatible` filter, and every exclusion is written down with its reason. Every run gets `environment.placement = "cell"`, a machine profile derived from the descriptor alone so that it is equal across arms and leases on equally shaped cells (`gcp/<zone>/<driver machine type>x<count>+<postgres machine type>/<disk type>-<size>g/pg<major>`, for example `gcp/us-west1-a/n2-standard-8x1+n2-standard-8/pd-ssd-200g/pg18`), an explicit seed if it had none, and `cohortExpectation` rewritten to the name and plan hash of the payload it will run under, because the plan was made by a cabal build whose hash the payload can never match. The payload is chosen by label: the run's trial arm when it names a payload, otherwise `default`.

`sliceRuns` under `GranularityAuto` starts a new slice whenever the payload or the reset parameters change, and always before and after a run of kind `benchmark` or `soak`. A slice's work file is the original plan document with `runs` restricted to the slice, so it is itself a valid `kenshou.run-plan/v1`. Its wall-clock limit is the sum of the runs' timeouts plus five minutes; `outputMaxBytes` defaults to 20 GiB; the cache policy defaults to `cold`. `submissionFor` also fills the submission's `env` with `KENSHOU_PAYLOAD_BUNDLE_SHA256`, `KENSHOU_PAYLOAD_STORE_PATH`, `KENSHOU_PAYLOAD_NAR_HASH`, `KENSHOU_PAYLOAD_COHORT`, `KENSHOU_OTLP_SINK` (`null` or `file`), an optional `GHCRTS` from `--rts` for the diagnostic variants, and labels naming the session, the plan and the slice.

`Kenshou.Remote.Cell.Exec.cellExec :: Registry -> FilePath -> FilePath -> IO ExitCode` is the body of the hidden verb `kenshou cell exec <work-file> <out-dir>`, the payload's command. On a driver whose `CELL_DRIVER_INDEX` is not 0 it writes `idle-driver.json` and exits 0, because kenshou starts with one driver. Otherwise it maps the cell's generic environment to kenshou's inputs, in this order.

It reads `CELL_ENV_FILE` (absent or invalid: exit 4, reason `cell-environment-missing`), connects to PostgreSQL and checks the major, `fsync` and the role's `rolcreatedb` (exit 4 with the reason given in Context), and probes capabilities: `pg_partman` from `pg_available_extensions` (available or not, and the version), and, when the environment file has a broker, its implementation and version from the Redpanda admin interface (`GET <adminUrl>/v1/brokers`, two-second timeout, `unknown` on failure).

It builds the process environment that `kenshou run` children inherit. `KENSHOU_CELL_PG_URL`, and `KENSHOU_CELL_PG_URL_<NAME>` for every extra server named anywhere in the plan, all carry the environment file's connection string. `XDG_CACHE_HOME` and `TMPDIR` point under `CELL_SCRATCH_DIR`. `KENSHOU_COHORT_IDENTITY`, `KENSHOU_HARNESS_REVISION` and `KENSHOU_HARNESS_DIRTY` are already set by the payload's wrapper and are only checked for presence (absent: exit 4, reason `payload-identity-missing`, which means someone submitted an unwrapped binary). `KENSHOU_CELL_FAULT_HOOK` is set to the environment file's optional `faultHook` path when that member exists and the file is executable, and is otherwise left unset, so that the correctness toolkit reports cell-only injectors as unavailable; when it is set, `heal-all` is called once before the plan starts and once after it ends, whatever the outcome. `KENSHOU_CLOCK_SKEW_BOUND_MICROS` is left unset when `CELL_DRIVER_COUNT` is 1; with several drivers it is twice the sum of the absolute last offset, the root dispersion and half the root delay reported by `chronyc -c tracking`, rounded up with a floor of 1000, or 50000 when `chronyc` is not available, and the source (`chrony` or `assumed`) is recorded.

It resolves what only the cell knows with `resolveOnCell :: Registry -> CellEnvironment -> OtlpSink -> RunPlan -> IO (Either Text RunPlan)`: for runs whose scenario requires Kafka, `environment.kafka` becomes the Kafka plan's `ExternalBrokers` form with `brokers` from `broker.bootstrapServers` and no proxied lanes (read that plan's schema `kenshou.kafka-env/v1` for the spellings); for runs whose `telemetry.tracing` is `sdk-otlp` and whose scenario declares the knob `otel.endpoint`, that knob is set to the chosen sink's HTTP URL; for this package's own `cell-environment` scenario, the knobs `remote.otlp-endpoint` and `remote.kafka-bootstrap` are filled from the environment file when they were left empty and `remote.expect-placement` becomes `cell`; and input materialisation: any text knob whose value is a `gs://` URI inside the cell's own results bucket is downloaded with the VM's service-account token to `<scratch>/inputs/<sha256>/<basename>`, the knob is rewritten to that path, and the mapping with its digest is written to `<out-dir>/kenshou-cell/inputs.json`. That last rule is what lets a gated soak such as `runtime/order-flow/soak/steady-4h` name the earlier stage's result, which lives in the results bucket because that stage also ran on a cell, as `soak.gate-run-result=gs://<results-bucket>/runs/<cell-run-id>/output/<run-id>/run-result.json`. It writes `<out-dir>/kenshou-cell/plan.resolved.json` and `<out-dir>/kenshou-cell/context.json`, pointing `KENSHOU_CELL_FINGERPRINT` at the latter.

It starts the health-notice mapper and points `KENSHOU_HEALTH_NOTICES` at `<out-dir>/kenshou-cell/health-notices.jsonl`. The mapper is a labelled thread with two sources. It holds a hanging request on `http://metadata.google.internal/computeMetadata/v1/instance/maintenance-event?wait_for_change=true` and appends a `hard` notice with source `gce-maintenance-event` for every value other than `NONE`. And, when the cell exposes its rolling health observations to the payload (requested from the cell plan as a JSON-lines file named by `CELL_HEALTH_FILE`; until then, best effort against the PostgreSQL role agent's `GET http://<postgres-host>:9600/v1/health` with the lease identifier), it translates them every five seconds: a maintenance event on any cell machine and free space under five percent become `hard` notices, CPU steal or background load above the cell policy's threshold become `soft` ones, each with source `cell-health:<gate>:<machine>`. A `hard` notice makes the measurement toolkit end the run `infrastructure-failure` and a `soft` one `inconclusive`, so a disturbed trial can never be judged a regression, even before the cell has written its own verdict.

Finally it calls `executePlan` on the resolved plan with the output directory and exits with `summaryExitCode`. The context document is what appears under `fingerprint.cell` of every run result:

```json
{
  "schema": "kenshou.cell-context/v1",
  "cell": "alpha", "cellRun": "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9", "leaseId": "0199a3c1-0d52-7f10-8a77-6e0c4b2d9f01",
  "resetGranularity": "per-slice", "driver": { "index": 0, "count": 1 },
  "gce": { "zone": "us-west1-a", "machineType": "n2-standard-8", "cpuPlatform": "Intel Ice Lake", "instanceId": "4711…", "onHostMaintenance": "MIGRATE" },
  "postgres": { "major": 18, "host": "10.0.0.2", "port": 5432, "placement": "cell-server", "extraPostgres": "shared-server",
                "extensions": { "pg_partman": { "available": false, "version": null } } },
  "broker": { "implementation": "redpanda", "version": "v25.2.4", "bootstrapServers": "10.0.0.5:9092" },
  "otlpSink": "null", "faultHook": false, "clock": { "source": "same-host", "skewBoundMicros": null },
  "payload": { "bundleSha256": "9f2c…e1", "storePath": "/nix/store/<hash>-kenshou-released", "narHash": "sha256-…",
               "cohort": "released", "variant": "default", "harness": { "revision": "869c38d0e1…", "dirty": false } }
}
```

That is how the payload digest, the broker implementation and version that served the run, and the presence of `pg_partman` are recorded in the run result. The `gce` member is read from the metadata server with a two-second timeout and omitted elsewhere; `broker` is null on a cell without the broker role; `postgres.placement` is `driver-ephemeral` for a run admitted with `--ephemeral-on-driver`.

The package contributes one scenario through `Kenshou.Remote.Selftest.bundle` (layer `selftest`): `selftest/remote/correctness/cell-environment`, tier `smoke`, placement `either`, revision 1, requiring PostgreSQL with the kiroku schema only, supporting `pg.durability` `fsync-off` (default) and `durable` and `pg.version` `18` (default) and `17`. Its knobs are `remote.expect-placement` (text, one of `any`, `local`, `cell`, default `any`), `remote.otlp-endpoint` (text, default empty) and `remote.kafka-bootstrap` (text, default empty). It establishes that the environment the kernel hands a scenario is the one the run specification asked for, with the failure labels `placement-as-expected` (the specification's placement, the presence of `CELL_RUN_ID` and the knob agree), `postgres-mode-as-expected` (external on a cell), `pg-version-honoured`, `pg-durability-honoured`, `database-is-fresh` (the migrated kiroku tables exist and are empty), `otlp-reachable` (an empty OTLP/HTTP JSON export to `<endpoint>/v1/traces` is accepted, when the knob is set) and `kafka-reachable` (a TCP connection succeeds, when set). It passes when no label failed and writes what it saw under `putSummary ctx Verdicts "cell-environment"`. It is the only kernel-level scenario that supports PostgreSQL 17, which is what makes routing testable.

The same scenario is the vehicle of `kenshou cell probe --cell NAME --payload FILE`, which leases the cell, runs it as one slice, reads `fingerprint.cell` from the fetched run result, and writes `.dev/cells/<cell>.capabilities.json`:

```json
{
  "schema": "kenshou.cell-capabilities/v1",
  "cell": "alpha", "descriptorSha256": "c81d…", "probedBy": "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9", "probedAt": "2026-10-05T10:20:00Z",
  "capabilities": { "postgres.major": "18", "postgres.pg_partman": false, "postgres.second-server": false, "postgres.control-hook": false,
                    "broker": "redpanda v25.2.4", "otlp.null": true, "otlp.file": true, "fault-hook": false }
}
```

The cache is ignored when the descriptor's digest has changed, which is what happens after the cell is upgraded. Capabilities are facts about one cell at one image revision; they are never part of a machine profile, and the authoritative record for any given run remains its own `fingerprint.cell`.

`Kenshou.Remote.Cell.Session`, `.Submit` and `.Watch` drive a session. The primitives are shared by every command that runs work under one lease:

```haskell
data CellSession -- an open lease with its heartbeat, the payloads by label, the store, and the session file
withCellSession :: ObjectStore -> SessionOptions -> (CellSession -> IO a) -> IO a
runSlice :: CellSession -> Slice -> IO SliceResult -- submit, wait for the seal, fetch, verify, record
cellRunChild :: CellSession -> PayloadLabel -> RunSpec -> FilePath -> IO ExitCode
runSession :: ObjectStore -> SessionOptions -> IO SessionResult -- withCellSession, prepare, runSlice for each slice
```

`cellRunChild session label spec outDir` wraps one run specification in a single-entry run plan, prepares it for the cell, runs it as its own slice (and therefore behind its own reset), and then creates the symbolic link `<outDir>/<run-id>` pointing at the fetched `tree/output/<run-id>`, so that a caller that expects a local run directory finds one without the fetched tree being touched; its exit code follows the mapping below. `runSession` writes `<out>/<session-id>/session.json` (`kenshou.cell-session/v1`: cell, buckets, lease identifier and mode, payloads, the plan's digest, the rejected runs with reasons, and one entry per slice with its cell run identifier, ordinals, run identifiers, reset parameters, state `planned`, `submitted`, `sealed`, `rejected`, `fetched` or `verified`, the cell outcome, the entry exit code and the manifest digest) atomically after every transition, and for each slice in order: check the lease flag; upload `work`, then `submission.json` with `DoesNotExist`; poll `status.json` and `rejected.json` every two seconds, printing phase changes and new log chunks; on `sealed`, record the outcome and the manifest digest, fetch and verify (below), and continue. A lost lease stops the session; the remaining slices stay `planned`, so `kenshou cell resume` can take a new lease and continue, never reusing a cell run identifier. Outcomes map to the command-line contract as follows. A sealed `completed` slice yields its entry exit code (0, 1, 3 or 4; an entry exit of 2 means the adapter rejected its own input and counts as 4). `infrastructure-failure`, `cancelled` and `timed-out` yield 4. A rejection for `lease-mismatch` or `payload-digest-mismatch` yields 4; any other rejection is a client bug or misuse and yields 2. The session's exit code is that of the kernel's `worstOutcome` over all effective outcomes; a busy or quarantined cell is 4, never 1, because 1 means "failed".

`Kenshou.Remote.Cell.Fetch` retrieves and verifies.

```haskell
data FetchSelection = WholeTree | OnlyRuns (NonEmpty RunId)
data VerifyProblem
  = Unsealed | Missing FilePath | Extra FilePath | DigestMismatch FilePath | SizeMismatch FilePath
  | ManifestsDisagree FilePath | PayloadMismatch Text | StatusDigestMismatch | KenshouManifestProblem RunId ManifestProblem
fetchCellRun :: ObjectStore -> Bucket -> CellRunId -> FetchSelection -> FilePath -> IO (Either FetchError FilePath)
verifyCellRun :: FilePath -> IO (Either (NonEmpty VerifyProblem) CellRunIndex)
effectiveOutcome :: CellOutcome -> Bool {- run directory complete -} -> Outcome -> Outcome
```

The fetched layout is `<out>/<cell-run-id>/tree/`, a byte-for-byte mirror of `runs/<cell-run-id>/`, and beside it the derived `<out>/<cell-run-id>/cell-run.json`. Objects are downloaded to temporary names and renamed after their digest matches, so an interrupted fetch resumes. A prefix without `manifest.json` is refused as `Unsealed` unless `--allow-unsealed` is given for debugging. `OnlyRuns` fetches the manifest, `submission/`, `cell/`, the plan summary and the named `output/<run-id>/` subtrees, and verification then accepts missing objects outside the selection. Verification has three legs: every object against the cell manifest (missing, extra, size, digest); every `tree/output/<run-id>/` against kenshou's own `manifest.json` with the kernel's `verifyManifest`; and the cross-checks that both manifests agree on every file they share, that the cell manifest's payload digest equals the submission's and the `fingerprint.cell.payload.bundleSha256` of every run result, and that the manifest's digest equals the one in the session file when there is one. `effectiveOutcome` keeps the recorded outcome when the cell outcome is `completed`; turns every nested run into `infrastructure-failure` when the cell says so, because a tripped gate taints the whole window; and under `cancelled` or `timed-out` keeps complete runs as recorded and marks incomplete ones `errored`.

```json
{
  "schema": "kenshou.cell-run/v1",
  "cellRun": "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9", "cell": "alpha", "leaseId": "0199a3c1-…", "leaseSequence": 2,
  "resultsBaseUri": "gs://tan-nb-exp-cells-results/runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9",
  "dataBaseUri": "gs://tan-nb-exp-cells-results/runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9/output",
  "cellManifest": { "path": "manifest.json", "sha256": "e4f1…", "bytes": 5210 },
  "cellOutcome": "completed", "reasons": [], "entryExitCode": 0,
  "evidence": [ { "kind": "cell-fingerprint", "path": "cell/fingerprint.json", "sha256": "1c9a…", "bytes": 3904, "mediaType": "application/json" },
                { "kind": "cell-health", "path": "cell/health.json", "sha256": "8b20…", "bytes": 1188, "mediaType": "application/json" },
                { "kind": "cell-reset-evidence", "path": "cell/reset-evidence.json", "sha256": "77d2…", "bytes": 9120, "mediaType": "application/json" },
                { "kind": "cell-metrics-export", "path": "metrics/export.jsonl.zst", "sha256": "0aa4…", "bytes": 734003, "mediaType": "application/zstd" } ],
  "runs": [ { "runId": "0199a3f2-7c20-7f00-8a11-0c0d0e0f1011", "path": "output/0199a3f2-7c20-7f00-8a11-0c0d0e0f1011",
              "scenario": "selftest/kernel/correctness/postgres-roundtrip", "manifestSha256": "41c9…",
              "recordedOutcome": "passed", "effectiveOutcome": "passed", "overrideReason": null } ],
  "verifiedAt": "2026-10-05T10:31:40Z"
}
```

This document is how `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` addresses an individual run: `kenshou record <out>/<cell-run-id>/tree/output/<run-id> --data-base-uri <dataBaseUri>` finds every object already durable, takes the `cell-manifest` link and the `cell` and `cellRun` environment fields from here, and records the effective outcome. `kenshou cell runs <cell-run-dir>` prints the nested runs; there is no lookup by run identifier alone, because the results bucket cannot be indexed by clients, so the session file and `cell-run.json` are the index.

The fake cell lives in `kenshou-remote/test/Kenshou/Remote/FakeCell.hs`: a thread that watches a file store for submissions, enforces the lease identifier, starts a durable `ephemeral-pg` server as "the cell's PostgreSQL", writes an environment file, runs the locally built `kenshou cell exec <work> <out>` (found through `build-tool-depends: kenshou-cli:kenshou`), and publishes the tree, a manifest and the status transitions; options make it reject, trip a health gate, or die before sealing. `Kenshou.Remote.EndToEndSpec` drives `runSession` through all of them.

`Kenshou.Remote.Cli.cellCommand :: CliCommand` adds the verb family in the Execution group. Every nested parser follows EP-2's intent grouping: Cell for cell name and descriptor, Lease for lease identity/purpose/TTL/wait, Payload for payload and plan documents, Environment for cache/PostgreSQL/routing/OTLP/RTS controls, Execution for dry-run/detach/resume, and Output for local destinations and JSON. Document inputs `--payload FILE`, `--plan FILE` and `--routing-rules FILE` use `InputSource`; exactly one may be `-` in an invocation. Binary Nix payloads are never read implicitly from a pipe: `-` is accepted only for JSON documents, so `--payload -` is a usage error with a remediation to name a file. `kenshou cell status --cell NAME [--json]` prints the descriptor summary, lease, quarantine and agent state. `kenshou cell lease --cell NAME --purpose TEXT [--ttl N] [--wait SECONDS] [--start] [--hold] [--json]` acquires (exit 0), or reports busy or quarantined (exit 4); `--wait` polls; `--start` starts stopped instances with `gcloud compute instances start <names> --project <p> --zone <z>` taken from the descriptor after the project allowlist check; `--hold` stays in the foreground renewing. `kenshou cell release --cell NAME --lease-id ID`. `kenshou cell probe --cell NAME --payload FILE` refreshes the capabilities cache. `kenshou cell route --plan FILE --cell A --cell B --out DIR` writes `plan.<cell>.json` per cell, `plan.local.json` for runs that must stay on a laptop, and `unroutable.json`. `kenshou cell submit --cell NAME --lease-id ID --payload [LABEL=]FILE... --plan FILE [--granularity auto|plan|run] [--cache-policy cold|warm] [--pg-setting K=V]... [--skip-incompatible] [--coerce-durable] [--ephemeral-on-driver] [--routing-rules FILE] [--otlp-sink null|file] [--rts OPTS] [--out DIR] [--dry-run]` runs a session under an existing lease; `--dry-run` prints the session document in its planned state and touches nothing. `kenshou cell watch --cell NAME CELL_RUN_ID`, `kenshou cell fetch [--results-bucket B] CELL_RUN_ID [--run RUN_ID]... --out DIR`, `kenshou cell verify DIR_OR_GS_URI` (exit 0, 1 on any mismatch, 2 usage, 4 unreadable) and `kenshou cell runs DIR`. `kenshou cell run` is lease, submit, fetch, verify and release in one process with the heartbeat, and takes `--detach`; `kenshou cell resume --session DIR` continues or re-attaches. The escape hatch is `kenshou cell debug --cell NAME (ssh ROLE [-- CMD...] | journal | tunnel ROLE REMOTE_PORT LOCAL_PORT)` and `kenshou cell fetch --iap`, which pulls an unpublished work directory from the driver as a tar stream; both run `<lti>/scripts/iap-ssh.sh` with `ZONE` from the descriptor and print the command they run. The control bucket comes from `--control-bucket` or `KENSHOU_CELL_CONTROL_BUCKET` (default `tan-nb-exp-cells-control`); the results bucket from the descriptor. JSON paths reserve standard output for the document and send lease progress, upload progress, watch events and diagnostics to standard error.

For clarity, the generic `InputSource` rule above applies to `--plan` and `--routing-rules`; `--payload` remains a normal file path because it names a binary Nix export and never accepts `-`.

Add `kenshou-cli/help/cells.md` as a `HelpTopic` through EP-2's registry. It explains payload identity, leases, routing, reset granularity, submit/watch/fetch/verify, safe resume, result immutability and the debug escape hatch. Keep `docs/guides/running-on-gcp.md` as the full guide; the embedded topic is the concise operational reference available from the shipped binary.

### Milestone 3 — paired comparisons inside one lease

Scope: a candidate payload and a baseline payload (two cohorts, or two revisions of this repository) measured as interleaved trials on one leased, repeatedly reset cell and judged by the measurement toolkit. At the end `kenshou cell pair` prints a `kenshou.comparison/v1` verdict and exits with the contract code.

`Kenshou.Remote.Pair` depends on `kenshou-measure` for the schedule only.

```haskell
data PairRequest = PairRequest
  {candidate :: PayloadLabel, baseline :: PayloadLabel, pairs :: Int, ordering :: PairedOrdering, seed :: Word64, maxReplacements :: Int}
pairPlan :: PairRequest -> RunPlan -> Either Text RunPlan
data PairState = PairValid | PairInvalid Text
judgePairs :: [SliceResult] -> [(Int, PairState)]
```

`pairPlan` keeps the benchmark entries of the input plan (anything else is a usage error: comparisons are for measurements), collapses the planner's own trial repeats to one configuration per scenario, and for each configuration emits the slots of `pairedSchedule ordering pairs seed`: two entries per pair, one per arm, in the scheduled order, each with a fresh run identifier, `trial {group, arm, index, of}` with the arm `candidate` or `baseline`, the run specification's `comparison` membership filled with the same group, arm, pair index and position, and the pair's shared `pairSeed` as the seed so that both arms replay the same workload. `pairs` defaults to the policy's `minimumPairs` and values below 3 are a usage error. If every benchmark entry of the input plan already names the two payload labels as its arms, the plan is used as it is.

`kenshou cell pair --cell NAME --candidate FILE --baseline FILE --plan FILE [--pairs N] [--ordering abba|baab] [--policy FILE] [--pg-setting K=V]... --out DIR` is `kenshou cell run` with granularity forced to `run`, so every trial gets the cell's full reset (fresh databases, identical settings, restart, `CHECKPOINT`, cold cache) and both arms see identical reset parameters, by default including `checkpoint_timeout=30min` and `max_wal_size=16GB` so that no timed checkpoint falls inside a ten-minute window. After each pair `judgePairs` marks the pair invalid if either slice's effective outcome is `infrastructure-failure` or `errored`; an invalid pair is dropped whole and one replacement pair is appended while the lease's budget allows, up to `maxReplacements` (default: the number of pairs). When the schedule is exhausted the command runs, as a child of the same executable, `kenshou compare --baseline <dir>... --candidate <dir>... --policy <file> --vary cohort --out <out>/comparison.json` over the run directories of the valid pairs in pair order, and returns its exit code. Fewer valid pairs than the policy's minimum makes the toolkit answer `inconclusive` or `infrastructure-failure`, never `regression`. When the two payloads share a cohort (two revisions of this repository), `--vary cohort` finds nothing varying; pass the pairs positionally without it and record in the comparison's labels that the harness revision is the varied factor; if the toolkit refuses, that is a request to it for a `payload` axis, recorded in Surprises & Discoveries.

A telemetry overhead measurement uses the same primitive from the other side. `kenshou overhead` does not emit a run plan, so there is nothing to hand to `kenshou cell submit`; instead `kenshou cell overhead <scenario-id> --cell NAME --payload FILE --arms <factor>=<v1>,<v2>,... [--mode one-factor|full] [--control] [--trials N] [--policy FILE] [--otlp-sink null|file] --out DIR` calls the telemetry plan's `planOverhead` locally, opens one cell session, and runs `executeOverhead` with `OverheadHooks.runChild = cellRunChild session "default"`, so that every slot (one arm in one block) is one submission behind one reset under the one lease, in exactly the interleaved order that plan computed, with its retries and replacement blocks intact; `analyseOverhead` then runs locally over the linked run directories and writes the `kenshou.overhead-report/v1`. The `compare` hook stays the measurement toolkit's. Arms whose tracing value is `sdk-otlp` get the cell's collector through `resolveOnCell`. `kenshou cell pair` is built the same way: `withCellSession`, one `runSlice` per scheduled trial, then `kenshou compare`. Both therefore answer the question "how do a paired ABBA comparison and an overhead plan run inside one lease": as a sequence of single-run submissions that share a lease identifier, which the cell records in every manifest as `leaseId` with an increasing `leaseSequence`. This milestone adds `kenshou-telemetry` to the package's dependencies.

### Milestone 4 — proof that one correctness scenario passes identically locally and on a cell

Scope: evidence that placement does not change a verdict, and the operator's guide. `Kenshou.Remote.Parity.compareForParity :: ParityOptions -> FilePath -> FilePath -> IO ParityReport` reads two run directories and classifies every difference. These must be equal: scenario, scenario revision, resolved knobs, dimensions, seed, phases, outcome, `blocking`, failure labels, known-defect status, the cohort's components (package, version, source kind and commit), every `verdicts/*.json` document's status and counts, and `summaries.verdicts` except paths the caller names with `--volatile PATH`. These are intentional differences, listed by name in the report and in the guide: run identifiers and all timings; `environment.placement` and `machineProfile`; the host and runtime fingerprint and the executable digest; `fingerprint.cell`; the PostgreSQL mode (ephemeral locally, external on the cell), the role's superuser flag, and settings such as `shared_buffers`; `cohort.os`, `arch`, `resolver` and `planHash` when the local side is a cabal build; the compatibility keys, which include the machine profile; the invocation; the absence of `logs/postgres.log` on the cell, whose server log stays with the cell; and the warning observation that scenario-required settings are applied by reset rather than by the kernel. Anything else is an unexpected difference and makes `kenshou cell parity --local DIR --cell DIR [--out FILE]` exit 1; identical verdicts exit 0. The report is `kenshou.parity-report/v1` with `equal`, `intentional` and `unexpected` lists and the digests of both `run-result.json` files.

The proof uses three scenarios with seed 7, each run locally with the Nix-built binary for the workstation (`nix build .#kenshou-released`, so both sides come from one flake evaluation and share a plan hash) and on `cell-alpha` from a three-entry plan: `selftest/kernel/correctness/postgres-roundtrip` with `pg.durability=durable` (one ledger, three components, real writes), `selftest/kernel/concurrency/worker-echo` (child processes under the cell's systemd unit and memory limit) and `selftest/remote/correctness/cell-environment` with `pg.durability=durable`. A fourth, the first available correctness scenario of the kiroku layer with placement `either`, is added when `docs/plans/9-cover-kiroku-in-isolation.md` has landed. A second local run with the cabal-built binary is compared too, to show which differences belong to the build rather than the place.

Write `docs/guides/running-on-gcp.md`: prerequisites (gcloud identity with object access to both buckets, the remote builder, the cell repository's guide for creating and starting cells); publishing a payload; the one-command run and the separate verbs; probing a cell's capabilities; routing by PostgreSQL major, by server control and by capability, and what ends up in `plan.local.json`; what a cell cannot give a scenario (a second PostgreSQL server, a restartable postmaster, privileged fault injection) and how each shows in the context document; per-run PostgreSQL settings and the allowlist; cache policy; diagnostic variants with `--rts`; paired comparisons and overhead measurements and how to read their verdicts; soaks (the `<name>-reduced` forms are tier `extended` and run anywhere, the multi-hour forms are tier `soak`, placed `cell`, run with `--detach`, and take their gate result as a `gs://` URI of an earlier cell run); fetching an old run by identifier long after the cell is gone; recording a fetched run with the evidence commands; costs (a running default cell is roughly one US dollar per hour and a stopped one costs only its disks, both approximate until measured; storage is negligible; record actual figures from the billing export here); and failure handling: lease expiry in the middle of a run (the agent kills the work and seals what exists as `infrastructure-failure` with reason `lease-expired`; resume the session under a new lease, and completed slices are not repeated), partial uploads (an unsealed prefix is refused; the agent seals it as `agent-restarted` when it comes back; `--allow-unsealed` and `fetch --iap` are for diagnosis only and their output is never evidence), a quarantined cell (leasing answers 4 with the reason; clearing is a human decision made with the cell repository's tools after a probe run), a busy cell (`--wait`), a rejected submission (the reason and which flag fixes it), and a stale cohort lock.

Finish by adding the `kenshou-remote` package to `mori.dhall`, `cabal test kenshou-remote:tests` and `just payload-check released` to the `verify` recipe (the latter only evaluates, it does not build), and the two ADRs.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` inside the dev shell (`nix develop`, or `direnv allow` once). Commit after each milestone, directly on the current branch, with a Conventional Commits subject and these trailers:

```text
feat(remote): publish the kenshou payload as a content-addressed NAR bundle

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Any change made in `/Users/shinzui/Keikaku/bokuno/load-testing-infra` (the PostgreSQL role fix) is committed there with the `mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime` and `mori://shinzui/keiro-runtime-kenshou/plans/16-provide-leased-verification-cells-in-load-testing-infra` trailers that plan prescribes.

Check the starting state first. Everything here is read-only.

```bash
cabal build all && just cohort-check
K=$(cabal list-bin kenshou)
$K list | head -3
$K plan --suite smoke --placement cell --out /tmp/smoke.cell.plan.json && jq -r '.schema, (.runs | length)' /tmp/smoke.cell.plan.json
$K run --help | grep -E 'cohort-identity|cell-fingerprint|pg-url-env|placement|run-id'
$K execute --help | grep -E 'plan|out|resume'
grep -n 'nix.haskell-nix\|nix.builtin-package' .seihou/config.dhall
mori path shinzui/load-testing-infra
nix config show | grep -E '^(builders|extra-platforms)'
```

If a flag is missing, stop and finish the owning plan. For Milestone 2's real-cell steps also confirm, in the cell repository's dev shell, that `cellctl lease status --cell alpha` answers and that the hello fixture of the cell plan seals.

Milestone 1.

```bash
seihou run nix-haskell-flake            # after editing .seihou/config.dhall
git add flake.nix flake.lock flake.module.nix nix scripts/payload-lock.sh
just payload-lock released && just payload-lock head
nix build .#kenshou-released --print-out-paths
./result/bin/kenshou cohort show --json | jq -r '.resolver, .planHash, (.components | length)'
nix path-info -rsSh ./result | tail -1
nix path-info -r ./result | grep -c -- '-ghc-9' || true
just payload-check released && just payload-check head
```

```text
/nix/store/<hash>-kenshou-released
nix
sha256:7e41…
16
/nix/store/<hash>-kenshou-released   312.4M
0
cohort released: nix identity consistent with cohort/released.json (44 packages)
cohort head: nix identity consistent with cohort/head.json (44 packages)
```

The numbers are illustrative; the `0` (no compiler in the closure) is the target. Then build for the cells and publish. The first Linux build compiles the whole cohort on a two-core builder and can take hours; later builds recompile only changed kenshou packages.

```bash
nix build .#packages.x86_64-linux.kenshou-released --no-link --print-out-paths
mkdir -p payloads
$K cell payload publish --cohort released --out payloads/released.json
$K cell payload publish --cohort released --out payloads/released.json     # second time
```

```text
built /nix/store/<hash>-kenshou-released (x86_64-linux)
exported 96.4 MiB bundle sha256 9f2c…e1
uploaded gs://tan-nb-exp-cells-control/payloads/sha256/9f2c…e1.nar.zst
wrote payloads/released.json
...
already published gs://tan-nb-exp-cells-control/payloads/sha256/9f2c…e1.nar.zst (96.4 MiB)
```

If the copy back from the builder fails, repeat with `--via-builder nix-builder-x86`. Add `payloads/` and `cell-runs/` to `.gitignore`.

Milestone 2, first without any cloud:

```bash
cabal test kenshou-remote:tests
export KENSHOU_CELL_STORE=file:/tmp/kenshou-fake-cell
$K cell submit --cell alpha --lease-id 00000000-0000-7000-8000-000000000000 --payload payloads/released.json --plan /tmp/smoke.cell.plan.json --dry-run | jq '.slices | length, .rejected'
unset KENSHOU_CELL_STORE
```

Then on a real cell (identifiers and timings illustrative):

```bash
$K cell status --cell alpha
$K cell run --cell alpha --start --purpose ep17-smoke --payload payloads/released.json \
   --plan /tmp/smoke.cell.plan.json --out cell-runs; echo "exit=$?"
```

```text
cell alpha  project tan-nb-exp  zone us-west1-a  postgres 18  lease: none  quarantine: none
lease 0199a3c1-0d52-7f10-8a77-6e0c4b2d9f01 acquired (ttl 120s, heartbeat 40s)
session 0199a3c1-2f00-7a10-9c11-5d6e7f8091a2: 1 slice, 9 runs, 0 rejected
[slice 0] 0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9 accepted
[slice 0] resetting → fetching (bundle 9f2c…e1 verified) → running
stdout | passed  selftest/kernel/correctness/postgres-roundtrip  /var/lib/cell-agent/work/0199a3c2-…/out/0199a3f2-…
...
[slice 0] sealed outcome=completed entryExitCode=0 manifest e4f1…
fetched 143 objects to cell-runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9/tree
verified: cell manifest ok (143), kenshou manifests ok (9), cross-check ok
lease released
exit=0
```

```bash
$K cell probe --cell alpha --payload payloads/released.json && jq .capabilities .dev/cells/alpha.capabilities.json
jq -c '{revision: .fingerprint.kenshou.revision, dirty: .fingerprint.kenshou.dirty, resolver: .cohort.resolver, cell: .fingerprint.cell.cell,
        partman: .fingerprint.cell.postgres.extensions.pg_partman.available, broker: .fingerprint.cell.broker.implementation}' \
   cell-runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9/tree/output/*/run-result.json | sort -u
$K cell runs cell-runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9
$K cell verify gs://tan-nb-exp-cells-results/runs/0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9
$K plan --select 'selftest/remote/**' --dim pg.version=17 --placement cell --out /tmp/pg17.plan.json
$K cell submit --cell alpha --lease-id "$L" --payload payloads/released.json --plan /tmp/pg17.plan.json; echo "exit=$?"
$K cell route --plan /tmp/pg17.plan.json --cell alpha --cell beta --out /tmp/routed && ls /tmp/routed
```

```text
{"postgres.major":"18","postgres.pg_partman":false,"postgres.second-server":false,"postgres.control-hook":false,"broker":"redpanda v25.2.4","otlp.null":true,"otlp.file":true,"fault-hook":false}
{"revision":"869c38d0e1…","dirty":false,"resolver":"nix","cell":"alpha","partman":false,"broker":"redpanda"}
...
kenshou: 1 run cannot execute on cell alpha: ordinal 1 selftest/remote/correctness/cell-environment wants pg.version=17, the cell has 18 (use kenshou cell route, or --skip-incompatible)
exit=2
plan.beta.json  unroutable.json
```

A revision that prints as `null` means the binary was not the wrapped payload; stop and fix the payload, because the evidence plan will refuse such a run.

Confirm the planner's flag spellings with `kenshou plan --help`. Interoperability: hold a lease with `cellctl lease acquire --cell alpha ...` and see `kenshou cell lease` answer busy with exit 4, then the reverse.

Milestone 3.

```bash
$K cell payload publish --cohort head --out payloads/head.json
$K plan --select 'selftest/measure/benchmark/pg-insert' --placement cell --out /tmp/bench.plan.json
$K cell pair --cell alpha --start --candidate payloads/released.json --baseline payloads/released.json \
   --plan /tmp/bench.plan.json --pairs 5 --policy policies/default.json --out cell-runs/aa; echo "exit=$?"
$K cell pair --cell alpha --candidate payloads/head.json --baseline payloads/released.json \
   --plan /tmp/bench.plan.json --pairs 5 --policy policies/default.json --out cell-runs/head-vs-released; echo "exit=$?"
```

```text
10 slices planned (ABBA, 5 pairs), reset per run: cachePolicy=cold checkpoint_timeout=30min max_wal_size=16GB
...
comparison 0199a4d0-…: verdict pass (5 valid pairs, 0 replaced)  cell-runs/aa/comparison.json
exit=0
```

Use whichever benchmark scenario exists when you get here. The overhead measurement on the same cell:

```bash
$K cell overhead selftest/telemetry/benchmark/arms-on-synthetic-service --cell alpha --payload payloads/released.json \
   --arms tracing=off,noop,sdk-otlp --trials 3 --otlp-sink null --out cell-runs/overhead; echo "exit=$?"
jq -r '.schema, (.comparisons | length)' cell-runs/overhead/overhead-report.json
```

Expect nine single-run submissions under one lease identifier and a `kenshou.overhead-report/v1` with two comparisons (confirm the report's file name and member names in the telemetry plan). For the health case, start a pair run and, from the cell repository, issue `gcloud compute instances simulate-maintenance-event cell-alpha-postgres --project tan-nb-exp --zone us-west1-a` during a trial; expect that pair to be reported invalid and replaced, and with `--max-replacements 0` expect exit 3 or 4 and never 1.

Milestone 4.

```bash
nix build .#kenshou-released -o result-local
for s in selftest/kernel/correctness/postgres-roundtrip selftest/remote/correctness/cell-environment; do
  ./result-local/bin/kenshou run $s --dim pg.durability=durable --seed 7 --out runs/parity; done
./result-local/bin/kenshou run selftest/kernel/concurrency/worker-echo --seed 7 --out runs/parity
# the same three as a plan with --seed 7, run on cell-alpha with kenshou cell run --out cell-runs/parity
$K cell parity --local runs/parity/<run-id> --cell cell-runs/parity/<cell-run-id>/tree/output/<run-id>; echo "exit=$?"
```

```text
parity selftest/kernel/correctness/postgres-roundtrip seed 7: identical
  equal: outcome=passed failures=[] verdicts.postgres-roundtrip cohort.components(16) knobs dimensions seed
  intentional (11): runId timings environment.placement environment.machineProfile fingerprint.host fingerprint.cell postgres.mode postgres.superuser postgres.settings compatibility.comparisonKey logs/postgres.log
  unexpected: none
exit=0
```


## Validation and Acceptance

Milestone 1 is accepted when `nix build .#kenshou-released` and `.#kenshou-head` succeed for the local system and for `x86_64-linux`; the Nix-built binary lists the same scenarios as the cabal-built one (`diff <(result/bin/kenshou list) <($K list)` is empty) and reports `rtsStats: true` in a run result's fingerprint; `kenshou cohort show --json` from it validates against the identity schema with `resolver` `nix`; `just payload-check` passes for both cohorts, and fails naming the package when one version in a lock file is edited by hand and when the descriptor is edited without regenerating the lock; the closure holds no compiler, or the reason and size are recorded; two publishes of one closure upload once; a bundle whose object is later altered is refused by the cell with `payload-digest-mismatch`; the `info-table` variant builds; and `cabal test kenshou-remote:tests` covers the file store's preconditions and generations, the token provider order, and a descriptor round-trip.

Milestone 2 is accepted on a laptop when the tests show: twenty rounds of two simultaneous `acquireLease` calls over the file store give exactly one `Acquired` each; an expired lease is taken over by exactly one contender and judged by the store's clock, not the test's; a lost renewal flips the heartbeat flag; `prepareForCell` rejects each reason in `RejectReason` from a doctored plan, moves settings into the reset block, never emits an `fsync-off` run against the cell's server, gives a scenario with two extra servers two `connectionStringEnv` entries with distinct variable names, rejects a server-control scenario with `NeedsServerControl` and admits it as ephemeral only under `--ephemeral-on-driver` and never for a benchmark, and rejects a run with `pgmq.queue-kind=partitioned` as `MissingCapability "postgres.pg_partman"` when the cached capabilities deny it while accepting it with a warning when nothing is cached; `routePlan` sends server-control runs to the local plan; slices partition the accepted runs in plan order with every benchmark alone (a property over generated plans); `cellExec` against the fake cell sets `KENSHOU_CELL_FAULT_HOOK` exactly when the environment file names an executable hook and then calls `heal-all`, leaves the skew bound unset for one driver and computes it from a canned `chronyc` output for two, turns a canned health observation into a `hard` notice line that validates against the health-notice schema, materialises a `gs://` knob from the file store and records its digest, and exits 4 with `payload-identity-missing` when the wrapper's variables are absent; and the end-to-end test against the fake cell passes for a completed slice, a rejected submission, a tripped health gate (all nested runs effectively `infrastructure-failure`, exit 4), an agent that dies before sealing (`Unsealed`), a lease lost between slices followed by `resume`, and a fetched tree with one flipped byte (exit 1 naming the file, in each of the three verification legs).

The laptop acceptance also covers the configuration boundary: Settei resolves cell-client built-ins < ordered YAML files < explicit environment bindings < named flags, writes effective non-secret store/project/bucket values to `cell-session.json`, never reveals a sentinel GCS token in an explanation or failure, and cannot supply a run plan, payload descriptor, routing policy, or injected payload variable.

It is accepted on a real cell when the transcript above reproduces with no SSH and no image build; every fetched `run-result.json` has `fingerprint.placement` `cell`, a 40-character `fingerprint.kenshou.revision` equal to the commit the payload was built from with `dirty` false, a `fingerprint.cell` object whose payload digest equals `payloads/released.json`'s and which states whether `pg_partman` is available and, on a cell with the broker role, the broker's implementation and version, PostgreSQL mode `external`, `fsync` `on`, and a cohort equal to the payload's identity with `resolver` `nix`; `kenshou cell probe` writes a capabilities file that agrees with those fingerprints; a simulated maintenance event on the driver during a measured run makes that run's own result `infrastructure-failure` with a `host-notice` observation, before and independently of the cell's verdict; `kenshou cell verify gs://...` passes from a machine with no Pulumi state and no session file; the PostgreSQL 17 run is refused on `cell-alpha` with exit 2 and passes on `cell-beta` after `route`; a run with `--pg-setting checkpoint_timeout=30min` shows that value in its fingerprint's PostgreSQL settings and in the cell's reset evidence, and `--pg-setting bogus=1` is rejected by the cell with `unsupported-postgres-setting` and reported with exit 2; killing the client during a held-lease run ends the run within one TTL plus grace, seals it as `infrastructure-failure`, and `kenshou cell resume` finishes the remaining slices under a new lease; a `--detach` session survives the client exiting and is collected later with `resume`; `kenshou cell lease` and `cellctl` exclude each other; and with the collector role present, the `cell-environment` scenario with `remote.otlp-endpoint` set by `resolveOnCell` reports `otlp-reachable`.

Milestone 3 is accepted when the A/A control prints `pass` with exit 0; the released-against-head comparison prints a verdict document whose runs alternate arms in start-time order (the toolkit's interleaving check passes) and whose two arms show equal machine profiles and equal PostgreSQL settings; every trial's cell tree carries its own reset evidence with a `CHECKPOINT` step; the simulated maintenance event produces an invalid, replaced pair, and with replacements disabled an exit code of 3 or 4; no code path exists in `Kenshou.Remote.Pair` that produces exit 1 without the toolkit's `regression` verdict (a unit test over `judgePairs`); `kenshou cell overhead` on the synthetic service produces an overhead report from single-run submissions that all carry one `leaseId` with consecutive `leaseSequence` values, its `sdk-otlp` arm shows the cell collector's `otelcol_receiver_accepted_spans` rising in that slice's metrics export, and a unit test shows that `cellRunChild` leaves the fetched tree byte-identical and that `executeOverhead`'s resume logic accepts the linked directories; and, once the assembled-runtime plan has landed, `runtime/order-flow/soak/steady-reduced` passes on a cell with `extraPostgres` reported as `shared-server`.

Milestone 4 is accepted when `kenshou cell parity` reports `identical` with no unexpected difference for the three scenarios, the intentional differences printed are exactly the documented list, doctoring the cell copy's seed or outcome in a scratch copy makes the command exit 1, a second person can follow `docs/guides/running-on-gcp.md` from a clean checkout to a verified cell run, and `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce` passes with the two new records.

The plan as a whole is accepted when `just verify` is green, a run plan made by `kenshou plan --suite nightly` can be routed, run, fetched and verified with the commands in the guide, and a run fetched that way can be handed to `kenshou record` with the `dataBaseUri` from `cell-run.json` without uploading anything.


## Idempotence and Recovery

Every step can be repeated. `seihou run` reports a conflict instead of overwriting a hand-edited managed file; move the edit into `flake.module.nix` and re-run. `scripts/payload-lock.sh` is deterministic. Nix builds are cached; if Nix seems to ignore a new file, it is untracked: `git add` it. Payload bundles are named by digest and uploaded with the does-not-exist precondition, so repeated publishes are no-ops and a half-finished resumable upload leaves no object behind. Old bundles in the control bucket are deleted by the cell repository's janitor; sealed manifests still name their digests, and a payload can always be rebuilt from its commit and lock.

A session never reuses a cell run identifier, and `session.json` is rewritten atomically after each transition, so `kenshou cell resume --session DIR` is always safe: sealed slices are fetched and verified if they were not yet, planned slices are submitted under a new lease, and a slice that was `submitted` when the client died is looked up by its status object and either collected or, if rejected or never accepted, resubmitted under a fresh identifier. A client that dies leaves a lease that expires by itself; a detached lease is released early with `kenshou cell release --lease-id`, or forcibly by an operator with the cell repository's `cellctl lease cancel --force`. Fetching writes to temporary names and renames after verification, so an interrupted fetch resumes and a fetched tree is never modified afterwards; delete a whole `<cell-run-id>` directory to fetch again. Nothing in this plan can delete or overwrite an object in the results bucket: the client has read access only.

If a slice is rejected for `run-id-already-used`, the identifier was consumed by an earlier attempt; `resume` allocates a new one. If the cohort gate fails after a cohort change, run `just payload-lock <cohort>` and rebuild. If the cell reports `postgres-major-unavailable` or the adapter reports `cell-postgres-role-cannot-create-databases`, the cell is the wrong one or predates the role fix; nothing ran and nothing needs cleaning. Costs are bounded by the cell's idle policy (it powers itself off thirty minutes after the last lease by default) and, for a detached lease, by its TTL; when in doubt run the cell repository's `scripts/cell/stop.sh <name>`, which is always safe without a lease. The remote builder powers itself off when idle. If a fault hook was in use when a run died, the next `kenshou cell exec` calls `heal-all` before it starts, and the cell's reset is the backstop. A stale capabilities cache is harmless: it is keyed by the descriptor's digest, a wrongly admitted run ends `errored` with the layer's own remediation message, and `kenshou cell probe` refreshes it. Local residue is confined to `payloads/`, `cell-runs/`, `runs/`, `.dev/` and `result*` links, all ignored by git and safe to delete.


## Interfaces and Dependencies

Libraries use the cohort's resolved plan plus EP-2's verified harness dependencies (take versions from `cohort/released.project` and `dist-newstyle/cache/plan.json`; do not loosen constraints): `kenshou-core` (kernel, `Kenshou.Plan.*`, and `Kenshou.Core.Cli.Config`), `aeson >=2.2 && <2.3`, `bytestring`, `containers`, `text`, `time`, `directory`, `filepath`, `unix`, `async`, `stm`, `typed-process >=0.2.12 && <0.3`, `cryptohash-sha256` and `base16-bytestring`, `uuid` and `mmzk-typeid` through the kernel's generator, `optparse-applicative >=0.19 && <0.20`, the Settei 0.2.0.0 family, `http-client`, `http-client-tls` and `http-types` (present through `hs-opentelemetry-exporter-otlp`; confirm with `jq '."install-plan"[]."pkg-name"' dist-newstyle/cache/plan.json | grep http-client`), `hasql` for the adapter's preflight, and from Milestone 3 `kenshou-measure` and `kenshou-telemetry`. Tests use `hspec`, `hspec-hedgehog`, `temporary` and `ephemeral-pg`. External tools from the dev shell: `nix` with flakes, `nix-store`, `nix-prefetch-url`, `zstd`, `jq`, `gcloud` (tokens and `--start` only), `check-jsonschema`; from the cell repository, by path, `scripts/iap-ssh.sh` and `scripts/cell/payload-publish.sh`. Nix inputs: `haskell-nix-dev` and `haskell-nix` as pinned by Seihou module `nix-haskell-flake` 0.24.0. Services: the two cell buckets and the cells of `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md`, the builder `nix-builder-x86`, and on the driver the GCE metadata server.

At the end of Milestone 1 these exist: `nix/kenshou/{default,packages,cohort-overlay,identity}.nix`, `nix/cohort-locks/{released,head}.lock.json`, `scripts/payload-lock.sh`, the recipes `payload-lock` and `payload-check`, the flake outputs `kenshou-released`, `kenshou-head` and their `-info-table` and `-profiled` variants with `passthru.cohortIdentity`, the optional `resolver` member of `kenshou.cohort-identity/v1`, the package `kenshou-remote` with `Kenshou.Remote.Store` (`ObjectStore`, `Precondition`, `ObjectMeta`, `PutOutcome` as shown), `Kenshou.Remote.Store.Gcs` (`newGcsStore`, `TokenProvider`), `Kenshou.Remote.Store.File` (`newFileStore`), `Kenshou.Remote.Payload.Nix`, `Kenshou.Remote.Payload` (`PayloadDescriptor`, `publishPayload`), the schemas for `kenshou.payload/v1`, `kenshou.payload-identity/v1` and `kenshou.cohort-nix-lock/v1`, and the verb `kenshou cell payload`. At the end of Milestone 2: `Kenshou.Remote.Config` (`cellClientConfig` and explicit Settei environment bindings), `Kenshou.Remote.Cell.Docs`, `.Lease`, `.Prepare`, `.Exec`, `.Session` (`CellSession`, `withCellSession`, `runSlice`, `cellRunChild`, `runSession`), `.Submit`, `.Watch`, `.Fetch`, `.Debug` with the signatures given in Plan of Work, `Kenshou.Remote.Selftest.bundle`, Execution `Kenshou.Remote.Cli.cellCommand` using EP-2's `InputSource`, Settei configuration, and option-group contracts, `kenshou-cli/help/cells.md`, `policies/cell-routing.json`, the schemas for `kenshou.cell-context/v1`, `kenshou.cell-capabilities/v1`, `kenshou.cell-session/v1` and `kenshou.cell-run/v1`, the payload command `["bin/kenshou", "cell", "exec"]`, the variables this plan defines (`KENSHOU_CELL_PG_URL`, `KENSHOU_CELL_PG_URL_<NAME>`, `KENSHOU_CELL_STORE`, `KENSHOU_CELL_CONTROL_BUCKET`, `KENSHOU_GCP_ALLOWED_PROJECTS`, `KENSHOU_GCS_TOKEN`, `KENSHOU_LTI_DIR`, the `KENSHOU_PAYLOAD_*` family) and the ones it supplies on a cell for other plans (`KENSHOU_COHORT_IDENTITY`, `KENSHOU_HARNESS_REVISION`, `KENSHOU_HARNESS_DIRTY`, `KENSHOU_PG17_BIN`, `KENSHOU_PG18_BIN` from the wrapper; `KENSHOU_CELL_FINGERPRINT`, `KENSHOU_HEALTH_NOTICES`, and conditionally `KENSHOU_CELL_FAULT_HOOK` and `KENSHOU_CLOCK_SKEW_BOUND_MICROS`, from `kenshou cell exec`). At the end of Milestone 3: `Kenshou.Remote.Pair` (`PairRequest`, `pairPlan`, `judgePairs`), `kenshou cell pair` and `kenshou cell overhead`. At the end of Milestone 4: `Kenshou.Remote.Parity` (`compareForParity`, `ParityReport`), the schema for `kenshou.parity-report/v1`, `kenshou cell parity`, `docs/guides/running-on-gcp.md` and two ADRs.

Requests to the cell plan. The cell protocol is generic, so the mapping to kenshou's inputs is this plan's, but seven things can only be provided by the cell. Raise each against `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` (its Decision Log, then Integration Point 9 of the MasterPlan), implement them in `mori://shinzui/load-testing-infra` under that plan's trailers, and keep the client forward-compatible as described. First, and blocking real-cell acceptance: the PostgreSQL role must have `CREATEDB` and `pg_hba.conf` must trust it on all databases from the cell's subnet. Second: build `pg_partman` into the cell PostgreSQL images (`services.postgresql.extensions`), so that the pgmq plan's partitioned-queue scenarios can run on a cell; until then they are routed away and the fact is in every fingerprint. Third: a privileged fault hook, an executable named by an optional `faultHook` member of `cell.environment/v1` that talks to the root agent, implements `inject <fault> <json>`, `heal <token>` and `heal-all` for `net-reject`, `net-drop`, `net-delay`, `disk-fill` and `memory-limit`, is enabled only by the cell policy's `allowFaultInjection`, and suppresses the matching health gate for the declared window. Fourth: the rolling health observations of every cell machine, made readable to the payload during the run as a JSON-lines file named by a new variable `CELL_HEALTH_FILE` (or a documented, lease-authorised `GET /v1/health`), so that the mapper does not depend on an internal endpoint. Fifth: chrony tracking figures for every machine in `cell/fingerprint.json`, and a measured `clock.skewBoundMicros` in the environment file when a cell has several drivers. Sixth, optional: a second PostgreSQL role (`postgres-b`) and a lease-authorised restart endpoint on the PostgreSQL role agent, which together would let the assembled runtime's postmaster-restart scenarios leave `plan.local.json`; the capabilities `postgres.second-server` and `postgres.control-hook` are already reserved for them. Seventh: the broker's implementation and version in the environment file, replacing the admin-interface probe.

What other plans consume. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` takes a fetched run directory `<out>/<cell-run-id>/tree/output/<run-id>`, the `dataBaseUri`, the `cell-manifest` link, the cell name and cell run identifier and the effective outcome from `cell-run.json`, and the harness revision and dirty flag from `fingerprint.kenshou`, which the payload's wrapper supplies; its attester can re-fetch with `fetchCellRun` and `OnlyRuns`. `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` and `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` get their cell-side inputs (`KENSHOU_COHORT_IDENTITY`, `KENSHOU_HARNESS_REVISION`, `KENSHOU_HARNESS_DIRTY`, `KENSHOU_CELL_FINGERPRINT`, one connection-string variable per PostgreSQL environment). `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` runs its multi-hour soaks with `kenshou cell run --detach`, gets its two contexts as two databases on the cell's server, passes gate results as `gs://` URIs, and keeps its postmaster-restart scenarios local. `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` gets its OTLP endpoint from `resolveOnCell` and its slots executed through `cellRunChild` by `kenshou cell overhead`. `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` gets the cell's Redpanda broker through the external-brokers form written by `resolveOnCell`, with the implementation and version in `fingerprint.cell.broker`. `docs/plans/8-cover-pgmq-hs-in-isolation.md` gets `pg_partman` availability recorded and its partitioned-queue runs routed by the seeded rule in `policies/cell-routing.json`, which it may extend. `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` gets Nix-built `info-table` and `profiled` variants and the `--rts` pass-through, and can reach a `ghc-debug` socket with `kenshou cell debug tunnel`. `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` receives host and cell health notices during a run through `KENSHOU_HEALTH_NOTICES`. `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` gets `KENSHOU_CELL_FAULT_HOOK` as soon as a cell offers a hook and `KENSHOU_CLOCK_SKEW_BOUND_MICROS` on multi-driver cells. `docs/plans/3-plan-and-select-runs-from-what-changed.md` needs no change: plans made with `--placement cell` are filtered by `route` and `submit`. The house CI platform can drive everything through the verbs and exit codes above and the session document. If implementation changes the payload command, the bucket layout relied on, or the addressing of nested runs, update Integration Point 9 of `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` first and then tell the consuming plans.


Revision note (2026-09-20): Aligned the `kenshou cell` family with EP-2's `haskell-jitsurei`-based CLI contract: Execution grouping, nested intent-based option sections, explicit stdin only for JSON documents, clean machine-output channels, and an embedded `cells` help topic.

Revision note (2026-09-20): Routed user-facing cell defaults through EP-2's Settei seam with explicit bindings, provenance and secret redaction, while keeping payload/session/run-plan protocol state explicit.
