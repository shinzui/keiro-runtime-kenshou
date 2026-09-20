---
id: 2
slug: build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results
title: "Build the harness kernel for scenarios, dimensions, run specs and results"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
---

# Build the harness kernel for scenarios, dimensions, run specs and results

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This repository, `keiro-runtime-kenshou`, exists to produce evidence about the keiro runtime (a cohort of Haskell libraries: the PGMQ client `pgmq-hs`, the PostgreSQL event store `kiroku`, the message-processing framework `shibuya`, and `keiro` on top). Eighteen other plans will write verification scenarios, measuring tools, checkers, cloud runners and evidence records. They can only be written in parallel if they all agree on what a scenario is, how it is parameterised, what a request to run one looks like, what comes out, and how a script tells success from failure. This plan delivers that agreement as working code: the library `kenshou-core` (the harness kernel) and the executable `kenshou`.

After this plan a maintainer can run `kenshou list` and see every registered scenario with its identifier, cost tier and placement, as text or as a versioned JSON document. They can run `kenshou run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=durable --seed 7 --out runs` and get a fresh run directory `runs/<run-id>/` holding exactly three contract documents — `run-spec.json` (what was asked, with every default made explicit), `run-result.json` (the outcome, timings, the resolved identity of every runtime package, a fingerprint of the machine and the PostgreSQL server, and a compatibility key) and `manifest.json` (the SHA-256 digest of every file) — plus logs. The process exit code is 0 for passed, 1 for failed, 2 for a usage error, 3 for inconclusive and 4 for errored or infrastructure failure, so any script or the house CI platform can branch on it. Behind that command the kernel has started a private PostgreSQL server (version 17 or 18, with durability off or on as the dimensions ask), migrated the kiroku, keiro and PGMQ schemas into it through one migration ledger, handed the scenario a connection string, torn everything down, and hashed the results. A hidden `kenshou worker` subcommand lets a scenario run part of itself in a separate operating-system process of the same binary, which is what later crash tests need.

Seven self-test scenarios under the `selftest` layer prove each of those behaviours and stay in the suite as fixtures for every later plan.


## Progress

Milestone 1 — Scenario model, layer bundles, registry and `kenshou list`

- [ ] Confirm the state EP-1 left behind (build, dev shell, `kenshou cohort show`, `docs/adr/`), as listed in Context and Orientation.
- [ ] Extend `kenshou-core/kenshou-core.cabal` (dependencies, modules, `kenshou-core-test`) and restructure `kenshou-cli` into library, executable and `kenshou-cli-test`.
- [ ] `Kenshou.Core.Id`, `Kenshou.Core.Outcome`, `Kenshou.Core.Selector` with property tests.
- [ ] `Kenshou.Core.Scenario`, `Kenshou.Core.Bundle` (`LayerBundle`, `Registry`, `mkRegistry`) with validation tests.
- [ ] `Kenshou.Core.Cli` (`CliCommand`, exit-code-2 parse handling) and `Kenshou.Cli.Registry`, `Kenshou.Cli.Main`.
- [ ] `Kenshou.Core.Selftest` with `always-pass`, `always-fail`, `errors`; `kenshou list` in text and `--json` form.

Milestone 2 — Dimensions, knobs and the run specification

- [ ] `Kenshou.Core.Knob` (specs, typed values, `--set` parsing, validation, accessors).
- [ ] `Kenshou.Core.Dimension` (four closed dimensions, `Supported`, `resolveDimensions`).
- [ ] `Kenshou.Core.Phase`, `Kenshou.Core.RunSpec` (document, hand-written JSON codecs, redaction) and `Kenshou.Core.RunSpec.Resolve` (`resolveRunSpec`).
- [ ] `kenshou run … --print-spec` prints the effective run specification; usage errors exit 2.

Milestone 3 — Environments, the composed migration plan and worker roles

- [ ] `Kenshou.Core.Env.Migration` (one `pg-migrate` plan for kiroku, keiro, PGMQ).
- [ ] `Kenshou.Core.Env.Postgres` (ephemeral fsync-off, ephemeral durable, external; version selection; template and clones; settings snapshot; server control).
- [ ] `Kenshou.Core.Role`, `Kenshou.Core.Role.Dispatch`, `Kenshou.Core.Role.Spawn`; hidden `kenshou worker`.
- [ ] Integration tests against PostgreSQL 18 and, when `KENSHOU_PG17_BIN` is set, 17.

Milestone 4 — The runner, the run directory, the manifest and exit codes

- [ ] `Kenshou.Core.Log`, `Kenshou.Core.Context` (`RunContext` and its helpers).
- [ ] `Kenshou.Core.Fingerprint`, `Kenshou.Core.Compat`, `Kenshou.Core.Canonical`.
- [ ] `Kenshou.Core.RunResult`, `Kenshou.Core.Manifest` (`writeManifest`, `verifyManifest`).
- [ ] `Kenshou.Core.Run.executeRun`; `kenshou run`; self-tests `outcome` and `known-defect`; exit-code tests.
- [ ] ADR: this repository owns the runtime-facing `list`/`run`/`compare` protocol.

Milestone 5 — Published JSON Schemas, golden fixtures and the self-test scenarios

- [ ] `schemas/*.schema.json` for the six kernel documents and `schemas/README.md`.
- [ ] Golden fixtures under `kenshou-core/test/golden/` and the schema-validation test (`check-jsonschema`).
- [ ] Self-tests `postgres-roundtrip` and `worker-echo`; `just selftest` and `just schemas-check`.
- [ ] ADR: scenarios never open a database themselves; one ledger per database. Distil the Decision Log into `docs/adr/`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Re-implement the suite-template PostgreSQL fixture inside `Kenshou.Core.Env.Postgres` instead of depending on `Keiro.Test.Postgres` or `Kiroku.Test.Postgres`.
  Rationale: Both were read. Each starts `EphemeralPg.defaultConfig` with no way to pass a configuration, so `pg.durability=durable`, extra server settings, a PostgreSQL 17 binary and an external server are all impossible through them. The pattern itself (one server, one migrated template database, `CREATE DATABASE … TEMPLATE …` clones) is about 150 lines and is copied.
  Date: 2026-09-20

- Decision: One private PostgreSQL server per run, never shared between runs; template cloning is used inside a run.
  Rationale: A shared server would mix two runs' dimension values, pollute benchmarks and make postmaster-crash scenarios unsafe. With the `initdb` cache a server costs well under a second. Clones still matter inside a run: model-based tests want a fresh database per generated case and the assembled-runtime scenarios need two databases.
  Date: 2026-09-20

- Decision: The PostgreSQL major version is selected by prepending `$KENSHOU_PG17_BIN` or `$KENSHOU_PG18_BIN` to `PATH` before starting the server.
  Rationale: `ephemeral-pg` finds `initdb`, `postgres`, `createdb` and `pg_isready` only through `PATH` (verified in its `Process` modules), and its cache key already includes the major version, so nothing else needs to change.
  Date: 2026-09-20

- Decision: A failure explained by a declared known defect keeps the outcome `failed` in the result, is marked `blocking: false`, and makes `kenshou run` exit 0; `--strict-known-defects` restores exit 1. A known defect may name the failure labels it explains, and any other label makes the failure blocking again.
  Rationale: Integration Point 3 calls this a "reported, non-blocking outcome" while Integration Point 5 fixes the outcome vocabulary at five values. Keeping the true outcome and adding a disposition satisfies both, and the label list stops a known defect from masking a new one.
  Date: 2026-09-20

- Decision: Several bundles may share one layer. Toolkit packages contribute `selftest` scenarios through their own `LayerBundle` whose `layer` is `Selftest`; uniqueness is enforced on scenario identifiers and role names, not on layers.
  Rationale: The `selftest` layer has scenarios owned by this plan and by EP-4 to EP-7, which live in different packages; Integration Point 3 only says each layer package exports one bundle.
  Date: 2026-09-20

- Decision: The result stores structured compatibility inputs plus two digests: `comparisonKey` (everything except the runtime cohort) and `seriesKey` (the same plus the solver plan hash).
  Rationale: `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` wants a series key that includes the dependency closure, but a candidate-versus-baseline comparison is by definition across two closures, and a telemetry overhead comparison is across two dimension values. Structured inputs let EP-4 and EP-7 ask "equal except for this field".
  Date: 2026-09-20

- Decision: The worker control channel is line-delimited JSON on the child's standard input and output; the child re-points file descriptor 1 at standard error before any role code runs.
  Rationale: Pipes on 0 and 1 need no file-descriptor inheritance tricks and also work through SSH. Redirecting descriptor 1 means a stray `putStrLn` in a library cannot corrupt the channel.
  Date: 2026-09-20

- Decision: Other plans add CLI verbs through a `CliCommand` value defined in `kenshou-core`, collected in `Kenshou.Cli.Registry` next to the bundles.
  Rationale: Integration Point 6 has seven plans extending one executable. A value-level seam keeps each addition to one import and one list element, the same shape as bundle registration, and avoids a dependency cycle (toolkits cannot import `kenshou-cli`).
  Date: 2026-09-20

- Decision: JSON Schemas are checked with the `check-jsonschema` tool from the Nix dev shell rather than a Haskell library.
  Rationale: No maintained Haskell validator for JSON Schema 2020-12 is part of the pinned cohort; nixpkgs carries `check-jsonschema` (0.37.4 at the time of writing). The Haskell tests still own round-trip and golden checks.
  Date: 2026-09-20

- Decision: Versioned documents use hand-written `ToJSON`/`FromJSON` instances, enum texts are explicit functions, and seeds are limited to 0 … 2^53−1.
  Rationale: Field names and enum spellings are the contract and must not move when a Haskell identifier is renamed. The seed bound keeps the value exact in `jq` and in TypeScript consumers.
  Date: 2026-09-20

- Decision: The registry refuses a `benchmark` scenario that requires PostgreSQL and supports `pg.durability=fsync-off`, and an external server whose `fsync` or version contradicts the dimensions yields `infrastructure-failure`.
  Rationale: Integration Point 4 makes `durable` mandatory for benchmarks. Enforcing it where scenarios are registered means no run plan can ever contain a mislabelled benchmark; EP-4's own refusal to summarise an `fsync-off` run remains as a second guard for external servers.
  Date: 2026-09-20

- Decision: A dimension can be `NotApplicable` for a scenario, and is then absent from documents.
  Rationale: `always-pass` has no PostgreSQL and no telemetry; forcing four values onto it would put meaningless fields into its compatibility key and multiply EP-3's matrices for nothing.
  Date: 2026-09-20

- Decision: Two self-test scenarios were added to the five the MasterPlan brief lists: `selftest/kernel/correctness/outcome` and `selftest/kernel/correctness/known-defect`.
  Rationale: Exit codes 3 and 4 for infrastructure failure, and the known-defect disposition, need a fixture that produces them on demand; EP-3 and EP-18 need the same fixtures.
  Date: 2026-09-20

- Decision: An external PostgreSQL connection string may be given by environment-variable name, and every document the kernel writes has `password=` values and URL passwords redacted.
  Rationale: Run directories are published to object storage by EP-17 and linked from OKF records by EP-18.
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The repository today and what EP-1 leaves behind

