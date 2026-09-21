---
id: 1
slug: bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort
title: "Bootstrap the kenshou repository and pin the runtime cohort"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T21:08:38Z
      mode: "update"
      note: "Adopted relevant Haskell Jitsurei CLI patterns and the bounded Settei configuration contract."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T02:35:53Z
      mode: "implement"
      note: "Implemented EP-1 milestones and maintained living plan evidence."
---

# Bootstrap the kenshou repository and pin the runtime cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today `keiro-runtime-kenshou` holds a README, a project manifest and nineteen plan documents, and nothing that compiles. After this plan a contributor can clone the repository, run `nix develop`, and land in a shell with GHC 9.12.4, cabal 3.16, PostgreSQL 18 on the `PATH`, PostgreSQL 17 reachable through an environment variable, librdkafka, formatters and git hooks. From that shell `cabal build all` builds two small packages against an exactly pinned set of runtime libraries, and `cabal run kenshou -- cohort show --json` prints which version (or which git commit) of every runtime component the dependency solver actually chose, together with a hash of that choice. `kenshou --version` prints the Cabal package version and the build's short Git revision for both local Cabal builds and Nix builds, so a captured command transcript identifies the harness itself as well as its runtime cohort. `just use-cohort head` switches the whole build from "what services get from Hackage today" to "the same, with chosen components replaced by unreleased git commits", and `just use-cohort released` switches back.

The second thing a contributor gains is proof that the verification suite is possible at all. One test suite, `kenshou-linkproof`, depends on every runtime package at once (keiro and its family, kiroku, shibuya and its three adapters, the Kafka client stack, the PGMQ client family), starts a throwaway PostgreSQL, migrates the kiroku, keiro and PGMQ schemas through one migration ledger, appends an event, sends and reads a queue message, and creates a Kafka producer handle. If that suite is green, one build plan can link the whole runtime including the C library librdkafka, and every later plan can assume it.

Finally the repository gains its hygiene: a profile-governed bundle of Architecture Decision Records under `docs/adr/` with the first two decisions written down, a `mori.dhall` that names every runtime project this suite depends on, a README that describes the real layout, a `just verify` gate, and a GitHub Actions workflow that runs the build, the unit tests and the link-proof on every push.

This plan owns Integration Points 1 and 2 of `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`. It deliberately creates only the stub of `kenshou-core` (one module, `Kenshou.Core.Cohort`) and of `kenshou-cli` (one verb family, `kenshou cohort`). Everything else in those two packages belongs to `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`.


## Progress

Milestone 1 — Scaffold the repository, development shell and formatting hooks

- [x] (2026-09-21T02:35:34Z) Confirm the starting state (no `flake.nix`, no `cabal.project`, no `docs/adr/`) and that `seihou`, `nix`, `just`, `okf`, `dhall` and `mori` are on the `PATH`.
- [x] (2026-09-21T02:39:01Z) Add the `nix-haskell-flake` variables to `.seihou/config.dhall` and apply the module with `seihou run nix-haskell-flake`.
- [x] (2026-09-21T02:39:01Z) Write `flake.module.nix` (PostgreSQL 17 and 18 bin directories as environment variables, `dhall`, `git`, Linux-only `procps` and `lsof`, fourmolu from the `ghc9124` package set) and `git add` it together with `flake.lock`.
- [x] (2026-09-21T02:39:01Z) Write `cabal.project`, the placeholder `cohort/active.project` and `cohort/released.project`, and the skeleton `kenshou-core` package so that the package glob matches something.
- [x] (2026-09-21T02:39:01Z) Write the `Justfile` (meta, haskell, cohort, docs and database groups).
- [x] (2026-09-21T02:39:01Z) Enter `nix develop`, check tool versions and both PostgreSQL variables, run `cabal build all`, `nix fmt` and `just process-compose-check`.
- [ ] Commit.

Milestone 2 — Pin the released and head cohorts and print the resolved cohort identity

- [ ] Run `cabal update`, read the index ceiling it prints, and re-verify every cohort version against Hackage.
- [ ] Write the full `cohort/released.project` and `cohort/head.project`; re-resolve the head commits with `git ls-remote`.
- [ ] Write the descriptors `cohort/released.json` and `cohort/head.json` and the two JSON Schemas under `schemas/`.
- [ ] Implement `Kenshou.Core.Cohort` (descriptor, plan reader, identity, plan hash, consistency check) with `kenshou-core-test`.
- [ ] Create `kenshou-cli` with Git-aware `kenshou --version`, `kenshou cohort show` and `kenshou cohort check`, usage errors exiting 2, and `kenshou-cli-test`.
- [ ] Add the `use-cohort`, `cohort-show`, `cohort-check` and `cohort-assert-released` recipes; prove a switch to `head` and back changes the printed identity.
- [ ] Commit.

Milestone 3 — Prove the whole cohort links and migrates in one build

- [ ] Add the `kenshou-linkproof` test suite to `kenshou-cli/kenshou-cli.cabal` with a dependency on every runtime package.
- [ ] Write `kenshou-cli/linkproof/Main.hs` and `kenshou-cli/linkproof/LinkProof/Imports.hs`.
- [ ] Run it green on the released cohort; run it on the head cohort and record the outcome.
- [ ] Commit.

Milestone 4 — Adopt the ADR bundle, update mori.dhall and the README, add CI

- [ ] Draft the first ADR, run the `adopt-architecture-decisions` blueprint (or the manual fallback), allocate the second ADR with `okf id next`, and record the adopted `haskell-jitsurei` CLI interaction standard in the appropriate ADR before validating strictly.
- [ ] Extend `mori.dhall` (packages, dependencies, `okfBundles`, docs) and run `mori validate --check-deps` and `mori register`.
- [ ] Replace the README "Status" block with the layer-package layout.
- [ ] Add `.github/workflows/ci.yaml` and finish `just verify`.
- [ ] Run `just verify` from a clean clone; commit; update the MasterPlan's Progress and registry status.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The installed and upstream `nix-haskell-flake` module is 0.25.0, while the plan was drafted against 0.24.0 and Mori's cached template metadata still reports 0.14.0. Evidence: both `/Users/shinzui/.config/seihou/installed/nix-haskell-flake/module.dhall` and the Mori-located source at `/Users/shinzui/Keikaku/bokuno/seihou-modules/modules/haskell/nix-haskell-flake/module.dhall` declare `version = Some "0.25.0"`. Implementation follows 0.25.0's current variable and extension contracts.


## Decision Log

Record every decision made while working on the plan.

- Decision: Scaffold the Nix side with the Seihou module `nix-haskell-flake` 0.24.0 and hand-write the Haskell side; do not use the `haskell-cli-app` module.
  Rationale: `nix-haskell-flake` is what keiro, kiroku and shibuya use, so the toolchain locks byte-identically with theirs. `haskell-cli-app` would overwrite `README.md`, write a managed `cabal.project` that conflicts with the cohort import, default to tasty rather than hspec, and needs `project.name = kenshou` while the flake module needs `project.name = keiro-runtime-kenshou`.
  Date: 2026-09-20

- Decision: Select the cohort with a tracked one-line file `cohort/active.project` rewritten by `just use-cohort <name>`, and make that recipe delete `dist-newstyle/cache/config` and `dist-newstyle/cache/plan.json`.
  Rationale: Verified with cabal 3.16.1.0 while drafting: a nested relative `import:` resolves relative to the importing file, so `cabal.project` → `cohort/active.project` → `released.project` works; but cabal does not notice an edit to an imported file, and `touch cabal.project` does not help because cabal compares content. Deleting `dist-newstyle/cache/config` forces the project files to be re-read without discarding compiled objects.
  Date: 2026-09-20

- Decision: Each cohort file is self-contained; `head.project` does not import `released.project`.
  Rationale: cabal `constraints` accumulate and cannot be removed by a later file, so a head component whose version differs from the released pin would be unsatisfiable. Duplication is the honest cost of a cohort being a complete statement; `kenshou cohort check` catches drift.
  Date: 2026-09-20

- Decision: The released cohort pins `kiroku-store-migrations ==0.4.0.0` and the `pg-migrate` family `==1.1.0.0` although 0.5.0.0 and 1.2.0.0 are on Hackage.
  Rationale: `keiro-migrations` 0.17.0.0 bounds both (`^>=0.4.0.0`, `^>=1.1.0.0`) and `pgmq-migration` 0.6.1.0 bounds `pg-migrate ^>=1.1.0.0`. kiroku's changelog states 0.5.0.0 changes only the pg-migrate bound; migration payloads and checksums are identical. This is what a service resolves today.
  Date: 2026-09-20

- Decision: Pin `effectful` and `effectful-core` to 2.6.1.0.
  Rationale: keiro 0.17.0.0 (`>=2.6 && <2.7`) and `shibuya-kiroku-adapter` 0.5.1.2 (`effectful-core >=2.5 && <2.7`) forbid 2.7 even though shibuya-core, pgmq-effectful and the Kafka packages admit it.
  Date: 2026-09-20

- Decision: Pin `ephemeral-pg ==0.3.1.0` and carry one package-qualified `allow-newer: keiro-test-support:ephemeral-pg`.
  Rationale: The solver rejected the cohort without it: the published `keiro-test-support` 0.17.0.0 declares `ephemeral-pg >=0.2 && <0.3` (tag `keiro-0.17.0.0` and the Hackage cabal file agree; the `>=0.3.1` bound exists only in unreleased keiro commit `9fb54d56`). ephemeral-pg is harness infrastructure, not runtime under test. The only breaking change in 0.3.0.0 is a new `Config` field, and the released fixture passes `defaultConfig` through unchanged; every symbol it uses exists at tag `v0.3.1.0`. The 0.3 line adds the stale-cluster sweep and exports `withCachedConfig`, which a harness that kills processes needs. The link-proof is the evidence that discharges the entry, following `mori://shinzui/rei/okf/adrs/concepts/ADR-16`. Remove it when keiro releases the new bound.
  Date: 2026-09-20

- Decision: `index-state` is `2026-09-20T13:44:47Z`, the index ceiling observed while drafting, not a rounded time.
  Rationale: A dry-run with `2026-09-20T14:00:00Z` failed with cabal error Cabal-7159 because the index did not reach it. 13:44:47Z is the upload time of `shibuya-metrics` 0.9.0.3, the newest cohort member, and the solver confirmed that version resolves at that state. `mori://shinzui/rei/okf/adrs/concepts/ADR-18` states the same rule.
  Date: 2026-09-20

- Decision: In the released cohort `hw-kafka-client` is Hackage 5.3.0; in the head cohort it is the house fork at commit `6caed636898a78e9f6e5a9c93eeb5562cbb2580a`.
  Rationale: "Released" means what a service gets with no extra pins; `shibuya-kafka-adapter` and `kafka-effectful` do not pass their fork pin on to dependents. The fork fixes consumer fatal-error blindness and a message leak, which is exactly the kind of difference the two cohorts exist to expose. Integration Point 2 makes this a cohort property, not a scenario knob.
  Date: 2026-09-20

- Decision: The head cohort replaces only shibuya (`shibuya-core`, `shibuya-metrics`) and `hw-kafka-client` for now.
  Rationale: Those are the two components with known unreleased fixes. keiro's master still bounds `kiroku-store-migrations ^>=0.4.0.0`, so moving kiroku or keiro to git would need more `allow-newer`. The plan documents how to add a component later.
  Date: 2026-09-20

- Decision: The link-proof is a dedicated test suite `kenshou-linkproof` inside `kenshou-cli`, not part of `kenshou-core-test`.
  Rationale: `kenshou-cli` is the one package allowed to depend on everything; keeping the runtime closure out of `kenshou-core`'s test dependencies keeps the kernel's unit tests fast.
  Date: 2026-09-20

- Decision: Add the document name `kenshou.cohort-identity/v1` for the output of `kenshou cohort show --json`, and add `kenshou cohort check`.
  Rationale: The MasterPlan names `kenshou.cohort/v1` for descriptors but gives the resolved identity no schema name, while Integration Point 5 requires every document to carry one. `cohort check` compares the descriptor with the solver's plan, which is the only guard against the two hand-maintained sources (`*.project` and `*.json`) drifting and against the stale plan cache described above.
  Date: 2026-09-20

- Decision: Expose PostgreSQL binaries as `KENSHOU_PG17_BIN` and `KENSHOU_PG18_BIN`, exported by a Nix setup hook in `flake.module.nix`; keep PostgreSQL 18 as the one on `PATH`.
  Rationale: `pg.version` is a run-time dimension, so one process must reach both majors; kiroku's one-shell-per-major approach does not fit. Environment variables are trivial for Haskell, CI and a GCP cell to supply.
  Date: 2026-09-20

- Decision: `okf` is not added to the dev shell; `dhall` is.
  Rationale: `okf` is not in nixpkgs, and a new flake input means editing the Seihou-managed `flake.nix`. Locally `okf` comes from the owner's Nix profile; CI uses `nix shell github:shinzui/okf/v0.9.0.0#okf-cli`.
  Date: 2026-09-20

- Decision: Leave `nix.redpanda` and `nix.haskell-nix` false.
  Rationale: The private Redpanda scripts belong to the broker fixture plan (`docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md`) and Nix-built payloads to `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`; both can turn the variable on later with `seihou run nix-haskell-flake --var …`.
  Date: 2026-09-20

- Decision: Establish `kenshou --version` in the bootstrap plan with the Git-aware dual path from `mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`: `githash` reads `.git` in local Cabal builds and `flake.module.nix` injects `GIT_HASH` for Nix builds where `.git` is absent.
  Rationale: EP-1 already owns the executable skeleton and Nix build. Later run results record a full harness revision, but operators and scripts need the executable to identify itself before any run exists. Keeping the version implementation in one module also gives EP-2's final parser a value to expose without duplicating build logic.
  Date: 2026-09-20

- Decision: Reserve Settei 0.2.0.0 as the harness configuration family that EP-2 adds, without putting it in the runtime cohort descriptors.
  Rationale: `settei`, `settei-env`, `settei-optparse-applicative`, and `settei-yaml` configure the harness executable, not the runtime under test. Mixing them into the cohort identity would make an operator-interface dependency look like a runtime comparison axis.
  Date: 2026-09-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 produced the locked Nix shell and the first buildable `kenshou-core` package. The shell reports GHC 9.12.4, cabal 3.16.1.0, PostgreSQL 18.6 on `PATH`, PostgreSQL 17.11 through `KENSHOU_PG17_BIN`, and librdkafka 2.15.0; `cabal build all`, a second `nix fmt -- --fail-on-change`, and `just process-compose-check` all pass. The generated commit hook also rejected a real commit attempt whose subject contained a literal `\n` escape.


## Context and Orientation

This section assumes you know nothing about the repository or the runtime.

The repository today. `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` (GitHub `shinzui/keiro-runtime-kenshou`, private, branch `master`) contains `README.md`, `mori.dhall` (the project manifest read by the house registry tool `mori`), `mina.kdl`, `.seihou/` (state of the scaffolding tool, see below), `agents/skills/` (the ExecPlan and MasterPlan skills), `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` and `docs/plans/1…19-*.md`. There is no Haskell code, no `flake.nix`, no `cabal.project`, no `Justfile`, no CI and no `docs/adr/`. This plan has no dependency on any other plan. Check the starting state with `ls` and `git status --short` before you begin; if `flake.nix` or `cabal.project` already exists, read Idempotence and Recovery first.

What is being verified. The "keiro runtime" is a set of Haskell libraries that services link together. `pgmq-hs` is a client for PGMQ, a message queue built from PostgreSQL tables. `kiroku` is an event store: an append-only log of events in PostgreSQL, grouped into streams. `shibuya` is a message-processing framework with adapters that feed it from PGMQ, from kiroku and from Kafka. `keiro` sits on top and provides command processing, process managers, routers, workflows, timers, an inbox, an outbox and a job queue. `keiki` is the pure state-machine library keiro uses. `pg-migrate` applies database migrations: each library ships a migration component, an application composes components into a plan, and applied migrations are recorded in a ledger table (`pgmigrate.migrations`, with a `component` column); all components of one database must share one ledger. `ephemeral-pg` starts a throwaway PostgreSQL server for tests using the `initdb` and `postgres` binaries it finds on the `PATH`. Kafka access goes through `kafka-effectful`, `hw-kafka-streamly` and `hw-kafka-client`, the last of which binds the C library librdkafka.

Where those libraries live. All are read-only for you. `mori://shinzui/keiro` at `/Users/shinzui/Keikaku/bokuno/keiro`; `mori://shinzui/keiki` at `/Users/shinzui/Keikaku/bokuno/keiki`; `mori://shinzui/kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (it also holds `shibuya-kiroku-adapter`, `kiroku-otel`, `kiroku-metrics`, `kiroku-cli`); `mori://shinzui/shibuya` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; `mori://shinzui/shibuya-pgmq-adapter` and `mori://shinzui/shibuya-kafka-adapter` beside it; `mori://shinzui/kafka-effectful` at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`; `mori://shinzui/hw-kafka-streamly` at `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`; the fork `mori://shinzui/hw-kafka-client` at `/Users/shinzui/Keikaku/bokuno/hw-kafka-client` (upstream is `mori://haskell-works/hw-kafka-client`); `mori://shinzui/pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`; `mori://shinzui/pg-migrate` at `/Users/shinzui/Keikaku/bokuno/pg-migrate`; `mori://shinzui/ephemeral-pg` at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`. Locate any other dependency with `mori registry show <project> --full`; never search `/nix/store` or `/`. A warning learned while drafting: these checkouts are ahead of their releases (keiro's master is more than thirty commits past tag `keiro-0.17.0.0`), so read released metadata with `git show <tag>:<path>` or from Hackage, never from the working tree.