Before any child plan runs, the repository at `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` holds only `README.md`, `mori.dhall`, `mina.kdl`, `.seihou/`, `agents/skills/`, the MasterPlan `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` and the plan files under `docs/plans/`. This plan hard-depends on `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` (EP-1) and expects EP-1 to have delivered the following. A Nix dev shell (`nix develop`, GHC 9.12.4, cabal 3.16, PostgreSQL 18 on `PATH`, PostgreSQL 17 available, `just`, `jq`, `okf`). A `cabal.project` that lists packages with the glob `kenshou-*/*.cabal` and imports `cohort/active.project`, so adding a package means creating a directory and nothing else. A stub package `kenshou-core` with the module `Kenshou.Core.Cohort`, which parses `dist-newstyle/cache/plan.json` into a `CohortIdentity` (the exact version or commit of every runtime package the build linked, plus the solver plan hash) with `ToJSON` and `FromJSON` instances. A package `kenshou-cli` whose executable `kenshou` implements only `kenshou cohort show [--json]`. An ADR bundle at `docs/adr/` with `docs/adr/profile.dhall`. A `Justfile` with a `verify` recipe, a `flake.module.nix` (the file Seihou, the house scaffolding tool, never overwrites, where extra dev-shell packages go under `haskellProject.extraDevPackages`), and CI. Check that state with the commands at the top of Concrete Steps; if any is missing, stop and finish EP-1 first.

This plan takes over both packages: it keeps `Kenshou.Core.Cohort` and the `cohort show` behaviour untouched and adds everything else. If EP-1 named the identity type or its plan-hash accessor differently, adapt the import and keep the document shapes below unchanged; the kernel needs only a JSON encoding of the identity and a `Text` plan hash.

### Terms used in this plan

A *scenario* is one named verification procedure: a Haskell value with an identifier, declared parameters and a function that does the work. Scenarios are not test-suite tests; unit tests (hspec) cover the harness code itself, and scenarios are run with `kenshou run`. A *layer* is the runtime component a scenario isolates. A *bundle* is the list of scenarios and worker roles one package contributes. The *registry* is the validated union of all bundles. A *knob* is a typed per-scenario parameter. A *dimension* is a cross-cutting switch with a closed value set that every layer honours. A *run specification* (run spec) is the JSON request to execute one scenario once; the *effective* run spec is the same document after every default has been made explicit. A *run result* is the JSON record of what happened. A *run directory* is the immutable folder holding both plus artifacts. The *artifact manifest* lists every file in a run directory with its SHA-256 digest. A *cohort* is the exact set of runtime package versions a build links; the *solver plan hash* is cabal's digest of the resolved build plan. An *event store* is a database that persists an append-only log of events per stream; kiroku is one, on PostgreSQL. A *migration ledger* is the table in which a migration tool records which schema changes have been applied; all components installed in one database must share one ledger. `fsync` is the PostgreSQL setting that forces writes to disk; with it off the server is fast and loses data on a crash. A *postmaster* is PostgreSQL's parent server process. A *template database* is a database that `CREATE DATABASE … TEMPLATE …` copies, which is how a migrated schema is cloned in milliseconds. A *worker role* is a named entry point that the same `kenshou` binary can run as a child process. `SIGKILL` is the Unix signal that ends a process with no chance to clean up. A *compatibility key* is a digest of everything that must be equal for two results to be comparable. UUIDv7 is a time-ordered UUID format. OKF (Open Knowledge Format) is the house format for Markdown knowledge bundles validated by the `okf` tool; a *profile* is a Dhall file of rules for one bundle. `mori` is the house registry of projects; `mori://…` URIs are its stable identifiers.

### Runtime pieces this plan touches (all read-only)

`mori://shinzui/ephemeral-pg`, on disk at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`, version 0.3.1.0, starts throwaway PostgreSQL servers. `EphemeralPg.startCached :: Config -> CacheConfig -> IO (Either StartError Database)` restores a cached `initdb` cluster (the cache lives under the XDG cache directory, `~/.cache/ephemeral-pg`, keyed by PostgreSQL major version and a hash of the `initdb` arguments, settings and user). `Config` is a monoid; its `postgresSettings :: [(Text, Text)]` are appended verbatim to `postgresql.conf`, so a later entry overrides an earlier one. `defaultConfig` sets `fsync='off'`, `synchronous_commit='off'`, `full_page_writes='off'`, `shared_buffers='12MB'`, `wal_level='minimal'`, `log_min_messages='PANIC'` and runs `initdb --no-sync --encoding=UTF8 --no-locale --auth=trust`. The `Database` handle exposes `socketDirectory`, `port`, `user`, `dataDirectory` and `process.pid`. `EphemeralPg.restart` keeps the data directory, socket directory and port, so connection strings survive a restart, but it relaunches with `defaultConfig`, which drops the output handles. Binaries are located through `PATH` only. Abandoned servers are swept at the next start, but only inside `Config.temporaryRoot`; Unix socket paths must stay under 104 bytes, so the root must be short and stable.

`mori://shinzui/pg-migrate`, at `/Users/shinzui/Keikaku/bokuno/pg-migrate`, is the house migration library (the released cohort pins 1.1.0.0; the checkout is at 1.2.0.0 with the same signatures). A library exports a `MigrationComponent`; an application composes `migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan` and runs `runMigrationPlan :: RunOptions -> Hasql.Connection.Settings.Settings -> MigrationPlan -> IO (Either MigrationError MigrationReport)` with `defaultRunOptions`. The ledger lives in schema `pgmigrate`. The three components are `Kiroku.Store.Migrations.kirokuMigrations` (component name `kiroku`, package `kiroku-store-migrations`, in `mori://shinzui/kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), `Keiro.Migrations.keiroMigrations` (component `keiro`, which declares a dependency on `kiroku`; package `keiro-migrations` in `mori://shinzui/keiro` at `/Users/shinzui/Keikaku/bokuno/keiro`) and `Pgmq.Migration.pgmqMigrations` (component `pgmq`, package `pgmq-migration` in `mori://shinzui/pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`), each of type `Either DefinitionError MigrationComponent`. PGMQ is a message queue made of PostgreSQL tables; `pgmq-migration` installs it without the PostgreSQL extension. A second plan run against a ledger that already holds another component fails strict verification with `UnknownStoredMigration`, and keiro's own `keiro-migrate` executable has no PGMQ component, which is why the kernel composes the plan itself. The model to copy is `/Users/shinzui/Keikaku/bokuno/keiro/keiro-test-support/src/Keiro/Test/Postgres.hs` (functions `withMigratedSuiteWith`, `withFreshDatabase`, `migrateTemplate`, `connectionStringFor`, `runSqlOn`, `quoteIdentifier`).

For the self-test writes: `Kiroku.Store.withStore`, `defaultConnectionSettings`, `runStoreIO`, `appendToStream`, `readStreamForward` and `runTransaction` from `kiroku-store` 0.8; `Keiro.Timer.scheduleTimerTx :: TimerRequest -> Tx.Transaction ()` and `Keiro.Timer.lookupTimer` from `keiro` 0.17 (table `keiro.keiro_timers`); `Pgmq.Hasql.Sessions.createQueue`, `sendMessage`, `readMessage` and `Pgmq.Types.parseQueueName` from the pgmq 0.6.1 family. UUIDv7 values come from `Data.UUID.V7.genUUID` in `mmzk-typeid` 0.7, which kiroku and keiro already use.

### The contracts this plan owns

The MasterPlan's Integration Points 3 to 8 are binding; the parts this plan implements are restated here.

Scenario identity (Integration Point 3). An identifier is the four-segment path `<layer>/<component>/<kind>/<name>`, for example `kiroku/append/concurrency/expected-version-race`. Layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`. Kind is one of `correctness`, `concurrency`, `soak`, `benchmark`. Each scenario declares a cost tier — `smoke` (under one minute), `standard` (under ten minutes), `extended` (under one hour), `soak` (hours) — a placement (`local`, `cell`, `either`; a cell is a leased set of Google Cloud machines delivered by EP-16 and EP-17), its knobs, the dimension values it supports, and optionally a known-defect reference. Each layer package exports `bundle :: LayerBundle`; `kenshou-cli/src/Kenshou/Cli/Registry.hs` is the single list; a coverage plan registers with one import, one list element and one `build-depends` line in `kenshou-cli/kenshou-cli.cabal`.

Dimensions and knobs (Integration Point 4). `telemetry.tracing` takes `off`, `noop`, `sdk-inmemory`, `sdk-otlp`. `telemetry.metrics` takes `off`, `collect`, `serve`, `serve-scraped`. `pg.durability` takes `fsync-off` and `durable` (mandatory for benchmarks and crash scenarios). `pg.version` takes `17` and `18`; keiro requires 18, kiroku supports both. This plan owns the vocabulary and the PostgreSQL behaviour; EP-7 owns what the telemetry values do. Knobs are `KnobSpec` values with a name, type, default and allowed values, named after the configuration field they set, such as `kiroku.pool-size`.

Documents and the run directory (Integration Point 5). Every document is JSON with a `schema` field `kenshou.<name>/v<N>` and a JSON Schema in `schemas/`. A run identifier is a UUIDv7 in lowercase text. A later run never writes into an earlier run's directory. This plan owns `run-spec.json` (`kenshou.run-spec/v1`), `run-result.json` (`kenshou.run-result/v1`) and `manifest.json` (`kenshou.artifact-manifest/v1`); EP-4 fills `samples/` and `series/`, EP-5 `verdicts/`, EP-6 `diagnosis/`, and everyone `logs/`. Outcomes are `passed`, `failed`, `errored` (the scenario could not be evaluated), `inconclusive` (evidence too noisy to decide) and `infrastructure-failure` (the environment, not the runtime, misbehaved). The seed drives every random choice the harness makes.

The command line (Integration Point 6). This plan delivers `kenshou list`, `kenshou run`, the hidden `kenshou worker`, and keeps `kenshou cohort show`. Exit codes: 0 passed, 1 failed, 2 usage error, 3 inconclusive, 4 errored or infrastructure-failure.

Environments (Integration Point 7). A scenario never opens a database by itself; it asks the kernel for a `PostgresEnv`, either an ephemeral server honouring `pg.durability` and `pg.version` or an external server named in the run spec, migrated by one composed `pg-migrate` plan. The Kafka fixture belongs to EP-11; the kernel only carries its section of the run spec.

Worker roles (Integration Point 8). This plan owns the `WorkerRole` type, the message types and the `kenshou worker` dispatch; EP-5 owns supervision (restarts, signals, crash bookkeeping) and fault injection.

The protocol follows `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` (file `/Users/shinzui/Keikaku/bokuno/keiro-benchmarks/docs/improvement-requests/produce-hermetic-comparable-benchmark-results-with-stable-historical-identity.md`), which the MasterPlan adopts as the specification: `list` gives stable identifiers; `run` executes a versioned run spec and writes a result without judging candidate against baseline; the spec names run id, scenario, workload parameters, candidate-or-baseline role and comparison group, database mode and reset contract, and machine profile; the result identifies the effective spec, the monotonic timing source, the actual dependency closure, database and machine fingerprints, health observations, start and end times and artifact digests; a compatibility key changes whenever workload, schema, dependency closure or machine profile changes; exit status distinguishes failure to execute from an adverse result. That request is the workload part of `mori://shinzui/kotei/okf/use-cases/concepts/UC-1`; orchestration belongs to `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-3` and is out of scope.

### ADR context

There is no local ADR corpus until EP-1 creates `docs/adr/` as a profile-governed OKF bundle; when you start, scan its filenames and read EP-1's two records (layer packages never import one another; every result carries a resolved cohort identity). Three cross-repository decisions shape this plan. The shibuya repository's record "Require candidate-bound, machine-checkable release evidence" (the repository keeps ADRs outside an OKF bundle, so the artifact URI is pending: `mori://shinzui/shibuya`, path `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`) requires evidence to name exact commits, the solver plan hash, compiler, platform, service versions, commands, exit codes and seeds; the run result records all of them. `mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence and warns that repeated runs need an explicit run identity; hence the UUIDv7 run id, the never-reused directory and the manifest. `mori://shinzui/okf/okf/adrs/concepts/ADR-14` says okf records computations and never runs them, which is why run directories are plain files outside any OKF bundle. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` (only structural checks and controlled A/B workloads are authoritative performance evidence) is why the run spec carries a comparison group and the result carries compatibility inputs.