Build vocabulary. Hackage is the public Haskell package index. A cabal project is a directory with a `cabal.project` file naming local packages and solver settings. The solver picks one version of every dependency; its result is written to `dist-newstyle/cache/plan.json`, whose `install-plan` array has one unit per package component with `pkg-name`, `pkg-version`, `style` (`local` for this repository's packages) and `pkg-src` (`repo-tar` for Hackage with `pkg-src-sha256`, `source-repo` with `location`, `tag`, `subdir` for git, `local` with a path; boot libraries shipped with GHC have `type: pre-existing` and no `pkg-src`). `index-state` freezes Hackage at a timestamp so the solver's answer is repeatable. `constraints` force exact versions. A `source-repository-package` stanza makes cabal build a package from a git commit instead of Hackage. `allow-newer: a:b` tells the solver to ignore package `a`'s upper bound on `b`. A cohort, in house vocabulary, is the exact set of runtime package versions one build links.

Tooling vocabulary. A Nix flake (`flake.nix` plus `flake.lock`) describes a reproducible development shell entered with `nix develop`. Seihou (`mori://shinzui/seihou`) is the house scaffolding tool: a module is a set of templates applied with `seihou run <module>`; a blueprint is an agent-driven procedure run with `seihou agent run <blueprint>`; variables live in `.seihou/config.dhall` and applied state in `.seihou/manifest.json`; files a module generates are "managed" and must not be hand-edited. The module `nix-haskell-flake` 0.24.0 (`mori://shinzui/seihou-modules`, `/Users/shinzui/Keikaku/bokuno/seihou-modules/modules/haskell/nix-haskell-flake`) generates `flake.nix` (a thin flake-parts flake whose only real input is a revision-pinned `github:shinzui/haskell-nix-dev/206ecd25bcb4a07581210bdae3e6f43c8fd179d8`, which supplies GHC 9.12.4, cabal 3.16.1.0 and the language server), `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`, `flake.lock`, `fourmolu.yaml`, `process-compose.yaml`, `.envrc`, `flake.module.nix.example` and `.gitignore` lines. It does not generate a `Justfile`, a `cabal.project` or CI. Your own customisations go in the unmanaged `flake.module.nix`, which must be tracked by git or Nix ignores it. treefmt runs the formatters behind `nix fmt`: fourmolu for Haskell, cabal-gild for `.cabal` and `cabal.project` files, nixpkgs-fmt for Nix. pre-commit installs git hooks that run treefmt and reject a literal `\n` in a commit message. process-compose starts local services from `process-compose.yaml`; the generated one runs a Unix-socket PostgreSQL in `./db` and calls `just create-database`. `just` is a command runner that reads `Justfile`.

Documentation vocabulary. OKF (Open Knowledge Format) is a directory of Markdown files with YAML frontmatter, validated by the `okf` CLI (v0.9.0.0 here). A profile is a Dhall descriptor saying which concept types and fields a bundle may hold. An ADR (Architecture Decision Record) is one durable decision per file. The shared profile `documentation.architectureDecisions` from `mori://shinzui/okf-profiles` requires frontmatter `type: Architecture Decision Record`, `title`, `description`, `timestamp`, `generated` (with `by` and `at`), `docId: ADR-N` (unpadded, unique), `status` and `date`; `index.md` and `log.md` are reserved files. Registering the bundle in `mori.dhall` as `adrs` makes a record citable as `mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-N`.

What was verified while drafting (2026-09-20). Every version below was checked against `https://hackage.haskell.org/package/<p>/preferred`. More importantly, a scratch project carrying exactly the `cohort/released.project` shown in Milestone 2 and a package depending on the whole list was resolved with `cabal build all --dry-run` under GHC 9.12.4 and cabal 3.16.1.0: it produced a 347-unit plan, every unit from Hackage, with passengers aeson 2.2.5.1, hasql 1.10.3.7, hasql-pool 1.4.2.3, hasql-transaction 1.2.3.1, streamly 0.11.1, nqe 0.6.6, optparse-applicative 0.19.0.0, hspec 2.11.17, hedgehog 1.7 and c2hs 0.28.8. The same project switched to the head cohort resolved `shibuya-core` and `shibuya-metrics` from `https://github.com/shinzui/shibuya.git` at `a26d60609f118f8ca5357c6c16f02317e10fb819` and `hw-kafka-client` from the fork. These are solver results only: nothing was compiled, and whether Hackage `keiro-pgmq` compiles against unreleased shibuya is unknown until Milestone 3. The shibuya checkout on disk also has commits not yet pushed; a head cohort may only name commits that `git ls-remote` shows on GitHub. `kiroku-cli` is linked by `kiroku-metrics`, so it is part of the cohort. kenshou does not depend on `pg-migrate-test-support`, so the `allow-newer` for it that keiro carries is not needed here.

Contracts this plan owns (restated from the MasterPlan). Integration Point 1: one cabal project whose `cabal.project` lists packages with the glob `kenshou-*/*.cabal`, so later plans add a package by creating a directory and never edit the list; every module lives under `Kenshou`; layer packages (`kenshou-pgmq`, `kenshou-kiroku`, `kenshou-shibuya`, `kenshou-kafka`, `kenshou-keiro`) depend on the kernel and toolkits and never on one another; only `kenshou-runtime` and `kenshou-cli` may depend on layer packages. Integration Point 2: `cohort/released.project` pins Hackage versions with `index-state` and exact `constraints`; `cohort/head.project` uses `source-repository-package` stanzas with `https://github.com/shinzui/...` locations and immutable commit hashes, never `file://`; `cohort/active.project` is the one-line selector; `cohort/<name>.json` is a machine-readable descriptor mapping each component to its `mori://` URI, packages and version or commit; `kenshou cohort show --json` prints the `CohortIdentity` resolved by the solver plus a plan hash. Later plans embed that identity in every run result, diff two descriptors to decide what changed, ship it to GCP cells and write it into evidence records. From Integration Point 6 this plan relies on the exit codes: 0 success, 1 failed, 2 usage error, 3 inconclusive, 4 errored. From Integration Point 5: every JSON document has a `schema` field of the form `kenshou.<name>/v<N>` and a JSON Schema in `schemas/`; this plan uses the file naming `schemas/kenshou.<name>.v<N>.schema.json`.

ADR context. There is no local ADR corpus yet; this plan creates `docs/adr/`. Cross-repository decisions that shape it: `mori://shinzui/jinmyaku/okf/adrs/concepts/ADR-1` pins a runtime cohort to published releases, permits source pins only with a written argument, and requires an exact commit verified reachable on the public remote. `mori://shinzui/jinmyaku/okf/adrs/concepts/ADR-12` treats published artifacts as authoritative over documentation, which the ephemeral-pg finding above illustrates. `mori://shinzui/rei/okf/adrs/concepts/ADR-16` makes a package-qualified `allow-newer` the last remedy and demands the lifted bound, why the breakage does not reach the consumer, and the evidence run be written beside the entry; a blanket `allow-newer` is never allowed. `mori://shinzui/rei/okf/adrs/concepts/ADR-18` says an `index-state` must be a timestamp the index reaches and that resolved plans should be diffed across a bump to record passengers. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact URI is pending: the record is `mori://shinzui/shibuya` at `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`, whose candidate manifest (exact commits, package versions, solver plan hash, compiler, platform) is the precedent for `CohortIdentity`. The descriptor format is modelled on `config/dependency-releases.json` in `mori://shinzui/danwa` (`/Users/shinzui/Keikaku/bokuno/danwa`), and the pinning style on `/Users/shinzui/Keikaku/bokuno/kotei/cabal.project` (`mori://shinzui/kotei`), minus its `file://` pins. This plan writes two new ADRs: layer packages never import one another; and every result carries a resolved cohort identity, with released and head cohorts both first-class.


## Plan of Work

### Milestone 1 — Scaffold the repository, development shell and formatting hooks

Scope: everything needed for `nix develop` and `cabal build all` to succeed on a trivial package. At the end the repository has a locked flake, a dev shell, formatters, git hooks, a `Justfile`, a `cabal.project` that imports a cohort file, and a skeleton `kenshou-core`. Acceptance is tool versions printed from inside the shell, both PostgreSQL variables set, a successful build and a clean `nix fmt`.

Edit `.seihou/config.dhall` to add, beside the existing `git.repoName`, the keys `project.name = "keiro-runtime-kenshou"`, `project.description = "Verification evidence for the Keiro runtime"`, `nix.postgresql = "true"` and `nix.process-compose = "true"`. Both artifacts are already installed on the owner's machine (`seihou list` shows them); on another machine run `seihou install https://github.com/shinzui/seihou-modules.git --module nix-haskell-flake` first. Apply the module with the variable overrides shown in Concrete Steps: `nix.pg-package=postgresql_18`, `nix.pg-database=kenshou` (a hyphenated database name is invalid unquoted), `nix.kafka=true` (adds `rdkafka` and exports `CPATH`, `LIBRARY_PATH`, `PKG_CONFIG_PATH`), `nix.builtin-package=false` (there is no root package for `callCabal2nix`), `nix.redpanda=false`, `nix.haskell-nix=false`, and the fourmolu extension list. The module already puts `just`, `jq`, `pkg-config`, `zlib`, `process-compose`, PostgreSQL 18 with its `.dev` output and `openssl.dev` in the shell, so `flake.module.nix` adds only what is missing.

Create `flake.module.nix`:

```nix
# Unmanaged, project-specific flake-parts module. MUST be git-tracked, or the
# pathExists guard in flake.nix treats it as absent.
{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
      # pg.version is a run-time dimension, so one shell must reach both majors.
      # PostgreSQL 18 stays on PATH (keiro requires it); both bin directories are
      # exported for Kenshou.Core.Env.Postgres (docs/plans/2-…) to choose from.
      pgEnvHook = pkgs.makeSetupHook { name = "kenshou-pg-env"; }
        (pkgs.writeText "kenshou-pg-env.sh" ''
          export KENSHOU_PG17_BIN="${pkgs.postgresql_17}/bin"
          export KENSHOU_PG18_BIN="${pkgs.postgresql_18}/bin"
        '');
    in
    {
      haskellProject.extraDevPackages =
        [ pkgs.git pkgs.dhall pkgs.dhall-json pgEnvHook ]
        # ephemeral-pg inspects processes with ps and lsof; macOS ships both.
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.procps pkgs.lsof ];

      treefmt.programs.fourmolu.package = pkgs.haskell.packages.ghc9124.fourmolu;
    };
}
```

The base flake builds the shell with `pkgs.mkShell { nativeBuildInputs = … ++ extraNativeBuildInputs; }`, and a derivation made by `makeSetupHook` has its script sourced when the shell environment is assembled, the same way nixpkgs' `cacert` exports `NIX_SSL_CERT_FILE`. If the variables are nevertheless empty inside `nix develop`, replace the hook with `pkgs.writeShellScriptBin "kenshou-pg-bin"` printing the bin directory for an argument of `17` or `18`, record the change in the Decision Log, and tell the owner of `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`.

Create `cabal.project`:

```text
-- One cabal project. A plan adds a package by creating
-- kenshou-<name>/kenshou-<name>.cabal; nobody edits this list.
-- The cohort (index-state, exact constraints, git pins) comes from cohort/.
-- Switch with `just use-cohort <name>`, never by editing cohort/active.project
-- alone: cabal does not notice changes to imported files.
import: cohort/active.project

with-compiler: ghc-9.12.4

packages: kenshou-*/*.cabal

tests: True
test-show-details: direct
```

In this milestone `cohort/active.project` is the single line `import: released.project` and `cohort/released.project` holds only `index-state: 2026-09-20T13:44:47Z`; Milestone 2 fills it. Create `kenshou-core/kenshou-core.cabal` in the house style: `cabal-version: 3.0`, version `0.1.0.0`, `license: BSD-3-Clause` with no `license-file`, author Nadeem Bitar, `tested-with: ghc >=9.12 && <9.13`, a `common warnings` stanza (`-Wall -Wcompat -Widentities -Wincomplete-record-updates -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints`), `default-language: GHC2024`, default extensions `BlockArguments DuplicateRecordFields ImportQualifiedPost NoFieldSelectors OverloadedLabels OverloadedRecordDot OverloadedStrings`, a library exposing `Kenshou.Core.Cohort` from `src`, and a test suite `kenshou-core-test` (`type: exitcode-stdio-1.0`, `hs-source-dirs: test`, `main-is: Main.hs`, hspec). For now the module exports only `newtype CohortName = CohortName Text` and the test asserts one trivial property, so the milestone builds.

Create `Justfile` with `set shell := ["zsh", "-cu"]` and these groups, modelled on `/Users/shinzui/Keikaku/bokuno/keiro/Justfile`. Meta: `default` (`just --list`) and `verify`. Haskell: `haskell-build` (`cabal build all`), `haskell-test` (`cabal test kenshou-core:tests kenshou-cli:test:kenshou-cli-test`; always use the `:tests` or explicit component form, because a bare package name runs a single suite), `link-proof`, `fmt` (`nix fmt`), `fmt-check` (`nix fmt -- --fail-on-change`). Database, copied from keiro with the database default `kenshou`: `postgres-init`, `postgres-start`, `postgres-stop`, `process-compose`, `process-compose-check` (`process-compose -f process-compose.yaml --dry-run`), `create-database db=pg_database`, `db-create`. The generated `process-compose.yaml` calls `just create-database`, so that recipe must exist. The cohort and docs groups arrive in later milestones.

### Milestone 2 — Pin the released and head cohorts and print the resolved cohort identity

Scope: the cohort files, their descriptors, the library that reads the solver's plan, and the first CLI verb. At the end `cabal run kenshou -- cohort show` prints the resolved identity, `cohort check` exits 0, and switching cohorts visibly changes both. Acceptance is the transcripts in Concrete Steps.

Start by running `cabal update` inside the shell and reading the index ceiling it prints. Keep `2026-09-20T13:44:47Z` unless a cohort member has been released since; if so, follow `mori://shinzui/rei/okf/adrs/concepts/ADR-18`: choose a timestamp at or below the ceiling and at or after the newest member's upload time (`curl -s https://hackage.haskell.org/package/<p>-<v>/upload-time`), never a rounded one, and note any passenger versions that move. Re-check each version with `curl -s -H 'Accept: application/json' https://hackage.haskell.org/package/<p>/preferred`. Then write `cohort/released.project`:

```text
-- RELEASED COHORT: what a service resolves from Hackage today.
-- Descriptor: cohort/released.json. Verified by dry-run on 2026-09-20.
index-state: 2026-09-20T13:44:47Z

constraints:
  keiro ==0.17.0.0,
  keiro-core ==0.17.0.0,
  keiro-pgmq ==0.17.0.0,
  keiro-migrations ==0.17.0.0,
  keiro-test-support ==0.17.0.0,
  keiki ==0.9.1.0,
  keiki-codec-json ==0.9.1.0,
  kiroku-store ==0.8.0.1,
  -- 0.5.0.0 exists; keiro-migrations 0.17.0.0 bounds ^>=0.4.0.0. Same payloads.
  kiroku-store-migrations ==0.4.0.0,
  kiroku-otel ==0.2.0.8,
  kiroku-metrics ==0.1.0.8,
  kiroku-cli ==0.2.0.6,
  shibuya-kiroku-adapter ==0.5.1.2,
  shibuya-core ==0.9.0.3,
  shibuya-metrics ==0.9.0.3,
  shibuya-pgmq-adapter ==0.16.0.0,
  shibuya-kafka-adapter ==0.9.0.1,
  kafka-effectful ==0.3.1.0,
  hw-kafka-client ==5.3.0,
  hw-kafka-streamly ==0.2.0.0,
  pgmq-core ==0.6.1.0,
  pgmq-hasql ==0.6.1.0,
  pgmq-effectful ==0.6.1.0,
  pgmq-config ==0.6.1.0,
  pgmq-migration ==0.6.1.0,
  -- 1.2.0.0 exists; keiro-migrations and pgmq-migration bound ^>=1.1.0.0.
  pg-migrate ==1.1.0.0,
  pg-migrate-embed ==1.1.0.0,
  pg-migrate-cli ==1.1.0.0,
  pg-migrate-import-codd ==1.1.0.0,
  pg-migrate-import-hasql-migration ==1.1.0.0,
  ephemeral-pg ==0.3.1.0,
  -- keiro and shibuya-kiroku-adapter forbid effectful 2.7.
  effectful ==2.6.1.0,
  effectful-core ==2.6.1.0,
  hs-opentelemetry-api ==1.0.0.0,
  hs-opentelemetry-sdk ==1.0.0.0,
  hs-opentelemetry-propagator-w3c ==1.0.0.0,
  hs-opentelemetry-exporter-in-memory ==1.0.0.0,
  hs-opentelemetry-exporter-otlp ==1.0.0.0,
  hs-opentelemetry-semantic-conventions ==1.40.0.0

-- Lifted bound: keiro-test-support 0.17.0.0 declares ephemeral-pg >=0.2 && <0.3.
-- Why it does not reach us: 0.3.0.0's only breaking change is a new Config field;
-- the released fixture passes defaultConfig through unchanged, and every symbol
-- it uses exists at ephemeral-pg tag v0.3.1.0.
-- Evidence: kenshou-linkproof starts the fixture and migrates three components.
-- Discharge: remove when keiro releases the bound in its commit 9fb54d56.
allow-newer:
  keiro-test-support:ephemeral-pg
```

`cohort/head.project` is a copy of that file with the banner changed to `HEAD COHORT` and two stanzas appended. The version constraints stay: both repositories still call themselves 0.9.0.3 and 5.3.0, so the pins act as a tripwire if upstream bumps a version. Before writing, run `git ls-remote https://github.com/shinzui/shibuya.git refs/heads/master` and use the commit it prints; never take a commit from the local checkout.

```text
-- shibuya master: unreleased lifecycle remediation (totalShutdownTimeout,
-- ProcessorFailure, duplicate-processor and concurrency validation).
source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya.git
  tag: a26d60609f118f8ca5357c6c16f02317e10fb819
  subdir:
    shibuya-core
    shibuya-metrics

-- hw-kafka-client fork: surfaces consumer fatal errors in async poll mode and
-- stops leaking polled messages. Upstream 5.3.0 has neither fix.
source-repository-package
  type: git
  location: https://github.com/shinzui/hw-kafka-client.git
  tag: 6caed636898a78e9f6e5a9c93eeb5562cbb2580a
```

To add another component to head later, append a stanza with an https location and a full commit hash, adjust or remove that component's version constraints if its version string changed, mirror it in `cohort/head.json`, and run `just use-cohort head && cabal build all --dry-run && just cohort-check`. A further cohort is simply another `cohort/<name>.project` and `cohort/<name>.json` pair.

Write the descriptors. The shape, shown abbreviated, is:

```json
{
  "schema": "kenshou.cohort/v1",
  "name": "released",
  "description": "What a service resolves from Hackage today.",
  "verifiedAt": "2026-09-20",
  "compiler": "ghc-9.12.4",
  "indexState": "2026-09-20T13:44:47Z",
  "projectFile": "cohort/released.project",
  "components": [
    {
      "id": "kiroku",
      "moriUri": "mori://shinzui/kiroku",
      "source": { "type": "hackage" },
      "packages": [
        { "name": "kiroku-store", "version": "0.8.0.1" },
        { "name": "kiroku-store-migrations", "version": "0.4.0.0" }
      ]
    },
    {
      "id": "shibuya",
      "moriUri": "mori://shinzui/shibuya",
      "source": {
        "type": "git",
        "location": "https://github.com/shinzui/shibuya.git",
        "rev": "a26d60609f118f8ca5357c6c16f02317e10fb819"
      },
      "packages": [
        { "name": "shibuya-core", "version": "0.9.0.3", "subdir": "shibuya-core" }
      ]
    }
  ],
  "allowNewer": [ "keiro-test-support:ephemeral-pg" ],
  "exceptions": [
    {
      "package": "kiroku-store-migrations",
      "selected": "0.4.0.0",
      "latestObserved": "0.5.0.0",
      "reason": "keiro-migrations 0.17.0.0 bounds ^>=0.4.0.0",
      "recheckAfter": "2026-12-20"
    }
  ]
}
```

The `git` source appears only in `head.json`. A component is a repository: the unit that has a `mori://` URI and, in a head cohort, one commit; versions are per package because one repository releases packages at different versions. The components are `keiki` (`keiki`, `keiki-codec-json`), `kiroku` (`kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`, `kiroku-metrics`, `kiroku-cli`, `shibuya-kiroku-adapter`), `keiro` (`keiro`, `keiro-core`, `keiro-pgmq`, `keiro-migrations`, `keiro-test-support`), `shibuya` (`shibuya-core`, `shibuya-metrics`), `shibuya-pgmq-adapter`, `shibuya-kafka-adapter`, `kafka-effectful`, `hw-kafka-streamly`, `hw-kafka-client` (`mori://haskell-works/hw-kafka-client` when released, `mori://shinzui/hw-kafka-client` in head), `pgmq-hs` (the five `pgmq-*` packages), `pg-migrate` (the five pinned packages), `ephemeral-pg`, `effectful` (`mori://effectful/effectful`) and `hs-opentelemetry` (`mori://iand675/hs-opentelemetry`). Record as exceptions `kiroku-store-migrations`, the `pg-migrate` family, `effectful` (2.7.1.0 observed), `aeson` (2.2.5.1 resolved by bounds while 2.3.2.0 exists) and `hw-kafka-client`. Add `schemas/kenshou.cohort.v1.schema.json` and `schemas/kenshou.cohort-identity.v1.schema.json` (JSON Schema draft 2020-12, `additionalProperties: false` on the objects above).

Implement `kenshou-core/src/Kenshou/Core/Cohort.hs`. Add `aeson`, `bytestring`, `containers`, `cryptohash-sha256`, `directory`, `filepath` and `text` to the library.

```haskell
module Kenshou.Core.Cohort
  ( CohortName (..), ComponentId (..), PlanHash (..)
    -- descriptor, kenshou.cohort/v1: what a cohort intends to pin
  , CohortDescriptor (..), ComponentSpec (..), PackagePin (..), SourceSpec (..), PinException (..)
  , loadCohortDescriptor
    -- identity, kenshou.cohort-identity/v1: what the solver resolved
  , CohortIdentity (..), ResolvedComponent (..), ResolvedPackage (..), PackageSource (..)
  , CohortSource (..), CohortError (..)
  , activeCohortName, resolveCohortIdentity, identityFromPlan, planHash
    -- consistency
  , CohortMismatch (..), checkCohort, renderCohortIdentity
  ) where

data PackageSource
  = FromHackage {sha256 :: Maybe Text}
  | FromGit {location :: Text, rev :: Text, subdir :: Maybe Text}
  | FromBoot                 -- shipped with the compiler
  | FromLocalPath FilePath   -- never legitimate for a runtime package

data ResolvedPackage = ResolvedPackage {name :: Text, version :: Text, source :: PackageSource}

data ResolvedComponent = ResolvedComponent
  {id :: ComponentId, moriUri :: Text, packages :: [ResolvedPackage]}

data CohortIdentity = CohortIdentity
  { cohort :: CohortName, compiler :: Text, cabalVersion :: Text, os :: Text, arch :: Text
  , indexState :: Maybe Text, planHash :: PlanHash, descriptorSha256 :: Text
  , components :: [ResolvedComponent] }

data CohortSource
  = FromProject {projectDir :: FilePath, planJson :: Maybe FilePath, descriptor :: Maybe FilePath}
  | FromIdentityFile FilePath

data CohortMismatch
  = MissingPackage Text
  | VersionMismatch {package :: Text, expected :: Text, actual :: Text}
  | SourceMismatch {package :: Text, expected :: SourceSpec, actual :: PackageSource}
  | LocalPathSource {package :: Text, path :: FilePath}

activeCohortName      :: FilePath -> IO (Either CohortError CohortName)
loadCohortDescriptor  :: FilePath -> IO (Either CohortError CohortDescriptor)
planHash              :: Aeson.Value -> Either CohortError PlanHash
identityFromPlan      :: CohortDescriptor -> Text -> Aeson.Value -> Either CohortError CohortIdentity
resolveCohortIdentity :: CohortSource -> IO (Either CohortError CohortIdentity)
checkCohort           :: CohortDescriptor -> CohortIdentity -> [CohortMismatch]
renderCohortIdentity  :: CohortIdentity -> Text
```

`activeCohortName` parses the single `import: <name>.project` line of `<projectDir>/cohort/active.project`. `identityFromPlan` groups plan units under the descriptor's components by package name; `indexState` is copied from the descriptor because `plan.json` does not record it, and `descriptorSha256` is the SHA-256 of the descriptor file's bytes. `FromIdentityFile` reads a previously printed identity; it is the seam for builds that have no `dist-newstyle` (a Nix-built payload on a GCP cell), and the CLI also honours the environment variable `KENSHOU_COHORT_IDENTITY`. The plan hash is defined exactly so that any implementation reproduces it: take every unit of `install-plan` whose `style` is not `local`; render each as `<pkg-name> <pkg-version> <src> <flags>` where `<src>` is `hackage:<pkg-src-sha256>`, `git:<location>@<tag>#<subdir or ->` or `boot`, and `<flags>` is the unit's flags sorted and rendered `+f`/`-f` joined by commas (`-` when none); remove duplicates (a package appears once per component); sort bytewise; prepend the line `compiler <compiler-id>`; join with `\n`; hash the UTF-8 bytes with SHA-256 and render `sha256:<hex>`. Local units are excluded because they carry absolute paths; `os` and `arch` are excluded from the hash but kept in the identity. Platform-conditional dependencies can still make the hash differ between macOS and Linux, so consumers compare cohorts by `components`, and treat the hash as supporting evidence. `checkCohort` reports a descriptor package absent from the plan, a version difference, a source difference (Hackage versus git, or a different commit), and any descriptor package resolved from a local path, which means someone added a `cabal.project.local`.

`kenshou-core-test` uses trimmed fixtures under `kenshou-core/test/fixtures/` (`plan-released.json` with one Hackage unit, one `source-repo` unit, one `pre-existing` unit and two `local` units; `descriptor-released.json`; `cohort-identity.golden.json`). It must show that the hash is unchanged when units are reordered and when local paths change, changes when a version or commit changes, that each `CohortMismatch` constructor is produced by a doctored fixture, that the identity JSON matches the golden file, and that `activeCohortName` rejects a file that is not exactly one import line.

Create `kenshou-cli` with `app/Main.hs` (calls `Kenshou.Cli.main`), `src/Kenshou/Cli.hs`, `src/Kenshou/Cli/Options.hs` and `src/Kenshou/Cli/Cohort.hs`, executable `kenshou` built with `-threaded -rtsopts "-with-rtsopts=-N -T"` (the measurement toolkit needs `-T` for `GHC.Stats`), and `kenshou-cli-test`.

Also create `kenshou-cli/src/Kenshou/Cli/Version.hs` following `mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`. It reads the package version from `Paths_kenshou_cli`, uses `GitHash.tGitInfoCwdTry` for a local build, falls back to a CPP string literal `GIT_HASH`, and exports `appVersionWithGit` in the form `kenshou v0.1.0.0 (a1b2c3d)`. Add `githash >=0.1.7 && <0.2` to the library dependency set. Hackage listed 0.1.7.0 on 2026-09-20 and the upstream tag `githash-0.1.7.0` resolves, but recheck both during the existing `cabal update` and `git ls-remote --tags` refresh before changing that bound.

During the same dependency refresh, confirm that the fixed Hackage index contains `settei`, `settei-env`, `settei-optparse-applicative`, and `settei-yaml` 0.2.0.0 and that upstream tag `v0.2.0.0` still resolves in `mori://shinzui/settei`. These are harness dependencies for EP-2, not members of `cohort/released.json` or `cohort/head.json`; do not add them to the runtime identity or solver-plan comparison. EP-2 uses bounds `^>=0.2.0.0` unless a newer release is verified there first.

For the Nix package, use the same proven wiring as `mori://shinzui/okf` in `flake.module.nix` and `okf-cli/src/Okf/Cli/Version.hs`: bind `gitRev = inputs.self.shortRev or "dirty"`, wrap the `kenshou-cli` derivation with `overrideCabal`, and append `--ghc-option=-DGIT_HASH=\"${builtins.substring 0 7 gitRev}\"` to its configure flags. These are project-relative paths within the canonical project reference; no code-artifact URI exists yet. Keep this in the unmanaged `flake.module.nix`; do not edit Seihou-managed `flake.nix` or `nix/*.nix`. The Template Haskell path wins when `.git` is available, the CPP path wins in Nix, and a source tarball with neither prints the package version without a fabricated hash.

```haskell
-- Kenshou.Cli.Options
data Command = CohortCommand CohortCommand   -- docs/plans/2-… adds list, run, worker
commandParserInfo :: ParserInfo Command

-- Kenshou.Cli.Cohort
data CohortCommand
  = CohortShow  {json :: Bool, projectDir :: FilePath, planJson :: Maybe FilePath, identity :: Maybe FilePath}
  | CohortCheck {projectDir :: FilePath, planJson :: Maybe FilePath, descriptor :: Maybe FilePath}
cohortCommandParser :: Parser CohortCommand
runCohortCommand    :: CohortCommand -> IO ExitCode

-- Kenshou.Cli
main :: IO ()
runWithArgs :: [String] -> IO ExitCode
```

Attach `infoOption (Text.unpack appVersionWithGit) (long "version" <> help "Show version")` at the root parser. EP-2 will replace the closed command sum with the open registry and add grouped help, topics and completions; it must retain this version module and top-level option unchanged.

optparse-applicative exits 1 on a parse failure, but the contract says 2. `runWithArgs` therefore uses `execParserPure`, and on `Failure` calls `renderFailure`: if its exit code is `ExitSuccess` (that is `--help`) print to stdout and return 0, otherwise print to stderr and return `ExitFailure 2`. `cohort show` exits 0, or 4 when no plan or identity can be read, with the message `no dist-newstyle/cache/plan.json; run cabal build all first`. `cohort check` exits 0 when consistent, 1 with one line per mismatch, 4 when inputs are unreadable. Add the Justfile cohort group: `cohort-show`, `cohort-check`, `cohort-assert-released` (fails unless `cohort/active.project` is exactly `import: released.project`, which is what must be committed), and:

```text
[group('cohort')]
use-cohort name:
    test -f "cohort/{{name}}.project" && test -f "cohort/{{name}}.json"
    printf 'import: %s.project\n' "{{name}}" > cohort/active.project
    rm -f dist-newstyle/cache/config dist-newstyle/cache/plan.json
    @echo "active cohort: {{name}} (run cabal build all, then just cohort-check)"
```

### Milestone 3 — Prove the whole cohort links and migrates in one build

Scope: one test suite that depends on every runtime package and exercises PostgreSQL, the event store, the queue and librdkafka. At the end `just link-proof` is green on the released cohort and its result on the head cohort is recorded. This is the first time anything in the cohort is compiled here; expect a long first build.

Add to `kenshou-cli/kenshou-cli.cabal` a test suite `kenshou-linkproof` with `hs-source-dirs: linkproof`, `main-is: Main.hs`, `other-modules: LinkProof.Imports`, `ghc-options: -threaded`, depending on `keiro`, `keiro-core`, `keiro-pgmq`, `keiro-migrations`, `keiro-test-support`, `keiki`, `keiki-codec-json`, `kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`, `kiroku-metrics`, `shibuya-kiroku-adapter`, `shibuya-core`, `shibuya-metrics`, `shibuya-pgmq-adapter`, `shibuya-kafka-adapter`, `kafka-effectful`, `hw-kafka-client`, `hw-kafka-streamly`, `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-config`, `pgmq-migration`, `pg-migrate`, `ephemeral-pg`, `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-in-memory`, `hs-opentelemetry-exporter-otlp`, `hs-opentelemetry-propagator-w3c`, plus `aeson`, `effectful`, `effectful-core`, `hasql`, `hasql-pool`, `hspec`, `text` and `vector`. Give them no version bounds; the cohort decides.

A package named in `build-depends` but never imported may not be linked, so `LinkProof/Imports.hs` imports one exposed module from every package the four examples do not already use, with an empty import list (`import Keiki.Core ()`), which is warning-free and still forces the package into the link. Modules confirmed to be exposed: `Keiro.Command`, `Keiro.Schema`, `Keiro.PGMQ`, `Keiro.Migrations`, `Keiki.Core`, `Keiki.Codec.JSON`, `Kiroku.Store.Migrations`, `Kiroku.Otel.TraceContext`, `Kiroku.Metrics.Config`, `Shibuya.Adapter.Kiroku`, `Shibuya.App`, `Shibuya.Metrics.Config`, `Shibuya.Adapter.Pgmq.Config`, `Shibuya.Adapter.Kafka.Config`, `Kafka.Streamly.Stream`, `Pgmq.Types`, `Pgmq.Config`. Choose exposed modules for the OpenTelemetry packages from their cabal files under `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` (`mori://iand675/hs-opentelemetry`).

`Main.hs` follows `/Users/shinzui/Keikaku/bokuno/keiro/keiro-pgmq/test/Main.hs`, which already composes PGMQ into keiro's fixture:

```haskell
main :: IO ()
main = do
  pgmq <- either (fail . show) pure Pgmq.Migration.pgmqMigrations
  Keiro.Test.Postgres.withMigratedSuiteWith [pgmq] \fixture ->
    hspec $ describe "runtime cohort link-proof" $
      around (Keiro.Test.Postgres.withFreshDatabase fixture) do
        it "holds kiroku, keiro and pgmq in one pg-migrate ledger" \connStr -> …
        it "appends one kiroku event and reads it back" \connStr -> …
        it "sends and reads one PGMQ message" \connStr -> …
        it "creates and closes a librdkafka producer without a broker" \_ -> …
```

The ledger example opens a `Hasql.Pool` on `connStr` (`Pool.Config.settings [Pool.Config.staticConnectionSettings (Conn.connectionString connStr)]`) and runs `SELECT DISTINCT component FROM pgmigrate.migrations WHERE status = 'applied' ORDER BY 1`; the result must be exactly `keiro`, `kiroku`, `pgmq`. The kiroku example uses `Kiroku.Store.withStore (defaultConnectionSettings connStr)` and `Kiroku.Store.Effect.runStoreIO store`, calls `appendToStream (StreamName "linkproof-1") NoStream [EventData {eventId = Nothing, eventType = EventType "LinkProved", payload = object [], metadata = Nothing, causationId = Nothing, correlationId = Nothing}]`, then `readStreamForward (StreamName "linkproof-1") (StreamVersion 0) 10` and expects one event of that type; import from `Kiroku.Store.Append`, `.Read` and `.Types` if the umbrella `Kiroku.Store` lacks a name. The PGMQ example runs `runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool` over `createQueue q`, `sendMessage SendMessage {queueName = q, messageBody = MessageBody (String "ping"), delay = Nothing}` and `readMessage ReadMessage {queueName = q, delay = 30, batchSize = Just 1, conditional = Nothing}`, where `q` comes from `parseQueueName "kenshou_linkproof"`, and expects one message with that body. The Kafka example runs `runEff . runErrorNoCallStack @KafkaError . runKafkaProducer (brokersList [BrokerAddress "127.0.0.1:1"]) $ flushProducer` and expects `Right ()`: librdkafka connects lazily, so creating, flushing and closing a producer needs no broker, yet it loads the C library and calls into it. The fixture needs PostgreSQL 18 on the `PATH` (kiroku uses the built-in `uuidv7()`), which the dev shell provides.

Add the recipe `link-proof: cabal test kenshou-cli:test:kenshou-linkproof`. Then run `just use-cohort head`, build, and run it again. If the head cohort fails to compile because a Hackage package does not build against unreleased shibuya, that is a finding, not a defect in this plan: record the compiler error in Surprises & Discoveries, keep the offending stanza in `head.project` commented out with the reason, mirror that in `head.json`, and make sure the remaining head cohort is green. Finish with `just use-cohort released`.

### Milestone 4 — Adopt the ADR bundle, update mori.dhall and the README, add CI

Scope: durable decisions, registry metadata, the README and automation. At the end `just verify` passes from a clean clone and the workflow file is in place.

The `adopt-architecture-decisions` blueprint (`mori://shinzui/okf-profiles`, blueprint version 0.18.0 in the repository; the owner's machine has 0.15.0 installed) deliberately does nothing when `docs/adr/` holds no decision record, so the order matters. Refresh it with `seihou install https://github.com/shinzui/okf-profiles.git --module adopt-architecture-decisions`. Write `docs/adr/0001-layer-packages-never-import-one-another.md` with sections Context, Decision, Consequences and this frontmatter, leaving `docId` for the blueprint to derive from the file name:

```yaml
---
type: Architecture Decision Record
title: Layer packages never import one another
description: Each runtime layer is its own cabal package depending only on the kernel and toolkits, so a red layer is attributable and layers build and run independently.
timestamp: 2026-09-20T00:00:00Z
generated:
  by: human:nadeem
  at: "2026-09-20T00:00:00Z"
status: Accepted
date: 2026-09-20
---
```

Its decision: the five layer packages depend on `kenshou-core` and the toolkit packages and never on each other; only `kenshou-runtime` and `kenshou-cli` may depend on layers; the README's axis directories were rejected because isolating a failure and selecting runs by change both need the layer as the unit. Run `seihou agent run adopt-architecture-decisions "New repository with its first ADR; register OKF bundle adrs at okfVersion 0.2; the check surface is the Justfile recipe adr-validate."`. It installs `docs/adr/profile.dhall` (a hash-pinned import of `Profiles.documentation.architectureDecisions`), assigns `ADR-1`, writes `index.md` and `log.md`, and proposes the `mori.dhall` entry. If it cannot run, do the same by hand: copy `~/.config/seihou/installed/adopt-architecture-decisions/files/architecture-decisions-profile.dhall` byte for byte to `docs/adr/profile.dhall`, run `dhall type --file docs/adr/profile.dhall`, add `docId: ADR-1`, then `okf index docs/adr --write --okf-version 0.2` and `okf log add docs/adr --kind Migration -m "Adopt the shared architecture-decision profile."`.

Allocate the second handle properly with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (expect `ADR-2`; never count files) and write `docs/adr/0002-every-result-carries-a-resolved-cohort-identity.md`: a cohort is an explicit, complete, named pin set; `released` (Hackage at an `index-state`) and `head` (https git commits) are both first-class; every result embeds the identity resolved by the solver, not the intended one; descriptors map components to `mori://` URIs; `file://` and local-path sources are forbidden; a package-qualified `allow-newer` needs written evidence; cite `mori://shinzui/jinmyaku/okf/adrs/concepts/ADR-1`, `mori://shinzui/rei/okf/adrs/concepts/ADR-16` and `mori://shinzui/rei/okf/adrs/concepts/ADR-18`. Re-run `okf index … --write`, add a log entry, and add the recipe `adr-validate` running `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`. Before closing the plan, promote anything durable from this plan's Decision Log (the imported-file cache behaviour is a good candidate) into these ADRs or a new one.

Extend `mori.dhall`, keeping the schema pin, identity and `stableId` untouched. Add `packages` with `Schema.Package::{ name = "kenshou-core", type = Schema.PackageType.Library, … }` and `kenshou-cli` as `Schema.PackageType.Application`; set `dependencies` to `shinzui/keiro`, `shinzui/keiki`, `shinzui/kiroku`, `shinzui/shibuya`, `shinzui/shibuya-pgmq-adapter`, `shinzui/shibuya-kafka-adapter`, `shinzui/kafka-effectful`, `shinzui/hw-kafka-streamly`, `shinzui/hw-kafka-client`, `haskell-works/hw-kafka-client`, `shinzui/pgmq-hs`, `shinzui/pg-migrate`, `shinzui/ephemeral-pg`, `iand675/hs-opentelemetry`, with a matching `Schema.MoriRef::{ namespace, name }` in `dependencyRefs` for each; add `okfBundles = [ Schema.OkfBundle::{ name = "adrs", path = "docs/adr", profile = Some "docs/adr/profile.dhall", okfVersion = "0.2", description = Some "Durable architecture decisions" } ]`; add `docs` with one `Schema.DocRef::{ key = "masterplan", kind = Schema.DocKind.Spec, audience = Schema.DocAudience.Module, description = Some "…", location = Schema.DocLocation.LocalFile "./docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md" }`. `/Users/shinzui/Keikaku/bokuno/pg-migrate/mori.dhall` shows the `DocRef` shape and `/Users/shinzui/Keikaku/bokuno/keiro/mori.dhall` the package shape.

In `README.md` replace the text under "Status" with a statement that the repository builds and pins the runtime cohort, followed by a `text` block reproducing the layout of Integration Point 1 (`cabal.project`, `cohort/`, the `kenshou-*` packages marked as present or planned, `schemas/`, `suites/`, `docs/adr/`, `docs/verification/`), and a short "Getting started" listing `nix develop`, `cabal build all`, `cabal run kenshou -- cohort show`, `just use-cohort head` and `just verify`. Leave the rest of the README alone.

Add `.github/workflows/ci.yaml` modelled on `/Users/shinzui/Keikaku/bokuno/danwa/.github/workflows/ci.yaml`: triggers on push to `master` and on pull requests, a concurrency group, `CABAL_DIR: ${{ github.workspace }}/.cabal`, one `ubuntu-latest` job that checks out, installs Nix with `DeterminateSystems/nix-installer-action` and the `https://shinzui.cachix.org` substituter in `extra-conf`, enables `DeterminateSystems/magic-nix-cache-action`, caches `.cabal` and `dist-newstyle` keyed on `hashFiles('cabal.project', 'cohort/*.project', '**/*.cabal')`, then runs through `nix develop --command`: `just cohort-assert-released`, `cabal update`, `cabal build all`, `just haskell-test`, `just link-proof`, `just cohort-check`; then `nix shell github:shinzui/okf/v0.9.0.0#okf-cli nixpkgs#dhall -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`, `nix flake check` and `nix fmt -- --fail-on-change`. CI builds only the released cohort and runs no scenarios, benchmarks or soaks. Finally set `verify: process-compose-check fmt-check haskell-build haskell-test link-proof cohort-assert-released cohort-check adr-validate`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`. Transcripts are illustrative where hashes, counts or timings will differ.

Every commit follows Conventional Commits, goes directly to `master`, and carries these trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Suggested subjects, one per milestone: `build(nix): scaffold dev shell, formatting hooks and cabal project`, `feat(cohort): pin released and head cohorts and add kenshou cohort show`, `test(linkproof): link and migrate the whole runtime cohort`, `docs(adr): adopt the ADR bundle, extend mori.dhall, add CI`.

Milestone 1:

```bash
seihou list | grep -E '^  (nix-haskell-flake|adopt-architecture-decisions) '
seihou run nix-haskell-flake --dry-run \
  --var nix.pg-package=postgresql_18 --var nix.pg-database=kenshou \
  --var nix.kafka=true --var nix.builtin-package=false \
  --var nix.redpanda=false --var nix.haskell-nix=false \
  --var 'nix.fourmolu-ghc-opts="GHC2024" "DuplicateRecordFields" "ImportQualifiedPost" "NoFieldSelectors" "OverloadedLabels" "OverloadedRecordDot"'
# read the plan, then run the same command again without --dry-run
git add flake.nix flake.lock flake.module.nix nix fourmolu.yaml process-compose.yaml .gitignore .seihou
nix develop --command bash -c 'ghc --numeric-version; cabal --numeric-version; postgres --version; echo $KENSHOU_PG17_BIN; echo $KENSHOU_PG18_BIN; $KENSHOU_PG17_BIN/postgres --version; pkg-config --modversion rdkafka'
```

```text
9.12.4
3.16.1.0
postgres (PostgreSQL) 18.x
/nix/store/…-postgresql-17.x/bin
/nix/store/…-postgresql-18.x/bin
postgres (PostgreSQL) 17.x
2.x.y
```

```bash
nix develop --command cabal build all
nix fmt && git diff --stat        # expect formatting only on files you just wrote
nix develop --command just process-compose-check
```

Milestone 2:

```bash
nix develop
cabal update                      # note the index-state ceiling it prints
cabal build all --dry-run | tail -3
cabal build all
cabal run -v0 kenshou -- cohort show
```

```text
cohort     released
compiler   ghc-9.12.4   cabal 3.16.1.0   osx/aarch64
index      2026-09-20T13:44:47Z
plan       sha256:4f1c…
keiro      keiro 0.17.0.0, keiro-core 0.17.0.0, keiro-pgmq 0.17.0.0, …   hackage
shibuya    shibuya-core 0.9.0.3, shibuya-metrics 0.9.0.3                 hackage
…
```

Until Milestone 3 adds the link-proof, most descriptor packages are absent from the plan and `cohort check` reports `MissingPackage` for them; that is expected, and the check becomes meaningful once the link-proof exists. Exercise the switch now anyway:

```bash
just use-cohort head && cabal build all --dry-run | tail -2
just use-cohort released
cabal run -v0 kenshou -- cohort bogus; echo "exit=$?"     # expect usage text and exit=2
cabal test kenshou-core:tests kenshou-cli:test:kenshou-cli-test
```

Milestone 3:

```bash
just link-proof
```

```text
runtime cohort link-proof
  holds kiroku, keiro and pgmq in one pg-migrate ledger [✔]
  appends one kiroku event and reads it back [✔]
  sends and reads one PGMQ message [✔]
  creates and closes a librdkafka producer without a broker [✔]

Finished in 3.2 seconds
4 examples, 0 failures
```

```bash
cabal run -v0 kenshou -- cohort check; echo "exit=$?"      # expect exit=0
just use-cohort head && cabal build all && just link-proof
cabal run -v0 kenshou -- cohort show | grep -E 'shibuya|hw-kafka-client'
```

```text
shibuya          shibuya-core 0.9.0.3, shibuya-metrics 0.9.0.3   git a26d60609f11
hw-kafka-client  hw-kafka-client 5.3.0                           git 6caed636898a
```

```bash
just cohort-check && just use-cohort released && just cohort-assert-released
```

Milestone 4:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall      # expect ADR-1
okf id next docs/adr --profile docs/adr/profile.dhall ADR  # expect ADR-2
just adr-validate
mori validate --check-deps && mori register
mori registry concepts shinzui/keiro-runtime-kenshou --bundle adrs --json | jq -r '.[].ref'
```

```text
mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-1
mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-2
```

```bash
git clone . ../kenshou-verify-clone && cd ../kenshou-verify-clone && nix develop --command just verify
```


## Validation and Acceptance

Milestone 1 is accepted when, inside `nix develop`, GHC reports 9.12.4 and cabal 3.16.x; `postgres --version` reports 18 and `$KENSHOU_PG17_BIN/postgres --version` reports 17; `pkg-config --modversion rdkafka` prints a version; `cabal build all` builds `kenshou-core`; `nix fmt -- --fail-on-change` exits 0 on a second run; `just process-compose-check` exits 0; and an attempted commit whose message contains a literal `\n` is rejected by the hook.

Milestone 2 is accepted when `cabal run kenshou -- cohort show --json` prints a document whose `schema` is `kenshou.cohort-identity/v1`, that validates against `schemas/kenshou.cohort-identity.v1.schema.json`, and whose `planHash` is identical across two consecutive builds; when `just use-cohort head` followed by a build changes the reported source of shibuya and hw-kafka-client to git commits and changes the plan hash, and `just use-cohort released` restores the first hash exactly; when editing `cohort/active.project` by hand without the recipe demonstrably leaves the old plan in place (this proves why the recipe exists; note it in Surprises & Discoveries); when an unknown subcommand exits 2 and `--help` exits 0; when the Cabal-built and Nix-built executables both report `kenshou v0.1.0.0 (<seven-character revision>)` for the same clean commit and a dirty Nix source reports `(dirty)` rather than a stale revision; and when `cabal test kenshou-core:tests kenshou-cli:tests` passes, including the doctored-fixture tests that produce every `CohortMismatch` constructor and a version-format test.

Milestone 3 is accepted when `just link-proof` reports four passing examples on the released cohort; `cabal run kenshou -- cohort check` exits 0 on it; and the head cohort either passes the same four examples or has a recorded, explained reduction. To see that the proof is not vacuous, temporarily remove `pgmq` from the component list passed to the fixture and observe the ledger example fail, then restore it.

Milestone 4 is accepted when `just adr-validate` exits 0; `mori validate --check-deps` exits 0 and the two ADR handles resolve through `mori registry concepts`; the README's Status block shows the package layout; and `just verify` passes from a fresh clone. The workflow is accepted when its first run on GitHub is green; if Actions is unavailable, record that and treat the local `just verify` as the gate.

The plan as a whole is accepted when a person who has never seen the repository can clone it, run `nix develop --command just verify`, and then answer "which exact shibuya is this built against?" with one command.


## Idempotence and Recovery

`seihou run nix-haskell-flake` is safe to repeat; it reports a conflict if a managed file was hand-edited, in which case move the edit into `flake.module.nix`, `.envrc.local` or `process-compose.override.yaml` and re-run with `--force`. Never hand-edit `flake.nix` or `nix/*.nix`. If Nix seems to ignore `flake.module.nix` or `flake.lock`, they are untracked: `git add` them.

If the solver fails, read the first `rejecting:` line; it names the package and the bound. Remedies in order, following `mori://shinzui/rei/okf/adrs/concepts/ADR-16`: take the dependency's current release; move a git pin; and only then a package-qualified `allow-newer` with the written evidence. If cabal reports Cabal-7159, the `index-state` is beyond the local index: run `cabal update` and use a timestamp at or below the printed ceiling. If a cohort switch seems to have no effect, the plan cache is stale: `rm -f dist-newstyle/cache/config dist-newstyle/cache/plan.json`. Switching cohorts never requires deleting `dist-newstyle`. Always finish with `just use-cohort released`; `cohort-assert-released` stops a commit of the wrong selector in `just verify` and in CI.

The link-proof leaves nothing behind when it exits normally. If it is killed, a PostgreSQL server may survive: list with `pgrep -fl 'postgres -D'`, confirm the data directory is under the temporary directory, and stop it with `pg_ctl stop -D <dir> -m immediate`. The development database in `./db` is only used by `just process-compose`; remove it with `just postgres-stop; rm -rf db` and the shell recreates it. Nothing in this plan touches Kafka brokers, cloud resources or any sibling repository.

`okf index --write` and `okf validate` are repeatable. Never renumber an ADR; if the blueprint assigned an unexpected handle, keep it and adjust the file name. If `mori register` fails, `mori validate` still gates the manifest and registration can be retried later. Each milestone is one commit, so `git revert` of that commit is the rollback.


## Interfaces and Dependencies

Toolchain: GHC 9.12.4, cabal-install 3.16.1.0, fourmolu, cabal-gild and nixpkgs-fmt from `github:shinzui/haskell-nix-dev/206ecd25bcb4a07581210bdae3e6f43c8fd179d8` through Seihou module `nix-haskell-flake` 0.24.0; PostgreSQL 18 on the `PATH` and PostgreSQL 17 by variable; librdkafka from nixpkgs `rdkafka`; `okf` 0.9.0.0 or later; `mori`; `seihou`; blueprint `adopt-architecture-decisions` 0.18.0.

Released cohort: keiro, keiro-core, keiro-pgmq, keiro-migrations, keiro-test-support 0.17.0.0; keiki, keiki-codec-json 0.9.1.0; kiroku-store 0.8.0.1; kiroku-store-migrations 0.4.0.0; kiroku-otel 0.2.0.8; kiroku-metrics 0.1.0.8; kiroku-cli 0.2.0.6; shibuya-kiroku-adapter 0.5.1.2; shibuya-core, shibuya-metrics 0.9.0.3; shibuya-pgmq-adapter 0.16.0.0; shibuya-kafka-adapter 0.9.0.1; kafka-effectful 0.3.1.0; hw-kafka-client 5.3.0; hw-kafka-streamly 0.2.0.0; pgmq-core, pgmq-hasql, pgmq-effectful, pgmq-config, pgmq-migration 0.6.1.0; pg-migrate, pg-migrate-embed, pg-migrate-cli, pg-migrate-import-codd, pg-migrate-import-hasql-migration 1.1.0.0; ephemeral-pg 0.3.1.0; effectful, effectful-core 2.6.1.0; the hs-opentelemetry packages 1.0.0.0 and semantic-conventions 1.40.0.0. Head cohort: the same with shibuya at `a26d60609f118f8ca5357c6c16f02317e10fb819` and hw-kafka-client at `6caed636898a78e9f6e5a9c93eeb5562cbb2580a`. Harness libraries: aeson 2.2.x, cryptohash-sha256, optparse-applicative 0.19, githash 0.1.7.x, Settei family 0.2.0.0 (added by EP-2 and excluded from the runtime cohort identity), hspec 2.11, hspec-hedgehog 0.3.

At the end of Milestone 1 these exist: `flake.nix`, `flake.lock`, `flake.module.nix`, `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`, `fourmolu.yaml`, `process-compose.yaml`, `Justfile`, `cabal.project`, `cohort/active.project`, `kenshou-core/kenshou-core.cabal`, and the environment variables `KENSHOU_PG17_BIN` and `KENSHOU_PG18_BIN`. At the end of Milestone 2: `cohort/released.project`, `cohort/head.project`, `cohort/released.json`, `cohort/head.json`, the two schema files, module `Kenshou.Core.Cohort` with the signatures given in Plan of Work, package `kenshou-cli` with `Kenshou.Cli`, `Kenshou.Cli.Options`, `Kenshou.Cli.Cohort`, `Kenshou.Cli.Version` and executable `kenshou`, the Nix `GIT_HASH` injection, and the recipes `use-cohort`, `cohort-show`, `cohort-check`, `cohort-assert-released`. At the end of Milestone 3: test suite `kenshou-cli:test:kenshou-linkproof` and recipe `link-proof`. At the end of Milestone 4: `docs/adr/` with `profile.dhall`, `index.md`, `log.md`, ADR-1 and ADR-2; recipes `adr-validate` and `verify`; `.github/workflows/ci.yaml`.

What other plans consume. `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` extends both packages: it replaces the closed `Kenshou.Cli.Options.Command` sum with an open registry of `CliCommand` values defined in `kenshou-core` (so that later plans can add verbs without editing a central type), re-registers `cohort show` and `cohort check` through that registry with their behaviour unchanged, keeps `runWithArgs`' exit-code handling, embeds `CohortIdentity` in the run result through `resolveCohortIdentity`, reads `KENSHOU_PG17_BIN` and `KENSHOU_PG18_BIN` to choose a PostgreSQL major, takes over `schemas/` using the file naming started here, and should note that `ephemeral-pg` is 0.3.1.0, so `withCachedConfig`, `temporaryRoot` and the stale-cluster sweep are available. `docs/plans/3-plan-and-select-runs-from-what-changed.md` diffs two `kenshou.cohort/v1` descriptors at package granularity and maps packages to its own component graph. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` ships an identity file and points `KENSHOU_COHORT_IDENTITY` at it on the cell. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` writes each component's `moriUri` and version or commit into run records. `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` may turn on `nix.redpanda` and add a cohort that pairs released packages with the hw-kafka-client fork. Every later plan adds a package by creating `kenshou-<name>/kenshou-<name>.cabal` and adds a runtime dependency only if the cohort already pins it; a new runtime package means editing both cohort files and both descriptors and re-running `just cohort-check`.


Revision note (2026-09-20): Added the EP-1 portion of the `mori://shinzui/haskell-jitsurei` CLI standard. The bootstrap now provides a Git-aware top-level `--version` for both Cabal and Nix builds, verifies its registry and upstream release inputs, and hands that release-identity module to EP-2's shared CLI framework.

Revision note (2026-09-20): Added release verification and cohort-boundary guidance for the Settei 0.2.0.0 harness configuration family.