Two decisions of this plan deserve new ADRs. First, the one the MasterPlan assigns here: this repository, not `keiro-benchmarks`, owns the runtime-facing `list`/`run`/`compare` protocol, implementing IR-1 and serving UC-1, including the exit codes and the known-defect disposition. Second: scenarios never open a database themselves, the kernel provisions one private server per run, and all schema components share one ledger. Allocate each handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, name the file after the convention EP-1's records use, add a log entry with `okf log add`, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

### Packages and conventions

`kenshou-core` gains a test suite `kenshou-core-test` (hspec with `hspec-hedgehog`). `kenshou-cli` becomes a library (`hs-source-dirs: src`), an executable `kenshou` (`app/Main.hs`, one line calling `Kenshou.Cli.Main.main`, `ghc-options: -threaded -rtsopts "-with-rtsopts=-N -T"`; `-T` enables the runtime statistics EP-4 samples) and `kenshou-cli-test`, which lists `build-tool-depends: kenshou-cli:kenshou` so the real binary is on `PATH` during tests. Both cabal files follow the house shape of `/Users/shinzui/Keikaku/bokuno/keiro/keiro-test-support/keiro-test-support.cabal`: `cabal-version: 3.0`, a `common warnings` stanza, `default-language: GHC2024`, and `default-extensions: BlockArguments DuplicateRecordFields ImportQualifiedPost NoFieldSelectors OverloadedLabels OverloadedRecordDot OverloadedStrings`. With `NoFieldSelectors`, a field named `id` or `run` does not clash with the Prelude and is read as `scenario.id`. Sum types with more than one constructor use positional fields, because the house warning set includes `-Wpartial-fields`. Every type that appears in a versioned document gets hand-written `ToJSON` and `FromJSON` instances; enum spellings are given by explicit `render…`/`parse…` functions and never by `Show`.

The modules form this import order, which avoids cycles; keep to it. Leaves: `Kenshou.Core.Id`, `.Outcome`, `.Phase`, `.Knob`, `.Dimension`, `.Env`, `.Log`, `.Canonical`, `.Version`. Then `.Selector` (imports `.Id`); `.RunSpec` (document types and codecs only; imports the leaves); `.Env.Migration` and `.Env.Postgres`; `.Context` (imports `.RunSpec` and `.Env.Postgres`); `.Role` (types only; imports the leaves); `.Scenario` (imports `.Context`); `.Bundle` (imports `.Scenario`, `.Role`, `.Selector`); `.RunSpec.Resolve`, `.Role.Dispatch` and `.Cli` (import `.Bundle`); `.Role.Spawn` (imports `.Context` and `.Role`); `.Fingerprint`, `.Compat`, `.RunResult`, `.Manifest`; `.Selftest`; and last `.Run`.

### Milestone 1 — Scenario model, layer bundles, registry and `kenshou list`

Scope: the vocabulary of identifiers, the `Scenario` and `LayerBundle` types, a validated registry, the CLI skeleton and its extension seam, and `kenshou list`. At the end `cabal run kenshou -- list` prints three self-test scenarios and `cabal run kenshou -- list --json` prints a `kenshou.scenario-list/v1` document; acceptance is those two transcripts plus `cabal test kenshou-core:tests kenshou-cli:tests`.

Create `kenshou-core/src/Kenshou/Core/Id.hs`. A `Segment` matches `^[a-z][a-z0-9]*(-[a-z0-9]+)*$` and is at most 48 characters.

```haskell
data Layer = Selftest | Pgmq | Kiroku | Shibuya | Kafka | Keiro | Runtime
data Kind = Correctness | Concurrency | Soak | Benchmark
newtype Segment = Segment Text
data ScenarioId = ScenarioId {layer :: Layer, component :: Segment, kind :: Kind, name :: Segment}
newtype RunId = RunId UUID
newtype Seed = Seed Word64 -- 0 .. 2^53 - 1

renderLayer :: Layer -> Text -- selftest pgmq kiroku shibuya kafka keiro runtime
renderKind :: Kind -> Text -- correctness concurrency soak benchmark
mkSegment :: Text -> Either IdError Segment
parseScenarioId :: Text -> Either IdError ScenarioId
renderScenarioId :: ScenarioId -> Text
newRunId :: IO RunId -- Data.UUID.V7.genUUID
parseRunId :: Text -> Either IdError RunId -- canonical lowercase, version nibble 7
renderRunId :: RunId -> Text
mkSeed :: Word64 -> Either IdError Seed
deriveGen :: Seed -> Text -> System.Random.SplitMix.SMGen
```

`deriveGen seed label` is `mkSMGen (seed xor fnv1a64 (encodeUtf8 label))`, where `fnv1a64` is the 64-bit FNV-1a hash (offset basis 14695981039346656037, prime 1099511628211) written out in this module so the mapping never changes with a library upgrade. It gives the harness, each toolkit and each worker an independent, reproducible random stream from one seed (`"load"`, `"faults"`, `"worker/consumer-2"`).

Create `kenshou-core/src/Kenshou/Core/Outcome.hs`.

```haskell
data Outcome = Passed | Failed | Errored | Inconclusive | InfrastructureFailure
renderOutcome :: Outcome -> Text -- passed failed errored inconclusive infrastructure-failure
outcomeExitCode :: Outcome -> Int -- 0 1 4 3 4
usageExitCode :: Int -- 2
worstOutcome :: NonEmpty Outcome -> Outcome
```

`worstOutcome` orders `Failed` above `Errored` above `InfrastructureFailure` above `Inconclusive` above `Passed` (the order `docs/plans/3-plan-and-select-runs-from-what-changed.md` fixes for plan summaries: an unevaluated scenario is the suite's own problem and outranks an environment problem; both still map to exit code 4). A `failed` run that is non-blocking because an applicable known defect explains it is not passed to `worstOutcome` at all; callers filter on `blocking` first, so such a run leaves a plan `passed`.

Create `kenshou-core/src/Kenshou/Core/Selector.hs`. A selector is a `/`-separated pattern used by `kenshou list` and by EP-3's component graph: each segment is a literal or `*` (any one segment), and a final `**` matches all remaining segments. `pgmq/**`, `shibuya/pgmq-adapter/**`, `*/*/benchmark/*` and a full identifier are all selectors; a pattern with fewer than four segments and no trailing `**` is rejected. Export `parseSelector :: Text -> Either Text ScenarioSelector` and `matchesSelector :: ScenarioSelector -> ScenarioId -> Bool`.

Create `kenshou-core/src/Kenshou/Core/Scenario.hs` (it imports `Kenshou.Core.Context`, `.Knob`, `.Dimension` and `.Env`; in this milestone create those modules with the types shown in later milestones and fill in behaviour there).

```haskell
data Tier = TierSmoke | TierStandard | TierExtended | TierSoak -- smoke standard extended soak; Ord is cost order
data Placement = PlaceLocal | PlaceCell | PlaceEither -- local cell either

data KnownDefect = KnownDefect
  { reference :: Text -- a mori:// URI or an https:// issue URL
  , summary :: Text
  , expectedFailures :: [Text] -- failure labels this defect explains; [] means any failure
  , appliesTo :: CohortScope -- which resolved cohorts carry the defect
  }

-- A defect often exists only in the released cohort and is fixed at head (for example shibuya-core, whose
-- Hackage release and repository head both report version 0.9.0.3). The scope is evaluated against the
-- run's resolved CohortIdentity. When it does not hold, the kernel treats the scenario as having no
-- known defect, so a failure blocks: "known defect on released, must pass on head" needs no second scenario.
data CohortScope = AllCohorts | OnlyWhen (NonEmpty PackageCondition) -- every condition must hold
data PackageCondition
  = ResolvedFromHackage PackageName -- any Hackage version
  | ResolvedFromGit PackageName -- any source-repository-package commit
  | VersionBelow PackageName Version
  | RevisionIs PackageName Text -- full git commit

data ScenarioReport = ScenarioReport
  { outcome :: Outcome
  , reason :: Maybe Text -- one line; required unless passed
  , failures :: [Text] -- stable machine labels such as "no-loss"
  }

data Scenario = Scenario
  { id :: ScenarioId
  , revision :: Int -- bump when the workload's meaning changes
  , summary :: Text
  , tier :: Tier
  , placement :: Placement
  , knobs :: [KnobSpec]
  , dimensions :: DimensionSupport
  , phases :: PhasePlan -- default durations
  , requires :: EnvRequirements
  , knownDefect :: Maybe KnownDefect
  , run :: RunContext -> IO ScenarioReport
  }

passed :: ScenarioReport
failedWith :: [Text] -> Text -> ScenarioReport
inconclusiveBecause, infrastructureFailureBecause :: Text -> ScenarioReport
```

An exception escaping `run` becomes `errored`, except `InfrastructureError Text` (exported from `Kenshou.Core.Context`), which becomes `infrastructure-failure`.

Create `kenshou-core/src/Kenshou/Core/Bundle.hs`.

```haskell
data LayerBundle = LayerBundle {layer :: Layer, scenarios :: [Scenario], roles :: [WorkerRole]}
data Registry -- abstract
mkRegistry :: [LayerBundle] -> Either (NonEmpty RegistryError) Registry
allScenarios :: Registry -> [Scenario] -- sorted by identifier
allRoles :: Registry -> [WorkerRole]
lookupScenario :: Registry -> ScenarioId -> Maybe Scenario
lookupRole :: Registry -> RoleName -> Maybe WorkerRole
data ListFilter = ListFilter
  {selectors :: [ScenarioSelector], layers :: [Layer], kinds :: [Kind], maxTier :: Maybe Tier, placements :: [Placement]}
selectScenarios :: Registry -> ListFilter -> [Scenario]
```

`mkRegistry` rejects: a scenario whose `id.layer` differs from its bundle's `layer`; duplicate scenario identifiers or role names across all bundles; a role name whose prefix is not its bundle's layer; a knob default or variant outside its allowed set, or duplicate knob names; a `Supported` dimension whose default is not among its values; PostgreSQL dimensions that are applicable when `requires.postgres` is `Nothing`, or not applicable when it is present; a scenario that migrates `SchemaKeiro` yet supports `pg.version` 17; a `benchmark` scenario that requires PostgreSQL and supports `fsync-off`; `revision < 1`; and a known-defect reference that starts with neither `mori://` nor `https://`. The benchmark rule enforces Integration Point 4's "`durable` is mandatory for benchmarks"; the kernel cannot recognise a crash scenario, so the same rule for those is a convention EP-5 documents for authors.

Create `kenshou-core/src/Kenshou/Core/Cli.hs`, the seam other plans use to add verbs.

```haskell
data CliEnv = CliEnv {registry :: Registry, programName :: Text}
data CliCommand = CliCommand
  { name :: String
  , description :: String
  , hidden :: Bool
  , parser :: Options.Applicative.Parser (CliEnv -> IO ExitCode)
  }
runCli :: [LayerBundle] -> [CliCommand] -> [String] -> IO ExitCode
exitWithOutcome :: Outcome -> ExitCode
```

`runCli` validates the registry (a `RegistryError` prints every problem and returns exit code 4), builds one `subparser` of visible commands and one `internal` subparser of hidden ones, and parses with `execParserPure`. optparse-applicative's default exit code for a parse error is 1, which would collide with `failed`, so `runCli` handles `Failure` itself: render the message, and return `ExitSuccess` for `--help` or `ExitFailure 2` otherwise. A command signals a usage error by throwing `UsageError Text`, which `runCli` prints to standard error and turns into 2; any other escaped exception becomes 4.

Create `kenshou-cli/src/Kenshou/Cli/Registry.hs` with `bundles :: [LayerBundle]` (initially `[Kenshou.Core.Selftest.bundle]`) and `commands :: [CliCommand]` (list, run, worker, cohort), and `kenshou-cli/src/Kenshou/Cli/Main.hs` with `main = getArgs >>= runCli bundles commands >>= exitWith`. Move EP-1's cohort command into `kenshou-cli/src/Kenshou/Cli/Command/Cohort.hs` as a `CliCommand` without changing its output. Put a comment block at the top of `Registry.hs` stating the rule: a coverage plan adds one import and one element to `bundles`; a toolkit or tool plan may add one import and one element to `commands`.

Create `kenshou-cli/src/Kenshou/Cli/Command/List.hs`: `kenshou list [SELECTOR…] [--layer L]… [--kind K]… [--max-tier T] [--placement P]… [--roles] [--json]`. Text output is one line per scenario sorted by identifier: identifier, tier, placement, summary, and `[known defect]` when declared. `--json` prints `kenshou.scenario-list/v1`, built by `Kenshou.Core.Bundle.scenarioListDocument`:

```json
{
  "schema": "kenshou.scenario-list/v1",
  "suiteVersion": "0.1.0.0",
  "scenarios": [
    {
      "id": "selftest/kernel/correctness/postgres-roundtrip",
      "layer": "selftest", "component": "kernel", "kind": "correctness", "name": "postgres-roundtrip",
      "revision": 1,
      "summary": "Migrates kiroku, keiro and PGMQ into one ledger and writes once through each.",
      "tier": "smoke",
      "placement": "either",
      "knobs": [
        {"name": "selftest.events", "type": "int", "default": 3, "allowed": {"range": [1, 1000]}, "variants": [1, 100],
         "summary": "Events appended to the kiroku stream."}
      ],
      "dimensions": {
        "pg.durability": {"values": ["fsync-off", "durable"], "default": "fsync-off"},
        "pg.version": {"values": ["18"], "default": "18"}
      },
      "phases": {"warmUpSeconds": 0, "steadySeconds": 0, "drainSeconds": 0},
      "requires": {"postgres": {"schemas": ["kiroku", "keiro", "pgmq"], "settings": {}, "needsServerControl": false}, "kafka": false},
      "knownDefect": null
    }
  ],
  "roles": [{"name": "selftest/echo", "summary": "Replies to every custom message with the same payload."}]
}
```

`allowed` is `"any"`, `{"oneOf": […]}` or `{"range": [lo, hi]}`. A dimension that is not applicable is absent. `suiteVersion` is the `kenshou-core` package version, exported as `Kenshou.Core.Version.suiteVersion` from `Paths_kenshou_core`.

Create `kenshou-core/src/Kenshou/Core/Selftest.hs` exporting `bundle :: LayerBundle` with three scenarios, all tier `smoke`, placement `either`, no knobs, no applicable dimensions and no environment: `selftest/kernel/correctness/always-pass` returns `passed`; `selftest/kernel/correctness/always-fail` returns `failedWith ["seeded-failure"] "this scenario always fails"`; `selftest/kernel/correctness/errors` throws an `ErrorCall`.

### Milestone 2 — Dimensions, knobs and the run specification

Scope: parameterisation and the request document. At the end `kenshou run <id> --set … --dim … --print-spec` prints a complete effective run spec and every invalid input exits 2 with a message naming the offending knob or dimension; nothing executes yet.

Create `kenshou-core/src/Kenshou/Core/Knob.hs`. A knob name matches `^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$`. Enumerations are `KnobText` with `OneOf`; durations are integers with the unit in the name, as in `pgmq.visibility-timeout-seconds`.

```haskell
newtype KnobName = KnobName Text
data KnobType = KnobBool | KnobInt | KnobDouble | KnobText -- bool int double text
data KnobValue = VBool !Bool | VInt !Int64 | VDouble !Double | VText !Text
data Allowed = AnyValue | OneOf (NonEmpty KnobValue) | IntRange !Int64 !Int64 | DoubleRange !Double !Double
data KnobSpec = KnobSpec
  { name :: KnobName
  , summary :: Text
  , knobType :: KnobType
  , def :: KnobValue
  , allowed :: Allowed
  , variants :: [KnobValue] -- values worth sweeping; EP-3 expands them
  }
data RawKnob = RawText Text | RawJson Aeson.Value -- from --set, from a spec file
newtype ResolvedKnobs = ResolvedKnobs (Map KnobName KnobValue)

parseAssignment :: Text -> Either KnobError (KnobName, RawKnob) -- "kiroku.pool-size=12"
resolveKnobs :: [KnobSpec] -> [(KnobName, RawKnob)] -> Either (NonEmpty KnobError) ResolvedKnobs
knobBool :: HasCallStack => ResolvedKnobs -> KnobName -> Bool
knobInt :: HasCallStack => ResolvedKnobs -> KnobName -> Int64
knobDouble :: HasCallStack => ResolvedKnobs -> KnobName -> Double
knobText :: HasCallStack => ResolvedKnobs -> KnobName -> Text
```

`resolveKnobs` fills every declared knob, and reports unknown names, duplicates, type mismatches (`RawText` is parsed by declared type: `true`/`false`, decimal integer, decimal number, or the raw text) and values outside `allowed`. The accessors throw only on a programming error (an undeclared knob or wrong type), which the runner reports as `errored`. Toolkits may export reusable `[KnobSpec]` lists (EP-7's `otel.*` knobs) for scenarios to append.

Create `kenshou-core/src/Kenshou/Core/Dimension.hs`.

```haskell
data TracingArm = TracingOff | TracingNoop | TracingSdkInMemory | TracingSdkOtlp -- off noop sdk-inmemory sdk-otlp
data MetricsArm = MetricsOff | MetricsCollect | MetricsServe | MetricsServeScraped -- off collect serve serve-scraped
data PgDurability = PgFsyncOff | PgDurable -- fsync-off durable
data PgVersion = Pg17 | Pg18 -- "17" "18"
data DimensionName = DimTracing | DimMetrics | DimPgDurability | DimPgVersion
-- telemetry.tracing telemetry.metrics pg.durability pg.version

data Support a = Support {values :: NonEmpty a, def :: a} -- def must be one of values
data Supported a = NotApplicable | Supported (Support a)
data DimensionSupport = DimensionSupport
  {tracing :: Supported TracingArm, metrics :: Supported MetricsArm, pgDurability :: Supported PgDurability, pgVersion :: Supported PgVersion}
data Dimensions = Dimensions
  {tracing :: Maybe TracingArm, metrics :: Maybe MetricsArm, pgDurability :: Maybe PgDurability, pgVersion :: Maybe PgVersion}

noDimensions :: DimensionSupport
allTelemetryArms :: DimensionSupport -> DimensionSupport -- every tracing and metrics value, default off
postgresDimensions :: NonEmpty PgDurability -> NonEmpty PgVersion -> DimensionSupport -> DimensionSupport -- default = head
resolveDimensions :: DimensionSupport -> [(Text, Text)] -> Either (NonEmpty DimensionError) Dimensions
renderDimensions :: Dimensions -> [(Text, Text)] -- applicable dimensions only, sorted by name
```

`resolveDimensions` rejects an unknown dimension name, a value outside the closed set, a value the scenario does not support, and any assignment to a dimension that is not applicable.

Create `kenshou-core/src/Kenshou/Core/Env.hs` with the requirement types (no behaviour).

```haskell
data SchemaComponent = SchemaKiroku | SchemaKeiro | SchemaPgmq -- kiroku keiro pgmq
data PostgresRequirement = PostgresRequirement
  { schemas :: [SchemaComponent] -- SchemaKeiro implies SchemaKiroku
  , settings :: [(Text, Text)] -- postgresql.conf additions, applied to ephemeral servers only
  , needsServerControl :: Bool -- True: only an ephemeral server will do
  }
data EnvRequirements = EnvRequirements
  { postgres :: Maybe PostgresRequirement -- the primary server
  , extraPostgres :: [(Text, PostgresRequirement)] -- further, independently restartable servers, by name
  , kafka :: Bool
  }
noEnvironment :: EnvRequirements
```

`extraPostgres` exists because the assembled-runtime plan (`docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) runs two bounded contexts, each with its own PostgreSQL server that must be restartable without touching the other. Every other scenario leaves it empty. Each named requirement is provisioned exactly like the primary one and appears in `Environment.extraPostgres :: Map Text PostgresEnv`; the run specification carries a matching optional `environment.extraPostgres` object keyed by the same names (absent when empty), and the fingerprint records one `postgres` entry per server under `fingerprint.extraPostgres`. In external mode each name needs its own connection string (`--pg-url-env NAME=VAR`).

Create `kenshou-core/src/Kenshou/Core/Phase.hs` with `data PhaseName = WarmUp | Steady | Drain` (rendered `warm-up`, `steady`, `drain`) and `data PhasePlan = PhasePlan {warmUpSeconds :: Double, steadySeconds :: Double, drainSeconds :: Double}`. Then create `kenshou-core/src/Kenshou/Core/RunSpec.hs` (types, codecs and redaction) and `kenshou-core/src/Kenshou/Core/RunSpec/Resolve.hs` (`resolveRunSpec`, which needs the registry).

```haskell
data SpecPlacement = RunLocal | RunOnCell -- local cell
data ConnectionSource = ConnLiteral Text | ConnFromEnv Text
data PostgresSpec = PostgresEphemeral [(Text, Text)] {- extra settings -} | PostgresExternal ConnectionSource
data EnvironmentSpec = EnvironmentSpec
  { placement :: SpecPlacement
  , machineProfile :: Maybe Text
  , postgres :: Maybe PostgresSpec
  , kafka :: Maybe Aeson.Value -- opaque; schema owned by EP-11
  , telemetry :: Maybe Aeson.Value -- opaque; schema owned by EP-7 (for example the OTLP endpoint)
  }
data CohortExpectation = CohortExpectation {name :: Maybe Text, planHash :: Text}
data ComparisonMembership = ComparisonMembership {group :: Text, arm :: Text, trial :: Int, position :: Int}

data RunSpec = RunSpec -- as read; only scenario is required
  { runId :: Maybe RunId, scenario :: ScenarioId, scenarioRevision :: Maybe Int
  , knobs :: [(KnobName, RawKnob)], dimensions :: [(Text, Text)], seed :: Maybe Seed
  , phases :: Maybe PhasePlan, timeoutSeconds :: Maybe Int, environment :: EnvironmentSpec
  , cohortExpectation :: Maybe CohortExpectation, comparison :: Maybe ComparisonMembership, labels :: Map Text Text }

data EffectiveRunSpec = EffectiveRunSpec -- as executed and written; nothing optional is left implicit
  { runId :: RunId, scenario :: ScenarioId, scenarioRevision :: Int
  , knobs :: ResolvedKnobs, dimensions :: Dimensions, seed :: Seed
  , phases :: PhasePlan, timeoutSeconds :: Int, environment :: EnvironmentSpec
  , cohortExpectation :: Maybe CohortExpectation, comparison :: Maybe ComparisonMembership, labels :: Map Text Text }

redactConnectionString :: Text -> Text

-- in Kenshou.Core.RunSpec.Resolve
resolveRunSpec :: Registry -> RunSpec -> IO (Either (NonEmpty SpecError) (Scenario, EffectiveRunSpec))
```

`resolveRunSpec` looks up the scenario, checks `scenarioRevision` if given, resolves knobs and dimensions, generates a run id and a seed when absent, takes phases from the scenario when absent, and defaults the timeout by tier (smoke 120 s, standard 1200 s, extended 7200 s, soak the three phase durations plus 1800 s). It defaults `environment.postgres` to ephemeral when the scenario requires PostgreSQL, and rejects: an external server when `needsServerControl` is set, `settings` on an external server, a `cell`-only scenario with placement `local` (and the reverse), and a PostgreSQL section for a scenario that needs none. `machineProfile` defaults to `local/<os>-<arch>/<cpu-model-slug>/<cores>c/<memory-GiB>g`. The `comparison` section is carried through untouched; it is how EP-3, EP-4 and EP-7 mark paired executions (group, arm such as `candidate` or `tracing=off`, trial number, position in the interleaving). The effective document looks like this:

```json
{
  "schema": "kenshou.run-spec/v1",
  "runId": "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55",
  "scenario": "selftest/kernel/correctness/postgres-roundtrip",
  "scenarioRevision": 1,
  "knobs": {"selftest.events": 3},
  "dimensions": {"pg.durability": "durable", "pg.version": "18"},
  "seed": 7,
  "phases": {"warmUpSeconds": 0, "steadySeconds": 0, "drainSeconds": 0},
  "timeoutSeconds": 120,
  "environment": {
    "placement": "local",
    "machineProfile": "local/darwin-aarch64/apple-m3-max/16c/64g",
    "postgres": {"mode": "ephemeral", "settings": {}},
    "kafka": null,
    "telemetry": null
  },
  "cohortExpectation": null,
  "comparison": null,
  "labels": {}
}
```

An external server is written `{"mode": "external", "connectionStringEnv": "KENSHOU_PG_URL"}` or `{"mode": "external", "connectionString": "host=10.0.0.5 dbname=postgres user=kenshou"}`. Knob values are plain JSON scalars typed by the scenario's declaration; dimension values are always strings. The minimal input document is `{"schema": "kenshou.run-spec/v1", "scenario": "<id>"}`.

Create `kenshou-cli/src/Kenshou/Cli/Command/Run.hs` with the full option surface, of which this milestone implements parsing, resolution and `--print-spec`: `kenshou run (--spec FILE | SCENARIO) [--set K=V]… [--dim N=V]… [--phase warm-up|steady|drain=SECONDS]… [--seed N] [--run-id UUID] [--timeout SECONDS] [--out DIR] [--pg-url URL | --pg-url-env VAR] [--placement local|cell] [--machine-profile NAME] [--cohort-identity FILE] [--cell-fingerprint FILE] [--keep-env] [--strict-known-defects] [--print-spec] [--json]`. Command-line values override the spec file. `--out` defaults to `runs`; add `runs/` to `.gitignore`.

### Milestone 3 — Environments, the composed migration plan and worker roles

Scope: everything a scenario needs from outside its own process. At the end the integration tests start real PostgreSQL servers in both durability modes, prove that the three schemas share one ledger, clone databases, and exchange messages with a child `kenshou worker` process.

Create `kenshou-core/src/Kenshou/Core/Env/Migration.hs` exporting `composePlan :: [SchemaComponent] -> Either MigrationSetupError MigrationPlan` and `migrateDatabase :: Text -> MigrationPlan -> IO (Either MigrationSetupError ())`. `composePlan` de-duplicates, adds `SchemaKiroku` when `SchemaKeiro` is present, orders the components kiroku, keiro, pgmq, and calls `migrationPlan`. `migrateDatabase` calls `runMigrationPlan defaultRunOptions (Hasql.Connection.Settings.connectionString connStr) plan`. An empty component list means no migration.

Create `kenshou-core/src/Kenshou/Core/Env/Postgres.hs`.

```haskell
data PgSettingsSnapshot = PgSettingsSnapshot
  {serverVersion :: Text, serverVersionNum :: Int, settings :: Map Text Text, superuser :: Bool, collation :: Text, encoding :: Text}
data StopMode = StopFast | StopImmediate -- pg_ctl -m fast | -m immediate (immediate = crash: no checkpoint, WAL replay on start)
data ServerControl = ServerControl
  { currentServer :: IO EphemeralPg.Database -- dataDirectory, process.pid, port
  , restartServer :: IO () -- EphemeralPg.restart, then swap the handle
  , stopServer :: StopMode -> IO () -- leaves the data directory in place
  , startServer :: IO () -- starts the stopped server on the same port and data directory, then swaps the handle
  }
data PostgresEnv = PostgresEnv
  { mode :: PostgresMode -- PgEphemeral | PgExternal
  , connectionString :: Text -- the run's own migrated database, libpq key=value form so callers may append options
  , tcpEndpoint :: Maybe (Text, Int) -- host and port of the server's TCP listener, for the fault proxy
  , adminConnectionString :: Text -- maintenance database on the same server
  , databaseName :: Text
  , newDatabase :: Text -> IO Text -- clone another migrated database; returns its connection string
  , snapshot :: PgSettingsSnapshot
  , control :: Maybe ServerControl -- ephemeral only
  }
withPostgresEnv ::
  Logger -> FilePath {- run directory -} -> RunId -> PostgresRequirement -> PostgresSpec -> Dimensions ->
  (PostgresEnv -> IO a) -> IO (Either EnvError a)
```

Ephemeral mode works as follows. Resolve the binary directory from `KENSHOU_PG17_BIN` or `KENSHOU_PG18_BIN` according to `pg.version` and prepend it to `PATH` with `setEnv` (the runner holds a process-wide lock around provisioning, so this is safe for sequential in-process runs); if the variable is unset, accept the `postgres` already on `PATH` when `postgres --version` reports the right major version, and otherwise fail with `EnvError` naming the variable. Build the configuration as `EphemeralPg.defaultConfig` with `temporaryRoot` set to `/tmp/ephpg-kenshou-<uid>` (created if missing, so a later run sweeps servers orphaned by a killed one), then append settings in this order so later entries win: logging for every mode (`log_min_messages='WARNING'`, `log_line_prefix='%m [%p] %a '`, `logging_collector='on'`, `log_directory='log'`, `log_filename='postgres.log'`); for `durable`, `fsync='on'`, `synchronous_commit='on'`, `full_page_writes='on'`; then the scenario's required settings; then the run spec's settings. The log directory is deliberately relative to the data directory and identical for every run: the `initdb` cache key hashes the settings list, so a per-run path would defeat the cache and leave one cache entry per run, while settings written to `postgresql.conf` (unlike output handles) survive `restartServer`. At teardown, before the server's directories are removed, copy `<data-directory>/log/postgres.log` to `logs/postgres.log` in the run directory. Start with `startCached config defaultCacheConfig`. Create the database `kenshou_template`, migrate it, then clone `kenshou_run` from it for the scenario; `newDatabase label` clones `kenshou_<label>_<n>`. Migration connections are closed before any clone, because PostgreSQL refuses to copy a template with active sessions. Teardown stops the server (which removes its directories) unless `--keep-env` was given, in which case the connection string is logged and the server is left for the next sweep. Note that `durable` leaves `shared_buffers` at 12 MB; local benchmark numbers are for development, and scenarios or operators that care pass `shared_buffers` through settings.

Three more properties of the ephemeral server are part of the contract because other plans build on them. First, the server listens on TCP as well as on its Unix socket: `listen_addresses='127.0.0.1'` is among the settings applied in every mode (it is the same for every run, so it does not disturb the `initdb` cache), and `tcpEndpoint` is `Just ("127.0.0.1", port)`. The correctness toolkit's network fault proxy (`docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md`) sits between a client and that endpoint; verify in `ephemeral-pg` 0.3.1.0 that a TCP listener can be enabled this way and, if its `Config` needs a different switch, use that and record it in Surprises & Discoveries. Second, `connectionString` is always in libpq key=value form (`host=… port=… dbname=… user=…`), never a URI, so a layer may append options such as `application_name=…` or keepalive settings by concatenation; kiroku's pool connections carry no `application_name` of their own, and the kiroku coverage plan depends on this. Third, `stopServer StopImmediate` followed by `startServer` is what "PostgreSQL crashed" means in this suite: it uses `pg_ctl stop -m immediate` on the server's data directory, so no checkpoint is written and the next start replays the write-ahead log. `EphemeralPg.restart` in 0.3.1.0 starts the new server from `defaultConfig` rather than from the original configuration, so `restartServer` and `startServer` must re-apply this run's settings (they live in `postgresql.conf`, which survives) and must keep the same port; assert both in the integration test. For an external server `control` is `Nothing` and `tcpEndpoint` is parsed from the connection string when it names a host and port.

External mode resolves the connection string (reading the environment variable when asked), connects to it as the maintenance database, and honours this reset contract: every run gets a new database named `kenshou_<first 13 hex digits of the run id>` plus a template beside it, both migrated from nothing and both dropped with `DROP DATABASE … WITH (FORCE)` at teardown; an existing database of that name or a role without `CREATEDB` is an `EnvError`. The kernel cannot change an external server's settings, so it verifies them instead: `server_version_num` must match `pg.version`, and `fsync` and `synchronous_commit` must match `pg.durability`. A mismatch, like any `EnvError`, is reported by the runner as `infrastructure-failure`. Scenario-required settings are not applied externally and are recorded as a warning observation.

The snapshot reads `SHOW server_version`, `current_setting('server_version_num')`, the role's `rolsuper`, the database's `datcollate` and encoding, and these `pg_settings` rows: `fsync`, `synchronous_commit`, `full_page_writes`, `wal_level`, `shared_buffers`, `effective_cache_size`, `work_mem`, `max_connections`, `checkpoint_timeout`, `checkpoint_completion_target`, `max_wal_size`, `wal_buffers`, `random_page_cost`, `autovacuum`, `shared_preload_libraries`. Run one-off SQL the way the keiro fixture does, through a `hasql-pool` of size one.

Create `kenshou-core/src/Kenshou/Core/Role.hs` (types and wire format only).

```haskell
newtype RoleName = RoleName Text -- "<layer>/<segment>", for example "selftest/echo"
data WorkerRole = WorkerRole {name :: RoleName, summary :: Text, run :: RoleContext -> IO ()}
data PostgresConnInfo = PostgresConnInfo {connectionString :: Text, adminConnectionString :: Text}
data WorkerInit = WorkerInit -- kenshou.worker-init/v1
  { runId :: RunId, scenario :: ScenarioId, role :: RoleName, instanceName :: Text, seed :: Seed
  , knobs :: ResolvedKnobs, dimensions :: Dimensions, postgres :: Maybe PostgresConnInfo
  , kafka :: Maybe Aeson.Value, telemetry :: Maybe Aeson.Value, outDir :: FilePath, args :: Aeson.Value }
data ControlMessage -- parent to worker
  = CtlInit WorkerInit | CtlStart | CtlPhase PhaseName | CtlStop Int {- grace, ms -} | CtlCustom Text Aeson.Value {- name, payload -}
data WorkerMessage -- worker to parent
  = WrkReady | WrkProgress Int64 UTCTime {- count, at -} | WrkFacts [Aeson.Value] {- batch -}
  | WrkCustom Text Aeson.Value {- name, payload -} | WrkDone (Maybe Text) {- detail -} | WrkError Text {- message -}
data RoleContext = RoleContext
  { init :: WorkerInit
  , receive :: IO (Maybe ControlMessage) -- Nothing: the parent is gone
  , send :: WorkerMessage -> IO ()
  , logger :: Logger
  }
```

Each message is one line of JSON with a version and a type tag (`kenshou.worker-message/v1`). `WrkFacts` batches are opaque here; EP-5 defines what a fact is.

```json
{"v": 1, "type": "init", "init": {"schema": "kenshou.worker-init/v1", "runId": "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55", "scenario": "selftest/kernel/concurrency/worker-echo", "role": "selftest/echo", "instance": "echo-1", "seed": 7, "knobs": {}, "dimensions": {}, "postgres": null, "kafka": null, "telemetry": null, "outDir": "runs/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55", "args": {}}}
{"v": 1, "type": "ready"}
{"v": 1, "type": "custom", "name": "echo", "payload": {"n": 1}}
{"v": 1, "type": "stop", "graceMillis": 2000}
{"v": 1, "type": "done", "detail": null}
```

The other type tags are `start`, `phase` (`{"name": "steady"}`), `progress` (`{"count": 1200, "at": "2026-09-20T17:20:01.250Z"}`), `facts` (`{"batch": […]}`) and `error` (`{"message": "…"}`).

Create `kenshou-core/src/Kenshou/Core/Role/Dispatch.hs` with `runWorker :: Registry -> RoleName -> IO ExitCode`, the body of `kenshou worker --role NAME` (`kenshou-cli/src/Kenshou/Cli/Command/Worker.hs`, registered with `hidden = True`). It duplicates standard output to a private handle for the channel and re-points file descriptor 1 at standard error (`hDuplicate` then `hDuplicateTo stderr stdout`); reads the first line, which must be `init`; starts a reader thread that feeds a bounded queue and, on end of input, delivers `Nothing`, waits two seconds and then exits the process with code 75 so that a killed harness never leaves orphans; builds a logger that writes JSON lines to standard error; runs the role; sends `done` and returns 0, or sends `error` and returns 70 if the role threw. An unknown role or a malformed `init` returns 2.

Create `kenshou-core/src/Kenshou/Core/Role/Spawn.hs`, the primitive EP-5's `Kenshou.Check.Process` builds its supervision on.

```haskell
data WorkerHandle = WorkerHandle
  { instanceName :: Text, pid :: CPid
  , send :: ControlMessage -> IO ()
  , receive :: Int {- timeout ms -} -> IO (Maybe WorkerMessage)
  , waitExit :: IO ExitCode }
withWorker :: RunContext -> RoleName -> Text {- instance -} -> Aeson.Value {- args -} -> (WorkerHandle -> IO a) -> IO a
```

`withWorker` launches `getExecutablePath` with `worker --role <name>` through `typed-process`, in its own process group, with pipes on standard input and output and standard error appended to `logs/worker-<instance>.stderr.log`; sends `init` built from the context; and on exit sends `stop`, waits the grace period, then sends `SIGTERM` and finally `SIGKILL` to the group.

### Milestone 4 — The runner, the run directory, the manifest and exit codes

Scope: executing a run end to end. At the end `kenshou run` produces complete run directories for every outcome and its exit codes match the contract.

Create `kenshou-core/src/Kenshou/Core/Log.hs`: `data Logger`, `logAt :: Logger -> Severity -> Text -> [(Text, Aeson.Value)] -> IO ()`, writing JSON lines (`ts`, `level`, `msg`, `fields`, `runId`, `process`) to `logs/harness.jsonl` and a human line to standard error. Standard output is reserved for the command's result; scenario code logs and never prints.

Create `kenshou-core/src/Kenshou/Core/Context.hs`.

```haskell
data SummarySection = Measurements | Verdicts | Diagnosis | Telemetry -- owners: EP-4, EP-5, EP-6, EP-7
data ArtifactDir = SamplesDir | SeriesDir | VerdictsDir | DiagnosisDir | LogsDir
data Observation = Observation {source :: Text, severity :: Severity, message :: Text, at :: UTCTime}
data Environment = Environment {postgres :: Maybe PostgresEnv}
data RunContext = RunContext
  { runId :: RunId, scenario :: ScenarioId, knobs :: ResolvedKnobs, dimensions :: Dimensions, seed :: Seed
  , phases :: PhasePlan, env :: Environment, environmentSpec :: EnvironmentSpec
  , comparison :: Maybe ComparisonMembership, outDir :: FilePath, logger :: Logger, state :: RunState {- opaque -} }

requirePostgres :: HasCallStack => RunContext -> PostgresEnv
genFor :: RunContext -> Text -> SMGen
withPhase :: RunContext -> PhaseName -> IO a -> IO a
putSummary :: RunContext -> SummarySection -> Text -> Aeson.Value -> IO ()
observe :: RunContext -> Text -> Severity -> Text -> IO ()
artifactPath :: RunContext -> ArtifactDir -> FilePath -> IO FilePath
declareMediaType :: RunContext -> FilePath -> Text -> IO ()
```

`withPhase` records wall-clock and monotonic (`GHC.Clock.getMonotonicTimeNSec`) start and end marks, which is what EP-4 uses to exclude warm-up. `putSummary section key value` stores opaque JSON under `summaries.<section>.<key>` of the result; a repeated key overwrites. `artifactPath` creates the directory and returns the full path; toolkits just write files and the manifest finds them. `observe` appends a health observation.

Create `kenshou-core/src/Kenshou/Core/Fingerprint.hs` (`collectHostFingerprint :: IO HostFingerprint`): operating system and architecture (`System.Info`), kernel release (`uname -r`), CPU model and memory (`/proc/cpuinfo` and `/proc/meminfo` on Linux; `sysctl -n machdep.cpu.brand_string` and `hw.memsize` on macOS), logical cores, host name, GHC version (`System.Info.fullCompilerVersion`), RTS arguments, capabilities, whether the RTS is threaded and whether statistics are enabled, the `kenshou` version and the SHA-256 of its executable. With `--cell-fingerprint FILE` (or `KENSHOU_CELL_FINGERPRINT`), the JSON the cell supplies is embedded verbatim under `fingerprint.cell`.

Create `kenshou-core/src/Kenshou/Core/Canonical.hs` (`canonicalEncode :: Aeson.Value -> ByteString` with object keys sorted bytewise and no whitespace; `sha256Hex :: ByteString -> Text` via `cryptohash-sha256` and `base16-bytestring`) and `kenshou-core/src/Kenshou/Core/Compat.hs`.

```haskell
data CompatField = CfSuiteVersion | CfScenario | CfKnob KnobName | CfDimension DimensionName | CfPhases
                 | CfMachineProfile | CfPostgresProfile | CfSchemas | CfCohort
compatInputs :: EffectiveRunSpec -> Maybe PgSettingsSnapshot -> CohortIdentity -> CompatInputs
comparisonKey, seriesKey :: CompatInputs -> Text -- "sha256:<hex>"
compatibleExcept :: [CompatField] -> CompatInputs -> CompatInputs -> Either (NonEmpty CompatField) ()
```

The inputs are: suite version, scenario and revision, every knob, every applicable dimension, phases, machine profile, PostgreSQL profile (mode, major version, `fsync`, `synchronous_commit`, reset contract `fresh-database`), the two schema names, and the solver plan hash. `comparisonKey` digests the canonical encoding of all of them except the plan hash; `seriesKey` includes it. The algorithm name stored in the document is `kenshou.compat-key/v1`.

Create `kenshou-core/src/Kenshou/Core/RunResult.hs` and `kenshou-core/src/Kenshou/Core/Manifest.hs` (`writeManifest :: FilePath -> RunId -> Map FilePath Text -> IO Manifest`, `verifyManifest :: FilePath -> IO (Either (NonEmpty ManifestProblem) ())`). The manifest lists every regular file under the run directory except `manifest.json` itself, sorted by path, with media types by extension (`.json` `application/json`, `.jsonl` `application/x-ndjson`, `.csv` `text/csv`, `.log` and `.txt` `text/plain`, otherwise `application/octet-stream`) unless declared. The result document:

```json
{
  "schema": "kenshou.run-result/v1",
  "runId": "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55",
  "scenario": "selftest/kernel/correctness/postgres-roundtrip",
  "scenarioRevision": 1,
  "layer": "selftest", "component": "kernel", "kind": "correctness", "tier": "smoke",
  "outcome": "passed",
  "blocking": false,
  "exitCode": 0,
  "reason": null,
  "failures": [],
  "knownDefect": null,
  "seed": 7,
  "spec": {"path": "run-spec.json", "sha256": "5d0c…"},
  "comparison": null,
  "timings": {
    "clock": "GHC.Clock.getMonotonicTimeNSec",
    "startedAt": "2026-09-20T17:20:00.104Z", "endedAt": "2026-09-20T17:20:03.871Z",
    "durationSeconds": 3.767, "setupSeconds": 2.95, "scenarioSeconds": 0.61, "teardownSeconds": 0.2,
    "phases": [{"name": "steady", "startedAt": "2026-09-20T17:20:03.060Z", "endedAt": "2026-09-20T17:20:03.660Z",
                "startedMonotonicNs": 81234000000, "endedMonotonicNs": 81834000000}]
  },
  "cohort": {"…": "the CohortIdentity document from Kenshou.Core.Cohort, verbatim"},
  "fingerprint": {
    "placement": "local",
    "machineProfile": "local/darwin-aarch64/apple-m3-max/16c/64g",
    "host": {"os": "darwin", "arch": "aarch64", "kernel": "25.6.0", "cpuModel": "Apple M3 Max", "logicalCores": 16, "memoryBytes": 68719476736, "hostname": "workstation"},
    "runtime": {"ghc": "9.12.4", "rtsArgs": ["-N", "-T"], "capabilities": 16, "threaded": true, "rtsStats": true},
    "kenshou": {"version": "0.1.0.0", "executableSha256": "9a1f…", "revision": "4f0c2d7e9a1b3c5d6e7f8091a2b3c4d5e6f70812", "dirty": false},
    "postgres": {"mode": "ephemeral", "serverVersion": "18.1", "serverVersionNum": 180001, "superuser": true, "collation": "C", "encoding": "UTF8",
                 "reset": {"contract": "fresh-database", "database": "kenshou_run"},
                 "settings": {"fsync": "on", "synchronous_commit": "on", "full_page_writes": "on", "shared_buffers": "1536"}},
    "cell": null
  },
  "invocation": {"argv": ["run", "selftest/kernel/correctness/postgres-roundtrip", "--dim", "pg.durability=durable", "--seed", "7"], "workingDirectory": "/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou"},
  "compatibility": {
    "algorithm": "kenshou.compat-key/v1",
    "comparisonKey": "sha256:41c9…", "seriesKey": "sha256:e07a…",
    "inputs": {"suiteVersion": "0.1.0.0", "scenario": "selftest/kernel/correctness/postgres-roundtrip", "scenarioRevision": 1,
               "knobs": {"selftest.events": 3}, "dimensions": {"pg.durability": "durable", "pg.version": "18"},
               "phases": {"warmUpSeconds": 0, "steadySeconds": 0, "drainSeconds": 0},
               "machineProfile": "local/darwin-aarch64/apple-m3-max/16c/64g",
               "postgresProfile": {"mode": "ephemeral", "major": 18, "fsync": "on", "synchronousCommit": "on", "reset": "fresh-database"},
               "schemas": {"runSpec": "kenshou.run-spec/v1", "runResult": "kenshou.run-result/v1"},
               "cohortPlanHash": "b3f2…"}
  },
  "summaries": {"measurements": {}, "verdicts": {}, "diagnosis": {}, "telemetry": {}},
  "observations": [],
  "artifacts": {"samples": [], "series": [], "verdicts": [], "diagnosis": [], "logs": ["logs/harness.jsonl", "logs/harness.stderr.log", "logs/postgres.log"], "other": []}
}
```

`fingerprint.kenshou.revision` is the full 40-character commit of this repository that built the executable and `dirty` says whether the working tree had uncommitted changes; the evidence plan (`docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md`) refuses to record a run without them. Resolve them in this order: the environment variables `KENSHOU_HARNESS_REVISION` and `KENSHOU_HARNESS_DIRTY` (how a Nix-built payload on a cell supplies them, see `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`), then `git rev-parse HEAD` and `git status --porcelain` run in the directory containing `cabal.project` when the executable runs from a checkout; if neither works, write `null` and add a warning observation.

`knownDefect`, when the scenario declares one and its `appliesTo` scope holds for the run's cohort, is `{"reference": …, "summary": …, "expectedFailures": […], "status": …}` with status `reproduced` (outcome `failed` and every reported failure label explained), `different-failure` (failed with an unexplained label) or `not-reproduced` (any other outcome; worth a look, because the defect may be fixed in this cohort). `blocking` is true exactly when the outcome is not `passed` and the status is not `reproduced`. `exitCode` is `outcomeExitCode outcome`, except that a `reproduced` known defect exits 0 unless `--strict-known-defects` was given.

The manifest document:

```json
{
  "schema": "kenshou.artifact-manifest/v1",
  "runId": "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55",
  "createdAt": "2026-09-20T17:20:03.902Z",
  "algorithm": "sha256",
  "files": [
    {"path": "logs/harness.jsonl", "sha256": "0c4e…", "bytes": 2210, "mediaType": "application/x-ndjson"},
    {"path": "run-result.json", "sha256": "77ab…", "bytes": 3904, "mediaType": "application/json"},
    {"path": "run-spec.json", "sha256": "5d0c…", "bytes": 812, "mediaType": "application/json"}
  ]
}
```

Create `kenshou-core/src/Kenshou/Core/Run.hs`.

```haskell
data RunnerConfig = RunnerConfig
  { registry :: Registry, outRoot :: FilePath, cohort :: CohortIdentity, cellFingerprint :: Maybe Aeson.Value
  , keepEnvironment :: Bool, strictKnownDefects :: Bool, argv :: [String] }
data RunOutput = RunOutput {directory :: FilePath, result :: RunResult, manifestSha256 :: Text}
executeRun :: RunnerConfig -> RunSpec -> IO (Either (NonEmpty SpecError) RunOutput)
```

`executeRun` proceeds in this order. Resolve the spec; errors return `Left` and nothing is written (the CLI exits 2). Create `<out>/<run-id>/`, failing as a usage error if it exists. Write `run-spec.json` (effective, redacted) atomically by writing a temporary file and renaming it. Open the logger and tee file descriptor 2 into `logs/harness.stderr.log`. Compare `cohortExpectation.planHash` with the resolved identity; a mismatch skips the scenario with outcome `infrastructure-failure` and reason `cohort-mismatch`. Provision the environment inside a bracket; an `EnvError` gives `infrastructure-failure`. Collect the fingerprint. Run `scenario.run ctx` in an `async` under `System.Timeout.timeout`; a timeout gives `errored` with reason `timeout after N s`, `SIGINT` or `SIGTERM` cancels it and gives `errored` with reason `interrupted`. Tear down (a teardown failure becomes an observation, not a changed outcome). Apply the known-defect rules. Write `run-result.json`, then `manifest.json` last: a run directory is complete if and only if `manifest.json` exists, which is what EP-3's resume and EP-17's fetch rely on. The function is safe to call repeatedly in one process, one run at a time.

The cohort identity comes from `--cohort-identity FILE` or `KENSHOU_COHORT_IDENTITY` (a JSON file, which is how EP-17 supplies it on a cell where no `dist-newstyle` exists), and otherwise from EP-1's resolver reading `dist-newstyle/cache/plan.json`. If neither works, `kenshou run` exits 2 explaining both options, because a result without a cohort identity is not evidence.

Finish `Kenshou.Cli.Command.Run`: text mode prints `<outcome>  <scenario>  <run-dir>` on standard output; `--json` prints the run result. Add two scenarios to `Kenshou.Core.Selftest`: `selftest/kernel/correctness/outcome`, with knob `selftest.outcome` (text, default `passed`, one of the five outcome names) and knob `selftest.sleep-seconds` (double, default 0, range 0 to 3600, used to test timeouts), which returns the requested outcome; and `selftest/kernel/correctness/known-defect`, which always fails with label `seeded-defect` and declares a `KnownDefect` whose reference is `mori://shinzui/keiro-runtime-kenshou/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results` and whose expected failures are `["seeded-defect"]`.

Write the protocol-ownership ADR in this milestone.

### Milestone 5 — Published JSON Schemas, golden fixtures and the self-test scenarios

Scope: freeze the contract and prove the environment and worker paths through real scenarios. At the end `just schemas-check` and `just selftest` pass, and the seven self-test scenarios are listed.

Create JSON Schema (draft 2020-12) files named `schemas/kenshou.<name>.v<N>.schema.json` for the document `kenshou.<name>/v<N>` (the naming EP-1 established with `schemas/kenshou.cohort-identity.v1.schema.json`; in the file names listed next, prefix each with `kenshou.`), with `$id` `urn:kenshou:schema:<name>:v<N>`: `run-spec.v1`, `run-result.v1`, `artifact-manifest.v1`, `scenario-list.v1`, `worker-init.v1`, `worker-message.v1`. Every object is closed (`additionalProperties: false`) except the opaque sections: `cohort`, `fingerprint.cell`, `summaries.*`, `environment.kafka`, `environment.telemetry`, `args`, `payload` and `batch` items. Enumerations are spelled out; `runId` has the UUIDv7 pattern `^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`; digests match `^[0-9a-f]{64}$`; `seed` is an integer from 0 to 9007199254740991; `run-result` requires `cohort` to be an object. `schemas/README.md` states the naming rule, the rule that a breaking change means a new `v<N+1>` file with the old one kept, and lists which plan owns which document so that EP-3 to EP-18 add theirs the same way.

Create golden fixtures in `kenshou-core/test/golden/`: `run-spec.minimal.json`, `run-spec.effective.json`, `run-spec.external.json`, `run-result.passed.json`, `run-result.known-defect.json`, `manifest.json`, `scenario-list.json`, `worker-messages.jsonl`. `Kenshou.Core.GoldenSpec` decodes each, re-encodes it and compares `canonicalEncode` of both. `Kenshou.Core.SchemaSpec` runs `check-jsonschema --schemafile <schema> <file>` over every golden file and over documents emitted by a fresh `always-pass` run in a temporary directory, and fails, rather than skips, when the tool is missing. Add `pkgs.check-jsonschema` to `haskellProject.extraDevPackages` in `flake.module.nix`.

Add `selftest/kernel/correctness/postgres-roundtrip` (tier `smoke`, placement `either`, revision 1; requires schemas kiroku, keiro and pgmq; supports `pg.durability` `fsync-off` (default) and `durable`, `pg.version` `18` only; knob `selftest.events`, int, default 3, range 1 to 1000, variants 1 and 100). It opens a kiroku store on `requirePostgres ctx` and appends `selftest.events` events to stream `selftest-<run-id>` with `appendToStream … NoStream`, reads them back and checks the count and versions (label `kiroku-roundtrip`); schedules one timer with `Keiro.Timer.scheduleTimerTx` inside `runTransaction` and finds it with `lookupTimer` (label `keiro-roundtrip`); creates the queue `selftest_q`, sends one message and reads it back with a 30-second visibility timeout (label `pgmq-roundtrip`); queries `pgmigrate`'s ledger and checks that exactly the components `kiroku`, `keiro` and `pgmq` are recorded (label `one-ledger`); and checks that `SHOW fsync` agrees with the dimension (label `durability-honoured`). It writes the counts under `putSummary ctx Verdicts "postgres-roundtrip"`. It passes when no label failed.

Add `selftest/kernel/concurrency/worker-echo` (tier `smoke`, placement `either`, no PostgreSQL, knob `selftest.messages`, int, default 1, range 1 to 1000) and the role `selftest/echo`, which sends `ready` and answers each `custom` message named `echo` with the same payload until `stop`. The scenario spawns one worker with `withWorker`, waits up to ten seconds for `ready`, sends the payloads `{"n": i}`, and fails with label `echo-mismatch`, `echo-timeout` or `worker-exit` when a reply differs, is late, or the child's exit code is not 0. It records the child's process id, which must differ from the harness's, in the summary.

Add `Justfile` recipes `selftest` (runs the five self-tests that must exit 0 — `always-pass`, `outcome`, `known-defect`, `postgres-roundtrip`, `worker-echo` — into a temporary output directory and checks each exit code, then checks that `always-fail` exits 1 and `errors` exits 4) and `schemas-check`, and call both from `verify`. Write the environments ADR and distil the Decision Log.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` inside the dev shell (`nix develop`, or `direnv allow` once). First confirm EP-1's state:

```bash
cabal build all
cabal run -v0 kenshou -- cohort show --json | jq '.schema? // keys'
ls docs/adr/profile.dhall cohort/active.project flake.module.nix Justfile
postgres --version
echo "17=$KENSHOU_PG17_BIN 18=$KENSHOU_PG18_BIN"
```

`postgres --version` must report major version 18. If the two variables are empty, export them from the dev shell: inside `perSystem` in `flake.module.nix`, add the two elements below to whatever list EP-1 already assigns to `haskellProject.extraDevPackages` (the first is the schema checker Milestone 5 needs; the second is a setup hook, a script the shell sources on entry). The file must stay git-tracked, because Nix flakes ignore untracked files. Re-enter the shell and confirm with `nix develop -c sh -c 'echo $KENSHOU_PG17_BIN'`; if the hook is not sourced by the house `mkDevShell`, export the same two variables from `.envrc` instead and record that in Surprises & Discoveries.

```nix
haskellProject.extraDevPackages = [
  # ...EP-1's entries stay here...
  pkgs.check-jsonschema
  (pkgs.makeSetupHook { name = "kenshou-pg-bins"; } (pkgs.writeText "kenshou-pg-bins.sh" ''
    export KENSHOU_PG17_BIN=${pkgs.postgresql_17}/bin
    export KENSHOU_PG18_BIN=${pkgs.postgresql_18}/bin
  ''))
];
```

Per milestone, build, format and test:

```bash
cabal build all
nix fmt
cabal test kenshou-core:tests kenshou-cli:tests
```

After Milestone 1:

```bash
cabal run -v0 kenshou -- list
cabal run -v0 kenshou -- list --json | jq -r '.schema, (.scenarios | length)'
```

```text
selftest/kernel/correctness/always-fail   smoke  either  Always reports failed.
selftest/kernel/correctness/always-pass   smoke  either  Always reports passed.
selftest/kernel/correctness/errors        smoke  either  Always throws.
kenshou.scenario-list/v1
3
```

After Milestone 2 (use the built binary directly when checking exit codes):

```bash
K=$(cabal list-bin kenshou)
$K run selftest/kernel/correctness/always-pass --seed 7 --print-spec | jq -r '.schema, .seed'
$K run selftest/kernel/correctness/always-pass --dim pg.version=17; echo "exit=$?"
$K run selftest/kernel/nope/always-pass; echo "exit=$?"
```

```text
kenshou.run-spec/v1
7
kenshou: dimension pg.version is not applicable to selftest/kernel/correctness/always-pass
exit=2
kenshou: invalid scenario identifier "selftest/kernel/nope/always-pass": unknown kind "nope"
exit=2
```

After Milestone 4 (identifiers and timings are illustrative):

```bash
$K run selftest/kernel/correctness/always-pass --out runs; echo "exit=$?"
$K run selftest/kernel/correctness/always-fail --out runs; echo "exit=$?"
$K run selftest/kernel/correctness/errors --out runs; echo "exit=$?"
$K run selftest/kernel/correctness/outcome --set selftest.outcome=inconclusive --out runs; echo "exit=$?"
$K run selftest/kernel/correctness/known-defect --out runs; echo "exit=$?"
$K run selftest/kernel/correctness/known-defect --strict-known-defects --out runs; echo "exit=$?"
```

```text
passed  selftest/kernel/correctness/always-pass  runs/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55
exit=0
failed  selftest/kernel/correctness/always-fail  runs/01997f3a-61d0-7c02-b1a9-52e07c4d9a13
exit=1
errored  selftest/kernel/correctness/errors  runs/01997f3a-6a4e-7f90-a3c1-0b9d5e2f7a68
exit=4
inconclusive  selftest/kernel/correctness/outcome  runs/01997f3a-7102-7b3d-9e55-7c1a3d8f2b04
exit=3
failed (known defect, non-blocking)  selftest/kernel/correctness/known-defect  runs/01997f3a-7b9c-7a11-8d20-4e6f1a2b3c4d
exit=0
failed (known defect, non-blocking)  selftest/kernel/correctness/known-defect  runs/01997f3a-8333-7e6a-b0f4-9a8b7c6d5e4f
exit=1
```

After Milestone 5:

```bash
$K run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=durable --seed 7 --out runs --json \
  | jq '{outcome, fsync: .fingerprint.postgres.settings.fsync, verdict: .summaries.verdicts["postgres-roundtrip"]}'
$K run selftest/kernel/concurrency/worker-echo --out runs; echo "exit=$?"
just schemas-check
just selftest
```

```text
{
  "outcome": "passed",
  "fsync": "on",
  "verdict": {"kirokuEvents": 3, "keiroTimers": 1, "pgmqMessages": 1, "ledgerComponents": ["keiro", "kiroku", "pgmq"]}
}
passed  selftest/kernel/concurrency/worker-echo  runs/01997f3b-02aa-7c4f-8b61-2d3e4f5a6b7c
exit=0
```

Commit after each milestone with a Conventional Commits message and the three trailers, for example:

```text
feat(core): add scenario model, registry and kenshou list

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `kenshou list` prints the three scenarios sorted by identifier; `kenshou list 'selftest/*/correctness/*' --max-tier smoke --json` validates against the scenario-list schema once it exists; `kenshou list --bogus` exits 2 and `kenshou --help` exits 0; and the unit tests show that `parseScenarioId` and `renderScenarioId` round-trip for generated identifiers, that identifiers with uppercase letters, three segments or an unknown layer or kind are rejected, that selectors match as described, and that `mkRegistry` reports each rule violation listed in Milestone 1 (one test per rule, each built from a deliberately broken bundle).

Milestone 2 is accepted when `--print-spec` emits a document in which every declared knob and every applicable dimension is explicit; when an unknown knob, a value outside its range, a wrong type, an unsupported dimension value, a bad seed or a run id that is not a UUIDv7 each exit 2 with a message naming the offender; and when property tests show that resolving is idempotent (resolving an effective spec yields the same effective spec) and that the JSON codecs round-trip.

Milestone 3 is accepted when the integration tests show, against real servers: `SHOW fsync` is `off` under `fsync-off` and `on` under `durable`; after migration the schemas `kiroku`, `keiro`, `pgmq` and `pgmigrate` exist in the run database and in a database returned by `newDatabase`; requesting only `SchemaPgmq` leaves no `kiroku` schema; `restartServer` keeps the connection string working; with `KENSHOU_PG17_BIN` set, a kiroku-plus-pgmq environment reports `server_version_num` between 170000 and 179999 (the test is pending, with a message, when the variable is unset); an external run against a second ephemeral server creates and then drops its databases, and fails with an `EnvError` when the server's `fsync` contradicts the dimension. The worker tests show that `kenshou worker --role selftest/echo` echoes a payload, that a stray `putStrLn` in the role reaches standard error rather than the channel, that closing the child's standard input ends it within three seconds with code 75, and that an unknown role exits 2.

Milestone 4 is accepted by the exit-code transcript in Concrete Steps, and by these checks on a run directory: it contains `run-spec.json`, `run-result.json`, `manifest.json` and `logs/`; `verifyManifest` succeeds, and fails naming the file after one byte of `run-result.json` is changed; `run-result.json` has a `cohort` object equal to `kenshou cohort show --json`; running with `--run-id` of an existing directory exits 2 and leaves that directory untouched; `selftest.sleep-seconds=5 --timeout 1` yields `errored` with reason `timeout after 1 s`; a spec whose `cohortExpectation.planHash` is wrong yields `infrastructure-failure` with reason `cohort-mismatch`; a connection string containing `password=hunter2` appears nowhere in the run directory. A hedgehog property shows that changing any knob value, any dimension value, the phases, the machine profile, the scenario revision or a schema name changes `comparisonKey`, that changing only the plan hash changes `seriesKey` and not `comparisonKey`, and that `compatibleExcept [CfDimension DimTracing]` accepts two inputs differing only in `telemetry.tracing`.

Milestone 5 is accepted when `just schemas-check` validates every golden file and freshly emitted document; the golden round-trip tests pass; `kenshou list` shows seven scenarios; `postgres-roundtrip` passes in both durability modes and its result shows the matching `fsync` value; `worker-echo` passes and records a child process id different from the harness's; and `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce` passes with the two new records.

The plan as a whole is accepted when `just verify` is green and a second person can follow only this document's Purpose paragraph to produce and inspect a run directory.


## Idempotence and Recovery

Every step is additive and can be repeated. `cabal build` and the tests have no side effects outside `dist-newstyle/`, the ephemeral-pg cache under `~/.cache/ephemeral-pg` (one entry per distinct settings combination; remove stale ones by deleting that directory), `/tmp/ephpg-kenshou-<uid>` and whatever `--out` names. A run never reuses a directory, so re-running a command produces a new run id beside the old one; delete `runs/` freely, it is ignored by git.

If a run is killed, the next ephemeral start sweeps the orphaned server from `/tmp/ephpg-kenshou-<uid>`; to clean by hand, run `pkill -u "$USER" -f ephpg-kenshou` and remove that directory. Worker children exit on their own when their standard input closes. A killed run leaves a directory without `manifest.json`; it is incomplete by definition and safe to delete. In external mode a killed run can leave `kenshou_<prefix>` databases behind; list them with `psql "$KENSHOU_PG_URL" -Atc "select datname from pg_database where datname like 'kenshou\_%'"` and drop them with `DROP DATABASE … WITH (FORCE)`.

If a milestone is half finished, the Progress list says which modules exist; every module is independently compilable in the order given, so resume at the first unchecked item. If EP-1's `CohortIdentity` differs from what this plan assumes, record the difference in Surprises & Discoveries and adapt the import only. If a schema has to change after another plan has started consuming it, update the MasterPlan's Integration Point 5 first, then add a `v2` schema beside `v1` rather than editing `v1`.


## Interfaces and Dependencies

Libraries, all from the cohort EP-1 pins (bounds follow the runtime's own cabal files): `base >=4.21 && <5`, `aeson >=2.2 && <2.3`, `bytestring`, `containers`, `text >=2.1 && <2.2`, `time`, `directory`, `filepath`, `unix >=2.8 && <2.9` (signals, user id), `process` and `typed-process >=0.2.12 && <0.3` (workers), `async`, `stm`, `uuid >=1.3 && <1.4` and `mmzk-typeid >=0.7 && <0.8` (`Data.UUID.V7`), `splitmix` and `random >=1.2.1 && <1.4`, `cryptohash-sha256 >=0.11.102 && <0.12` and `base16-bytestring`, `optparse-applicative >=0.19 && <0.20`, `ephemeral-pg >=0.3.1 && <0.4`, `pg-migrate ^>=1.1.0.0`, `hasql >=1.10 && <1.11`, `hasql-pool`, `kiroku-store-migrations`, `keiro-migrations`, `pgmq-migration`, and, for the self-tests only, `kiroku-store >=0.8 && <0.9`, `keiro ^>=0.17.0.0`, `hasql-transaction`, `pgmq-core` and `pgmq-hasql` (0.6.1 family). Tests use `hspec >=2.11 && <2.12`, `hedgehog >=1.4 && <1.8`, `hspec-hedgehog >=0.0 && <0.4` and `temporary`. The dev shell gains `check-jsonschema`. Take exact versions from `cohort/released.project`; do not loosen EP-1's constraints.

At the end of Milestone 1 these modules exist in `kenshou-core`: `Kenshou.Core.Id`, `.Outcome`, `.Selector`, `.Scenario`, `.Bundle`, `.Cli`, `.Version`, `.Selftest` (with type-only versions of `.Phase`, `.Knob`, `.Dimension`, `.Env`, `.RunSpec`, `.Context`, `.Role`), and in `kenshou-cli`: `Kenshou.Cli.Registry` (`bundles`, `commands`), `Kenshou.Cli.Main`, `Kenshou.Cli.Command.List`, `Kenshou.Cli.Command.Cohort`. At the end of Milestone 2: `Kenshou.Core.Phase`, `.Knob`, `.Dimension`, `.Env`, `.RunSpec`, `.RunSpec.Resolve` complete, and `Kenshou.Cli.Command.Run` with `--print-spec`. At the end of Milestone 3: `Kenshou.Core.Env.Migration`, `.Env.Postgres`, `.Role`, `.Role.Dispatch`, `.Role.Spawn`, and `Kenshou.Cli.Command.Worker`. At the end of Milestone 4: `Kenshou.Core.Log`, `.Context`, `.Fingerprint`, `.Canonical`, `.Compat`, `.RunResult`, `.Manifest`, `.Run`. At the end of Milestone 5: `schemas/`, the golden fixtures, and the seven self-test scenarios. The signatures are those given in Plan of Work.

What other plans consume. EP-3 uses `Registry`, `selectScenarios`, `ScenarioSelector`, `KnobSpec.variants`, `DimensionSupport`, `resolveRunSpec`, `EffectiveRunSpec` and its JSON form (a run plan is a list of them), `executeRun` or the `kenshou run --spec` command, `worstOutcome`, the completeness rule for run directories, and `CliCommand` for `plan` and `execute`. EP-4 uses `RunContext` (`withPhase`, `putSummary Measurements`, `artifactPath SamplesDir` and `SeriesDir`, `genFor`, `observe`), `ComparisonMembership`, `compatibleExcept`, `PostgresEnv.connectionString` for its samplers, and `CliCommand` for `compare` and `summarize`. EP-5 uses `WorkerRole`, the message types, `withWorker` as its spawn primitive, `ServerControl`, `PostgresEnv.adminConnectionString`, `putSummary Verdicts` and `artifactPath VerdictsDir`. EP-6 uses `putSummary Diagnosis`, `artifactPath DiagnosisDir` and `CliCommand`. EP-7 uses `Dimensions.tracing` and `.metrics`, `EnvironmentSpec.telemetry`, `putSummary Telemetry` and `compatibleExcept`. Every coverage plan (EP-8 to EP-15) uses `Scenario`, `LayerBundle`, `KnobSpec`, `DimensionSupport`, `EnvRequirements`, `RunContext`, `requirePostgres`, `newDatabase`, `KnownDefect`, and registers with one import, one `bundles` element and one `build-depends` line. EP-11 defines the content of `EnvironmentSpec.kafka` and reads `EnvRequirements.kafka`. EP-16 and EP-17 rely on the run-directory layout, `manifest.json`, `--cohort-identity`, `--cell-fingerprint`, `--pg-url-env`, `--placement cell` and the exit codes. EP-18 reads `run-result.json` and `manifest.json` and uses `verifyManifest`. Toolkits that add `selftest` scenarios export their own `LayerBundle` with `layer = Selftest`, using their toolkit name as the component segment (`measure`, `check`, `diagnose`, `telemetry`).
