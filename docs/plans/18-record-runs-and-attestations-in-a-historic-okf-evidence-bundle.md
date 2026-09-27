---
id: 18
slug: record-runs-and-attestations-in-a-historic-okf-evidence-bundle
title: "Record runs and attestations in a historic OKF evidence bundle"
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
      at: 2026-09-26T19:57:37Z
      mode: "implement"
      note: "Implemented the local OKF verification bundle, profile, definitions, and rejection gate."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T13:40:30Z
      mode: "implement"
      note: "Completed comparison attestation, live confirmation, operator guide, and scale probe."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T17:24:09Z
      mode: "implement"
      note: "Attached VC-2 only when a recorded run contains its measurement summary."
---

# Record runs and attestations in a historic OKF evidence bundle

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a kenshou run leaves a directory on somebody's disk. Nothing says, six months later, which revision of kiroku that run linked, whether the number in a slide came from the blessed computation, or whether the raw samples still exist and are the same bytes. After this plan a maintainer can turn any finished run into a small, permanent record in this repository, have a deterministic verifier re-check it, and ask the repository for the whole history of a scenario.

Concretely, four command surfaces appear. `kenshou record <run-dir> --data-base-uri gs://… --purpose release` makes sure the run's files are in durable object storage, and writes one Markdown file under `docs/verification/runs/` that names exactly what ran (scenario, knobs, dimensions, seed), against what (every runtime package with its `mori://` project URI, released version or Git revision), where (an environment excerpt), what came of it (the outcome), and where the data is (one link per file with its SHA-256 digest, media type and size). The record holds no measurement at all; this was decided by the platform owner on 2026-09-20 and is binding. `kenshou attest <run>` fetches the linked data, confirms every digest, recomputes the outcome from the raw data under a named, versioned computation definition, writes an `Attestation` record with a verdict of `confirmed`, `refuted` or `incomplete`, and, only when confirmed, appends a machine entry to the run's OKF `verified` list. `kenshou evidence check` enforces the repository rules that the profile cannot express. `kenshou history --scenario kiroku/append/benchmark/single-stream-throughput --json` emits the series of records for that scenario with their data links and a derived baseline, which is the input contract for a future reporting plan. The commands participate in the parser-derived shell completions and grouped help established by `docs/plans/2-…`; `record`, `attest`, and `evidence` are in the Evidence group, while `history` is in Analysis.

You can see it working at the end by running `just verify`, which validates the bundle against its profile, proves the generated indexes are current, and runs `kenshou evidence check`; by opening a run record and following a `gs://` link with `gcloud storage cat`; and by flipping one byte of a fetched copy in the tamper test and watching `kenshou attest` answer `refuted` with exit code 1.


## Progress

- [x] (2026-09-26) Completed Milestone 1: the local OKF v0.2 bundle, pinned Dhall profile, three source-checked computation definitions, reference scripts, Mori registration, two ADRs, and repository recipes are present. Strict enforcement reports `OK: 3 concepts`; `okf computations` shows executor and attester for each definition; `okf id list` resolves `VC-1` through `VC-3`; 20 isolated invalid-shape probes and the missing-attester-resource control reject as expected; `mori validate` and the index check pass.
- [x] (2026-09-26) Established typed digest and revision boundaries, create-only scratch and memory object stores, and a run source reader that checks manifest coverage, digests, sizes, safe paths and run document identity before producing evidence inputs.
- [x] (2026-09-26) The publishing boundary snapshots each verified file before a create-only upload, checks object size and SHA-256 metadata, optionally downloads for deep verification, and links the required run data. A GCS adapter checks the active project and passes an explicit project on storage calls; it uses an object-generation precondition and custom SHA-256 metadata. Scratch and fake-CLI tests cover the protocol. Live upload exposed that `gcloud storage cp` rejects `--no-clobber` together with `--if-generation-match=0`, and that `gcloud storage objects describe --format=json` reports custom metadata under `custom_fields`. The adapter and fake-CLI test now follow both behaviors. The second attempt created one matching object before the incorrect metadata parser stopped the command; it can be reused after the fix.
- [x] (2026-09-26) Created `gs://kenshou-evidence-tan-nb-exp` in `tan-nb-exp` and verified `us-west1`, uniform bucket-level access, enforced public access prevention, object versioning, and an unlocked five-year retention policy. A clean clone produced two always-pass correctness self-test runs, both live-recorded and confirmed. Live-recorded and attested concurrency, soak, and two passing benchmark runs cover the other three kinds; their attestations are incomplete because the scenario-specific VC-1 outcome recomputers are not yet registered, while their digest, revision, cohort, environment and clean-worktree checks passed. A one-pair comparison of the two benchmark runs is recorded with `purpose: release`; its metric checks passed and its verdict is inconclusive because the policy requires three pairs. Strict OKF validation reports 16 concepts, `kenshou evidence check --network --deep` reports no findings, and direct `gcloud storage cat` of `run-result.json` hashes to its recorded digest. The root `.gitignore` had hidden `docs/verification/runs/`; anchoring `/runs/` makes the generated corpus visible to Git.
- [x] (2026-09-26) `kenshou record` builds a typed run record, publishes data, writes the immutable concept and monthly log, regenerates indexes and runs in-process OKF validation with rollback. A scratch copy of the bundle recorded a real dirty selftest run, repeated it as `already recorded`, and passed strict OKF validation with four concepts; the scratch-store guard refused the repository bundle with exit code 2.
- [x] (2026-09-26) `kenshou evidence check` and the `just evidence-check` gate catch path, ID, digest, revision, string-typing, time-order, event-key, required-link, dirty-purpose, cell-field, reference-target, comparison outcome, and Git immutability violations. A temporary Git repository proves that editing an outcome is found in both the worktree and committed history. Settei resolves bundle, GCP project, and data URI from built-in, ordered YAML, explicit environment, and named-flag sources; strict unknown-key rejection keeps purpose and anomaly authority out of configuration. A scratch recording linked `gs://flag/runs/…` when a flag overrode the YAML and environment URI, and forced investigation purpose for the dirty run. The opt-in `--network` rule checks object size and SHA-256 metadata; `--deep` fetches bytes and hashes them, with a memory-store test covering both paths. The live `--network --deep` check passed against the seeded GCS corpus with no findings.
- [x] (2026-09-26) The comparison producer includes ordered arm IDs, timestamps, harness provenance, and execution design in `kenshou.comparison/v1`. `kenshou record --comparison FILE` reads and publishes the document, requires both recorded arms with one scenario and consistent factor values, derives a comparison outcome, and writes an immutable OKF concept with arm references through the run writer's create-only path. A scratch bundle test rejects a missing arm, records the comparison, reports replay as `already recorded`, and passes local evidence checks.
- [x] (2026-09-27) Completed Milestone 4: `kenshou history` walks the OKF bundle and emits deterministic `kenshou.evidence-history/v1` JSON, including comparison records, attestation summaries, trust derived from confirmations, and the latest earlier compatible confirmed baseline. Scenario, cohort package, outcome, date, and confirmed-only filters are present, with a JSON Schema and a scratch-bundle test. The live history of the two confirmed correctness runs validates against the schema and gives the newer run the older run's `derivedBaseline`. `just verify`, `nix flake check`, and the live deep evidence check pass; the seeded corpus covers all four evidence kinds and a comparison whose arms resolve.
- [x] (2026-09-27) Completed Milestone 3: `kenshou attest` fetches linked objects and manifest files, checks their bytes, records six named results in a create-only attestation concept, and derives `confirmed`, `refuted`, or `incomplete` from those checks. The local checker verifies the check set, verdict, digest coverage, target path, and process confirmations. Scratch-store tests cover incomplete intact data, refuted tampered data, a refuted recomputation, and a confirmed clean self-test run whose two attestations append exactly one `verified` entry. The target accepts a run or comparison path or ID. An interactive `--accept-anomaly` requires an explicit human actor and reason and is refused in CI. Revision resolution checks the Mori checkout and, when online, fetches the exact git commit from the cohort source into a scratch repository. The attester reads each named computation definition from the bundle and runs registered algorithms; a disagreement refutes the record even if another algorithm is unavailable. The CLI registers `kenshou-summary` recomputation for VC-2 and paired comparison replay for VC-3, while the core has a narrow VC-1 oracle for the fixed always-pass self-test. Other domain scenarios remain incomplete until their oracles are registered. The live GCS comparison attestation `01a0e314-ba03-71c8-ad09-6999aabbca8a` passed all six checks and added one machine `verified` entry; strict OKF validation, `okf trust`, and `kenshou evidence check` passed afterward.
- [x] (2026-09-27) Completed Milestones 2–4: `record`, `attest`, `history`, digest and revision checks, and a seeded corpus meet the acceptance commands below. The Bash, Zsh, and Fish completion protocols expose all four command surfaces; the embedded evidence help has a stable 80-column golden; a scratch-bundle flow checks URI refusal, JSON output separation, identical replay, CI anomaly refusal, and tamper refutation. The operator guide is `docs/guides/recording-evidence.md`.
- [x] (2026-09-27) Repeated the scale probe against a temporary copy with 2,000 synthetic run records: strict enforced `okf validate` reported `OK: 2017 concepts` in 6.740 seconds; `okf index --write` took 7.732 seconds. The ten-second validation threshold for splitting by year was not crossed.
- [x] (2026-09-27) Recorded clean Kafka rebalance and reduced stability-soak runs in the live GCS-backed bundle. Their attestations verified every linked digest, revision, cohort, environment, and clean worktree, but remained incomplete without a Kafka VC-1 recomputer. The soak attestation also found that `record` had named VC-2 solely because its scenario kind was `soak`, although that run wrote no `kenshou.measurements/v1` summary. The recorder now names VC-2 only when the nested measurement summary is present; a focused source-to-record test covers both shapes. The historical soak record and incomplete attestation remain unchanged.
- [x] (2026-09-27) Added a VC-1 oracle for Kafka static-member fencing. It reads the two sealed worker control streams and independently derives replacement handling, fatal-error visibility, original exit, failure labels, outcome, and the released-cohort known-defect disposition. Four focused facts tests pass, and a scratch GCS-backed attestation of released run `01a0e402-0b02-7309-b378-3686b0e953a6` passed verdict recomputation; its scratch verdict remained incomplete only because the development worktree was dirty. Clean live attestation [01a0e418-738b-7155-bc34-ae772f3e3ca5](../verification/attestations/2026/09/01a0e418-738b-7155-bc34-ae772f3e3ca5.md) then passed all six checks, and `okf trust` reports the released baseline as `machine-confirmed`. Clean head run `01a0e41c-947d-76df-80cf-11a7078016ad` also passed the oracle and all six checks in [attestation 01a0e41f](../verification/attestations/2026/09/01a0e41f-4f2a-747e-9bd6-625fd4317c00.md); both fencing cohort records are machine-confirmed. Other Kafka scenarios still need their own oracles.

## Surprises & Discoveries

- Observation: the Kafka reduced stability soak emitted a diagnosis and broker metadata but no `kenshou.measurements/v1` summary. The old recorder attached VC-2 to every soak and benchmark by kind, so the attester reported both VC-1 and VC-2 unavailable for its immutable record. VC-2 describes latency and throughput summary recomputation, not leak diagnosis. Future records attach it only when the run-result's `summaries.measurements.measurements` object exists; the old event remains a truthful incomplete attestation rather than being rewritten.
- Observation: the fencing worker's control log may contain a `done` event from scenario cleanup after the waiting deadline, and that event has no timestamp. The new VC-1 oracle refuses an original-member exit without a fatal error rather than treating an ambiguous cleanup event as proof of timely exit. The recorded released run has no such event; the head run has a fatal error followed by `done`.
- Observation: live `gcloud storage cp` rejects the combination of `--no-clobber` and `--if-generation-match=0`. The generation precondition alone supplies the create-only guarantee, so the adapter and its fake-CLI protocol test now use only that flag. The initial command failed before it created a cloud object.
- Observation: the installed `gcloud storage objects describe --format=json` reports custom SHA-256 metadata in `custom_fields`, not `metadata`. The first successful object upload was reported as a conflict because the adapter did not read that field. The parser now accepts `custom_fields` and retains `metadata` as a compatibility fallback.
- Observation: sandboxed benchmark runs could execute but `sysctl` could not read the CPU model, so the evidence recorder correctly refused them. Rerunning the selected baseline and candidate with host access produced sealed passing results with `Apple M1 Max` in their fingerprints; only those runs were recorded. A one-pair comparison remains inconclusive under the minimum-three-pair policy, even though its individual metrics passed.
- Observation: seeding the first live run increased the history entries in a scratch-bundle test that copies `docs/verification`. The assertion now filters its three fixture IDs before checking their order and kinds.
- Observation: staging the new corpus exposed that the immutability gate compared every staged addition against a nonexistent `HEAD` version and reported it as a changed committed event. The gate now permits `A` status for a new file while continuing to reject modifications, deletions and renames of committed events; a temporary Git test covers the staged-addition case.
- Observation: `just verify` passed, but the workflow's separate `nix flake check` initially failed because `flake.module.nix` had not wired the newly added local packages into the generated `kenshou-cli` derivation. The flake now supplies all local CLI dependencies, and `nix flake check` passes on the current host.
- Observation: the current runner records the `ScenarioReport.outcome` supplied by each scenario. It does not fold all `verdicts/` and `diagnosis/` files into an outcome, as the drafting example for `VC-1` assumed. The definition now describes the actual runner and known-defect disposition. A generic attester can verify internal consistency and digests, but must report an incomplete verdict-recomputation check unless the scenario's domain oracle can be replayed from saved inputs. The registered recomputation seam confirms the fixed always-pass self-test; each other scenario still needs an independent oracle. See `Kenshou.Core.Run.executeRun`, `Kenshou.Core.Run.defectDisposition`, and [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md).
- Observation: `Kenshou.Core.Canonical.sha256Hex` and the run manifest use `sha256:`-prefixed digests, while the OKF profile requires bare lowercase hexadecimal digests. The evidence boundary verifies the kernel form before stripping the prefix for data links. Also, `Kenshou.Core.Manifest.verifyManifest` only checks the digest of listed files; it does not check their sizes, reject extra files or guard listed paths, so `Kenshou.Evidence.Source` performs these checks itself.
- Observation: `Kenshou.Core.RunResult` has a `ToJSON` instance but no `FromJSON` instance. `Kenshou.Evidence.Source` uses a typed evidence-facing reader for the versioned run-result schema and keeps the larger diagnostic document as linked data.
- Observation: The shared Settei parser labels the bundle and configuration choices `Configuration` in `history --help`, where the draft called that section `Bundle selection`. The other named history sections are `Scenario filters`, `Trust filters`, and `Output`; the surface test checks the actual parser output.


## Decision Log

- Decision: Runs and attestations are addressed by path and carry no `PREFIX-N` handle; only computation definitions take handles, `VC-N`, held in the field `computationId`.
  Rationale: `okf id next` answers one more than the highest handle in the working tree and writes nothing, so two recorders working from different checkouts would allocate the same number and collide when merged. A UUIDv7 in the file name cannot collide, and Mori resolves `mori://…/concepts/<path>` by falling back from handle to path. Definitions are few and written by people, so short handles are safe and convenient there.
  Date: 2026-09-20

- Decision: `executor.resource` and `attester.resource` point at non-Markdown files (`references/executors/kenshou-run.sh`, `references/attesters/kenshou-attest.sh`). The bundle keeps exactly three concept types.
  Rationale: Any `.md` file in a bundle is a concept and needs a `type`; with `allowUnknownTypes = False` a Markdown reference is rejected with `type not in profile vocabulary` (verified while drafting). A fourth `Reference` type would exist only to hold two files and would contradict Integration Point 10. Shell scripts are also more honest: they are the runnable instructions.
  Date: 2026-09-20

- Decision: A comparison is a `Verification Run` whose discriminator `recordKind` is `comparison`; there is no fourth type.
  Rationale: Integration Point 10 fixes three types. okf can condition a required field on a closed scalar sibling but not on the presence of a key, so a discriminator is needed either way. With it, run-only fields (`cohort`, `components`, `environment`, `seed`, `solverPlanHash`, `compatibilityKey`) are required when `recordKind` is `run`, and the `comparison` object is required when it is `comparison`; both gates were verified with the installed okf.
  Date: 2026-09-20

- Decision: `checks` on an attestation is a list of records `{name, result, detail}` unique by `name`, not a bare list of names.
  Rationale: The brief asked for a closed list of check names. A bare list can say what was looked at but not which check failed, and a `refuted` attestation that does not say why is useless. The closed vocabulary is preserved on `name`; `result` is `passed`, `failed` or `skipped`.
  Date: 2026-09-20

- Decision: Digests are bare lowercase 64-hex strings in a plain scalar, checked by `kenshou evidence check`, not smuggled through a `reference` rule with a `sha256:` URI pattern.
  Rationale: The descriptor language has no digest format. The only regular-expression hook is `externalUriPattern` on a reference rule; using it would make Mori emit a typed graph edge per digest and would misdescribe a checksum as a relationship. The missing format is recorded as an upstream request instead.
  Date: 2026-09-20

- Decision: `data[].uri` is constrained to the single scheme `gs`.
  Rationale: The brief requires refusing non-durable schemes. Google Cloud Storage in project `tan-nb-exp` is the only durable store this initiative has. Widening later is a relaxation and therefore safe for a committed corpus.
  Date: 2026-09-20

- Decision: Link `run-spec`, `run-result`, `manifest`, and every file under `samples/`, `series/`, `verdicts/` and `diagnosis/` individually; link files under `logs/` individually only when the outcome is not `passed` (or with `--link-logs`).
  Rationale: `manifest.json` lists every file with its digest, so the manifest link pins the whole directory transitively. Worker logs are the one unbounded family, and a record with dozens of log links is a record nobody reads; Mori also stores every concept's full frontmatter.
  Date: 2026-09-20

- Decision: A computation definition is versioned by replacement. A change that can alter a result allocates a new `VC-N` and sets `supersedes`; the old definition becomes `status: deprecated` and is never deleted.
  Rationale: Runs name definitions by handle. If a handle's algorithm could change underneath them, an old record would silently claim to have been judged by the new algorithm.
  Date: 2026-09-20

- Decision: Use `okf-core` 0.9.0.0 as a library for reading, serialising, logging and indexing, and the `okf` command line as the gate.
  Rationale: `okf-core` is on Hackage, builds with GHC 9.12.4 (okf itself pins that compiler), and its serialiser is deterministic. A hand-rolled YAML emitter would have to rediscover the coercion hazards recorded in Context and Orientation.
  Date: 2026-09-20

- Decision: The local descriptor is written in three parts: runtime-specific vocabularies, a `shared` profile value, and an overlay that closes `layer` and `tier` again through profile-scope `optional` rules.
  Rationale: `docs/plans/19-…` lifts `shared` into okf-profiles and leaves the keiro-specific vocabularies here. Because profile and type scopes intersect vocabularies by key, the overlay needs no copy of the type rule (verified while drafting).
  Date: 2026-09-20

- Decision: Once the first record is committed, type names and field names are frozen; the profile may only relax.
  Rationale: Records are immutable. Renaming a field or tightening a rule would make committed, unchangeable files fail validation forever.
  Date: 2026-09-20

- Decision: The run's machine `verified` entry is appended only for a `confirmed` attestation, and only once per attester identity.
  Rationale: OKF defines `verified` as independent confirmation that the content is accurate. A refuted or incomplete attestation confirms nothing, and a list that grows on every re-attestation is noise.
  Date: 2026-09-20

- Decision: A record written from a dirty harness must carry `purpose: investigation`.
  Rationale: A modified tree cannot be reproduced from `harnessRevision`. Such a run may still be worth keeping while chasing a defect, but it must never become a baseline.
  Date: 2026-09-20

- Decision: The evidence commands extend the shared CLI interaction contract rather than defining a second command-line style: `record`, `attest`, and `evidence` are in the Evidence group; `history` is in Analysis; options are grouped by purpose; completions are generated from the same parsers; prose lives in the embedded `evidence` help topic; and machine-readable stdout is never mixed with diagnostics.
  Rationale: These commands are automation interfaces as well as operator tools. Following `mori://shinzui/haskell-jitsurei/docs/cli-option-groups`, `mori://shinzui/haskell-jitsurei/docs/cli-help-topics`, `mori://shinzui/haskell-jitsurei/docs/cli-help-width`, and `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions` keeps the growing executable coherent and makes its completion/help surfaces testable from one parser. Evidence commands do not accept versioned documents on standard input, so the `mori://shinzui/haskell-jitsurei/docs/cli-stdin-integration` rule applies only if a future evidence option gains a document source: `-` must then be explicit and unique.
  Date: 2026-09-20

- Decision: Reuse EP-2's Settei configuration seam for evidence storage locations and project defaults, while requiring purpose, subject identity, anomaly authority, and all evidence-bearing inputs to remain explicit.
  Rationale: Bundle roots, GCP projects, and durable URI prefixes are repetitive operator settings whose winning source should be explainable. The resulting record already freezes the effective URI and provenance; allowing purpose or attestation authority to arrive ambiently would make a consequential evidence decision too easy to miss.
  Date: 2026-09-20


## Outcomes & Retrospective

The repository now has a historic OKF evidence bundle with three
versioned computation definitions, recorded runs across correctness, concurrency,
soak, and benchmark, a paired comparison, and their attestations. Two clean
correctness runs and the comparison have confirmed machine verification. The
comparison remains `inconclusive` as a performance decision because the saved
policy requires three pairs and the corpus has one; its attestation confirms
that the recorded calculation and linked bytes are faithful. The other domain
scenario attestations remain `incomplete` on verdict recomputation until their
independent VC-1 oracles are registered by the scenario plans. This is an
explicit evidence limit, not a failure of digest or provenance checks.
The recorded Kafka stability soak adds a second, narrower limit: its historical
record names VC-2 without a measurement summary, so that recomputation is
unavailable as well. New records attach VC-2 only when the summary exists.

The live bucket in `tan-nb-exp` retains versioned objects for five years. Direct
GCS byte hashing, the deep network check, strict OKF validation, profile
rejection fixtures, local evidence checks, the CLI surface test, and the
history-schema fixture establish the evidence path from stored bytes to a
derived baseline. The 2,000-record scale probe completed validation in 6.740
seconds and index generation in 7.732 seconds, below the year-split threshold.

The upstream OKF requests are a decimal field format, a fixed-length lowercase
hex field format for digests and revisions, a type rule that can forbid a core
`status` field on event records, and concept-typed path references. They are
recorded here for the profile publication work; no upstream issue is filed
without the owner's agreement. The local checker enforces these constraints
for this corpus in the meantime. The strongest lesson was to keep the sealed
run result and the scenario's independent oracle distinct: shared checks can
prove the bytes and their internal summaries, but only a domain recomputer can
confirm an arbitrary outcome.


## Context and Orientation

This repository, `keiro-runtime-kenshou`, produces verification evidence about the keiro runtime, a cohort of Haskell libraries (pgmq-hs, kiroku, shibuya and its adapters, keiro). It is governed by the MasterPlan `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this plan is its child number 18 and owns Integration Point 10, "the evidence bundle and its profile". When this plan was drafted the repository held only documents: no Haskell code, no `flake.nix`, no `docs/adr/`. Everything below that is said to "exist" is therefore an expectation about what earlier plans deliver, with a way to check it.

Other repositories are cited by their canonical Mori project URI followed by a project-relative path and, for convenience on the owner's machine, the absolute path. Mori does not yet mint artifact-level URIs for arbitrary source files, so for those the artifact-level URI is pending and the project URI plus path is the reference.

### What this plan expects from earlier plans

`docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` delivers one cabal project whose `cabal.project` matches packages with the glob `kenshou-*/*.cabal` (so creating `kenshou-evidence/kenshou-evidence.cabal` is all it takes to add a package), a Nix development shell with GHC 9.12.4, a `Justfile` with a `verify` umbrella recipe, the ADR bundle `docs/adr/` with its `profile.dhall`, and `kenshou cohort show --json`. A cohort is the exact set of runtime package versions a build links; `cohort/<name>.json` maps every runtime component to its `mori://` project URI, its packages and its version or commit, and the solver plan hash is a hash of the resolved build plan. Check with `ls cabal.project Justfile docs/adr/profile.dhall cohort/` and `cabal run kenshou -- cohort show --json`.

`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` delivers the package `kenshou-core` (namespace `Kenshou.Core.*`), the executable `kenshou` in `kenshou-cli`, the directory `schemas/`, and the run directory. A run is identified by a UUIDv7 (a 128-bit identifier whose first 48 bits are a millisecond timestamp, so identifiers sort by creation time) rendered as lowercase text. A run directory has this shape, and a later run never writes into an earlier run's directory:

```text
<out>/<run-id>/
  run-spec.json          kenshou.run-spec/v1          scenario id, knobs, dimensions, environment, seed, phases, cohort expectation
  run-result.json        kenshou.run-result/v1        outcome, timings, cohort identity, environment fingerprint, summaries
  manifest.json          kenshou.artifact-manifest/v1 every file: relative path, sha256, bytes, media type
  samples/<op>.hist      latency histograms and raw sample spill files
  series/*.csv           time series
  verdicts/<checker>.json  kenshou.verdict/v1
  diagnosis/*.json       kenshou.diagnosis/v1
  logs/                  stdout and stderr of the harness and of every worker process
```

A scenario identifier is the four-segment path `<layer>/<component>/<kind>/<name>`. The layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`; the kind is one of `correctness`, `concurrency`, `soak`, `benchmark`; the cost tier is one of `smoke`, `standard`, `extended`, `soak`. Outcomes use one vocabulary everywhere: `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`. Knobs are per-scenario typed parameters; dimensions are cross-cutting switches (`telemetry.tracing`, `telemetry.metrics`, `pg.durability`, `pg.version`) whose values are text. Exit codes are part of the command-line contract: 0 for passed or pass, 1 for failed or regression, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure. Check with `cabal run kenshou -- list --json` and by running any `selftest` scenario and listing its output directory.

`docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` delivers `kenshou-measure` (`Kenshou.Measure.*`), `kenshou summarize`, and `kenshou compare`, which writes a `kenshou.comparison/v1` document whose verdict is `pass`, `regression`, `inconclusive` or `infrastructure-failure`. Check with `cabal run kenshou -- compare --help`.

Three facts this plan needs are not stated by the MasterPlan's integration points, so confirm them before Milestone 2 and, where one is missing, update Integration Point 5 in the MasterPlan first and then the kernel: the run result must carry the harness's own git revision and a dirty flag (a Nix build has no `.git` directory, so the revision has to be injected at build time, for example from an environment variable the flake sets, with a compile-time fallback to `git rev-parse` for cabal builds); the run result or run specification must carry the scenario's tier, its known-defect reference if any, and whether it ran on a cell; and the comparison document must name the run identifiers of both arms. Soft dependencies make this plan better but must not block it: `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` (invariant verdicts), `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` (leak and stall diagnoses), `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` (the cell's results bucket) and `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` (`kenshou cell fetch`). Two more plans are mentioned below: `docs/plans/3-plan-and-select-runs-from-what-changed.md` owns the component graph, and `docs/plans/19-publish-the-verification-evidence-profile-in-okf-profiles.md` publishes the shared profile once this corpus exists. After this paragraph a plan is abbreviated to its number and an ellipsis, for example `docs/plans/19-…`.

### Terms

OKF, the Open Knowledge Format, is a directory tree of Markdown files with YAML frontmatter (the metadata block between two `---` lines at the top of a file). The directory is a bundle; each Markdown file other than the reserved `index.md` and `log.md` is a concept, identified by its path without `.md`. `type` is the only key OKF itself requires. The house tool `okf` (`mori://shinzui/okf`, `/Users/shinzui/Keikaku/bokuno/okf`, installed version 0.9.0.0) validates, indexes and queries bundles; it implements OKF v0.2.

A profile is a Dhall file (Dhall is a typed configuration language) that states a team's house rules for a bundle: which types exist, which keys each requires, closed vocabularies, value formats, where files must live. `okf validate BUNDLE --strict --profile P --profile-enforce --log-enforce` is the failing gate: `--strict` adds authoring lint (`title`, `description`, `generated`), `--profile-enforce` turns profile deviations into exit code 1, and `--log-enforce` fails when a concept's `generated.at` date is newer than the newest entry of its nearest enclosing `log.md`. The shared catalog of profiles is `mori://shinzui/okf-profiles` (`/Users/shinzui/Keikaku/bokuno/okf-profiles`, release v0.18.0); its `package.dhall` re-exports okf's schema records (`Profile`, `TypeRule`, `FrontmatterRules`, `FieldRule`, `NestedRules`, `NestedFieldRule`, `HandleReferenceRule`, `PathReferenceRule`, `Cardinality`, `FieldFormat`, `mk`) and the six OKF v0.2 field families as `v02` (`generated`, `verified`, `status`, `staleAfter`, `sources`, `usageWindow`), so a local descriptor imports that one pinned package and never imports okf directly.

An actor is OKF's spelling of who acted, in exactly three shapes: `<producer>/<version>` for a tool, `process:<id>` for an automated process, and `human:<id>` for a person. `generated: {by, at}` says who produced a concept's current content; `verified` is an append-only list of `{by, at}` confirmations. okf derives a trust tier from `verified` on every read and never stores it: `unverified`, `machine-confirmed`, or `human-reviewed` when any entry is a `human:` actor. An agent must never write a `human:` actor; only a person types one.

An `Attested Computation` is the one OKF v0.2 type with its own contract: `runtime` (required for the type), `parameters` (a list of `{name, type, required}`), the computation itself (exactly one code block under a `# Computation` heading, fenced or indented by four spaces, or a `computation` path, never both), `executor {resource, receipt}` (run instructions and the names of what a run must return) and `attester {resource}` (deterministic code, with no language model in it, that checks what a run returned). okf records such definitions and never runs or attests them, which is why run records and attestations are new house types here.

A document handle is a short stable identifier of the form `PREFIX-N` (`ADR-7`, `VC-2`) stored in the frontmatter key a profile names as `idField`. Path addressing is the alternative: the concept's path is its identity. A digest here always means the lowercase hexadecimal SHA-256 of a file's bytes, 64 characters; a revision always means a full 40-character git commit hash, never a branch or tag, which move. Durable object storage means a Google Cloud Storage (GCS) bucket in the project `tan-nb-exp` with a retention policy, so an object can be neither deleted nor replaced before the retention period passes; `gs://bucket/key` is its URI form. Mori (`mori://shinzui/mori`) is the house catalog that indexes OKF bundles declared in a repository's `mori.dhall` and makes a concept addressable as `mori://<namespace>/<project>/okf/<bundle>/concepts/<handle-or-path>`.

### What was verified while drafting, and what was not

The following was checked on 2026-09-20 with okf 0.9.0.0 and dhall 1.42.3 against a throwaway bundle; the implementer should expect to reproduce each result. The pinned import of okf-profiles v0.18.0 freezes to `sha256:7d3a4a22be12fd0e697d6012ed1eb2efe4cb5dc4700d08fd49aa5e4c0e523df8`, the hash the catalog's own header states. The descriptor in Milestone 1 type-checks, loads, and validates the three example concepts printed in this plan, together with a comparison record, a second run and two more definitions, under `--strict --profile-enforce --log-enforce`.

Twenty rejection probes behaved as designed, including an undeclared key (`frontmatter field not declared by profile: p99Millis`), a non-`gs` data URI, a duplicate data URI, a dangling `VC-9`, a dangling `previousRun` and `comparison.baselineRuns[0]`, a run without `cohort` (`missing profile-required field: cohort (when recordKind is run)`), a git-sourced component without `revision`, a comparison record without its `comparison` object, a textual `seed`, a textual `harnessDirty`, an out-of-vocabulary `outcome`, a non-actor `attester`, a `process:` exception authority, a duplicate check name, and a run outside `runs/*/*/*/*`.

`okf id next BUNDLE VC --profile …` answered `VC-3` for a bundle holding `VC-1` and `VC-2`. `okf log add BUNDLE <concept-id> --kind Addition -m …` created `runs/kiroku/2026/09/log.md`, which is how per-month log shards arise with no extra machinery. A `verified` entry by `process:kenshou-attester/0.1.0.0` validates and `okf trust` then reports `machine-confirmed`. A synthetic bundle of 2,006 concepts validated in about 2.0 seconds and re-indexed in about 1.5 seconds on a laptop, roughly one millisecond per concept. The `mori.dhall` fragment in Milestone 1 type-checks against the mori-schema commit this repository already pins.

Five discoveries from that session shape the design. A rule that names a textual format and no cardinality compiles to `any`, and `uniqueBy` then fails to load with `uniqueBy field must be scalar at data.uri, found: any`; every helper in the descriptor therefore sets `Scalar` explicitly. OKF core keys are always permitted, so `status: stable` on a run is not rejected even with `allowUnknownFields = False`; the repository-local check must forbid it. The YAML reader coerces: an unquoted `off` became the boolean `false`, and a digest consisting of digits with one `e` became a number, and both still satisfied `Scalar`; records must be written through a YAML library that quotes such strings, and the local check must insist on JSON strings. `okf concepts --json` rows carry the whole frontmatter but no path, so a record must identify itself (`runId`, `layer`, `startedAt` rebuild the path). Closing `layer` with a profile-scope `optional` rule makes `layer` a declared key for every type, so an attestation carrying a stray `layer` is no longer rejected by okf; the local check covers that too.

Not verified: that `okf-core` resolves inside this repository's cohort solver plan; that the `yaml` library's encoder quotes every hazardous string (the property test in Milestone 2 is the proof); the exact `gcloud storage` flags in Concrete Steps; how Mori indexes the new bundle (`mori register` was not run); and every JSON field name of the kernel documents, which did not exist yet.

### Relevant decisions in other repositories

There is no local ADR corpus yet: `docs/adr/` is created by `docs/plans/1-…` as a profile-governed OKF bundle, and this plan adds to it. The cross-repository decisions that bind this work are these. `mori://shinzui/okf/okf/adrs/concepts/ADR-14` states that okf records computations and the means to check them and never executes or attests anything; receipts and verdicts are runtime artifacts okf will never see. Storing run records and attestations is therefore a house convention with new types, not a reinterpretation of `Attested Computation`. `mori://shinzui/okf/okf/adrs/concepts/ADR-13` states that a non-Markdown file in a bundle is a file, never a concept, that it is listed under `# Files` in generated indexes, and that a profile `path` rule checks that it exists. `mori://shinzui/okf/okf/adrs/concepts/ADR-8` states that trust and credibility are derived on read and never stored, the same rule this plan applies to baselines.

`mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence, makes re-import of identical content a successful no-op and different content under the same key a conflict, derives freshness at query time, and warns that repeated runs need an explicit run identity because time is not identity; the run record adopts all four.

In okf-profiles the registry lags the repository, so the following handles are the intended references and do not resolve yet: `mori://shinzui/okf-profiles/okf/adrs/concepts/ADR-6` excludes the `Attested Computation` type from the catalog until a consumer writes one (this corpus is that consumer, and `docs/plans/19-…` amends the record); `mori://shinzui/okf-profiles/okf/adrs/concepts/ADR-10` establishes that a review is an artifact and not only an annotation, the modelling precedent for an event record with no `status` and no `stale_after`; `mori://shinzui/okf-profiles/okf/adrs/concepts/ADR-1` and `ADR-8` of the same bundle govern when a profile takes OKF's `status` and how presence classes are chosen (a field is `optional` when a complete, correct document would still lack it). The modelling precedent itself is `mori://shinzui/okf-profiles` at `profiles/assurance/reviews.dhall` (`/Users/shinzui/Keikaku/bokuno/okf-profiles/profiles/assurance/reviews.dhall`), and the house template for the computation type is `mori://shinzui/okf` at `okf-core/test/fixtures/profiles/attested-computation-house.dhall`.

This plan owns one ADR named by the MasterPlan: evidence records are immutable events that link to data and never contain it, and baselines are derived, not stored. It adds a second: the evidence corpus freezes its type and field names, and its profile may only relax. Create each with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.

### Frozen field names

Because a committed record can never be edited, the following names are frozen from the first commit of Milestone 4, and the shared profile that `docs/plans/19-…` publishes may relax rules about them but never rename them. The type strings are `Attested Computation`, `Verification Run` and `Attestation`. The handle field is `computationId` with prefix `VC`; it is the profile's `idField`. The comparison discriminator is `recordKind`, with values `run` and `comparison`, and the comparison payload is the object `comparison` with members `verdict`, `factor`, `factorName`, `baselineValue`, `candidateValue`, `design`, `baselineRuns`, `candidateRuns`. The identity fields are `runId` and `attestationId`. The run's other fields are `purpose`, `scenario`, `layer`, `component`, `kind`, `tier`, `placement`, `outcome`, `startedAt`, `finishedAt`, `subject`, `subjectKind`, `harnessRevision`, `harnessDirty`, `computations`, `data` (`kind`, `uri`, `digest`, `mediaType`, `bytes`), `cohort`, `solverPlanHash`, `components` (`project`, `package`, `version`, `source`, `revision`), `environment`, `seed`, `compatibilityKey`, `knobs` and `dimensions` (`name`, `value`), `knownDefects`, `produced`, `previousRun`. The attestation's are `run`, `attester`, `attesterRevision`, `attestedAt`, `verdict`, `checks` (`name`, `result`, `detail`), `dataDigests`, `exception` (`authority`, `reason`). The definition's house fields are `algorithm`, `algorithmVersion`, `produces`, `inputs`, `implementation`, `appliesTo`, `supersedes`.


## Plan of Work

### Milestone 1 — The bundle, the local profile and the first computation definitions

This milestone creates the bundle as plain files, with no Haskell. At its end `docs/verification/` exists with a root index declaring `okf_version: "0.2"`, a root `log.md`, the local `profile.dhall`, two reference scripts, three computation definitions with handles `VC-1` to `VC-3`, a rejection-fixture script, a `mori.dhall` entry and three `Justfile` recipes (`evidence-validate`, `evidence-index-check`, `evidence-profile-test`) hung on `verify`. The command `okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce` prints `OK: 3 concepts (okf_version 0.2)` and `bash scripts/test-verification-profile.sh` prints one `rejected as expected` line per fixture.

The layout is fixed as follows. okf requires every path segment to start with an ASCII letter, digit or underscore and to continue with only ASCII letters, digits, underscore, dot and hyphen, which a lowercase UUID, a four-digit year and a two-digit month all satisfy.

```text
docs/verification/
  index.md                                   generated; root declares okf_version "0.2"
  log.md                                     bundle-level changes: profile, definitions
  profile.dhall                              local descriptor (listed under "# Files", not a concept)
  computations/<name>.md                     type Attested Computation, handle VC-N
  references/executors/kenshou-run.sh        executor.resource target (non-Markdown on purpose)
  references/attesters/kenshou-attest.sh     attester.resource target (non-Markdown on purpose)
  runs/<layer>/<YYYY>/<MM>/<run-id>.md       type Verification Run; YYYY/MM from startedAt in UTC
  runs/<layer>/<YYYY>/<MM>/log.md            per-month log shard, created by the first record of the month
  attestations/<YYYY>/<MM>/<attestation-id>.md   type Attestation; YYYY/MM from attestedAt in UTC
  attestations/<YYYY>/<MM>/log.md            per-month log shard
```

Sharding by layer, year and month keeps every generated `index.md` and every `log.md` bounded, and makes a later split into per-year bundles a `git mv`. The path patterns are `computations/*`, `runs/*/*/*/*` and `attestations/*/*/*`, where `*` matches exactly one segment. The pattern cannot say that the layer segment equals the `layer` field or that the month matches `startedAt`; `kenshou evidence check` does.

Create `docs/verification/profile.dhall` with exactly the content below, then run `dhall freeze docs/verification/profile.dhall` and `dhall format docs/verification/profile.dhall`. Never type a `sha256:` value by hand; `dhall freeze` must reproduce the hash shown, and if it does not, stop and find out why. The descriptor has three parts on purpose: the runtime-specific vocabularies, the value `shared` that `docs/plans/19-…` will lift into okf-profiles as `assurance.verificationEvidence`, and an overlay. After that plan, this file shrinks to the runtime-specific vocabularies, the pinned import of the published profile standing where `shared` stands now, and the same overlay; the `mori.dhall` binding becomes `Published` with `derived = True`.

```dhall
--| Local profile for the kenshou verification evidence bundle (docs/verification).
--
-- Three concept types: `Attested Computation` (a definition, handle VC-N),
-- `Verification Run` (an immutable event: one run, or one comparison of runs) and
-- `Attestation` (an immutable event: what a deterministic verifier concluded).
-- Records carry identity, provenance, outcome and digest-pinned links to data in
-- durable object storage. They never carry a measurement: `allowUnknownFields =
-- False` is what turns a stray `p99Millis:` into a validation failure.
--
-- The file has three parts so that the shared profile can later be lifted into
-- okf-profiles without touching the rest: (1) vocabularies that belong to the
-- keiro runtime and stay here, (2) `shared`, the part that is lifted, and (3) the
-- overlay that closes the runtime-specific vocabularies again.
--
-- What no descriptor can express is checked by `kenshou evidence check`.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/package.dhall
        sha256:7d3a4a22be12fd0e697d6012ed1eb2efe4cb5dc4700d08fd49aa5e4c0e523df8

let Profile = Profiles.Profile

let TypeRule = Profiles.TypeRule

let FrontmatterRules = Profiles.FrontmatterRules

let FieldRule = Profiles.FieldRule

let NestedRules = Profiles.NestedRules

let NestedFieldRule = Profiles.NestedFieldRule

let HandleReferenceRule = Profiles.HandleReferenceRule

let PathReferenceRule = Profiles.PathReferenceRule

let Cardinality = Profiles.Cardinality

let FieldFormat = Profiles.FieldFormat

let v02 = Profiles.v02

-- Part 1. Runtime-specific vocabularies. They mirror Integration Point 3 of the
-- MasterPlan and stay in this repository when `shared` moves upstream.
let runtimeSpecific =
      { layers =
        [ "selftest", "pgmq", "kiroku", "shibuya", "kafka", "keiro", "runtime" ]
      , tiers = [ "smoke", "standard", "extended", "soak" ]
      }

-- Generic vocabularies. They move upstream with `shared`.
let kinds = [ "correctness", "concurrency", "soak", "benchmark" ]

let placements = [ "local", "cell" ]

let outcomes =
      [ "passed", "failed", "errored", "inconclusive", "infrastructure-failure" ]

let comparisonVerdicts =
      [ "pass", "regression", "inconclusive", "infrastructure-failure" ]

let purposes = [ "nightly", "release", "baseline", "investigation" ]

let dataKinds =
      [ "run-spec"
      , "run-result"
      , "manifest"
      , "cell-manifest"
      , "samples"
      , "series"
      , "verdicts"
      , "diagnosis"
      , "logs"
      , "comparison"
      ]

let checkNames =
      [ "digests-match"
      , "revisions-resolve"
      , "cohort-matches-plan"
      , "verdict-recomputed"
      , "environment-captured"
      , "clean-worktree"
      ]

-- Every helper sets `Scalar` explicitly: a textual format alone compiles to
-- `any`, and `uniqueBy` and `when` both demand an explicit scalar.
let scalar =
      \(name : Text) ->
      \(description : Text) ->
        FieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.Scalar
        }

let enum =
      \(name : Text) ->
      \(description : Text) ->
      \(allowedValues : List Text) ->
        scalar name description // { allowedValues }

let formatted =
      \(name : Text) ->
      \(description : Text) ->
      \(format : FieldFormat) ->
        scalar name description // { format = Some format }

let list =
      \(name : Text) ->
      \(description : Text) ->
        FieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.List
        }

let nScalar =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.Scalar
        }

let nEnum =
      \(name : Text) ->
      \(description : Text) ->
      \(allowedValues : List Text) ->
        nScalar name description // { allowedValues }

let nFormatted =
      \(name : Text) ->
      \(description : Text) ->
      \(format : FieldFormat) ->
        nScalar name description // { format = Some format }

let nPaths =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , cardinality = Cardinality.List
        , path = Some PathReferenceRule::{=}
        }

let nPath =
      \(name : Text) ->
      \(description : Text) ->
        NestedFieldRule::{
        , field = name
        , description = Some description
        , path = Some PathReferenceRule::{=}
        }

let bundlePath =
      \(name : Text) ->
      \(description : Text) ->
        scalar name description // { path = Some PathReferenceRule::{=} }

let computationRef = Some HandleReferenceRule::{ localPrefix = "VC" }

let isRun = Some { field = "recordKind", hasValue = [ "run" ] }

let isComparison = Some { field = "recordKind", hasValue = [ "comparison" ] }

let nameValue =
      NestedRules::{
      , required =
        [ nScalar "name" "Name, as the harness spells it."
        , nScalar "value" "Value the run used."
        ]
      }

-- Attested Computation ------------------------------------------------------
let attestedComputation =
      TypeRule::{
      , type = "Attested Computation"
      , description = Some
          "How one outcome, verdict or figure is computed from raw run data, and how a deterministic verifier re-checks it."
      , pathPattern = Some "computations/*"
      , idPrefix = Some "VC"
      , frontmatter = FrontmatterRules::{
        , required =
          [ formatted
              "computationId"
              "Bundle-scoped stable VC-N handle."
              (FieldFormat.DocumentHandle "VC")
          , scalar "runtime" "How the computation is run: `kenshou`."
          , scalar "algorithm" "Identifier the harness writes into its documents."
          , formatted
              "algorithmVersion"
              "A change that can alter a result takes a new VC handle."
              FieldFormat.NonNegativeInteger
          , enum
              "produces"
              "What the computation yields."
              [ "outcome", "verdict", "diagnosis", "comparison", "summary" ]
          ,     list "inputs" "Data-link kinds the computation reads."
            //  { allowedValues = dataKinds }
          , scalar "implementation" "Haskell module implementing the algorithm."
          ,     list "parameters" "Typed named holes; empty when it takes none."
            //  { elementFields = Some NestedRules::{
                  , required =
                    [ nScalar "name" "The name the computation binds."
                    , nScalar "type" "What kind of value it takes."
                    ]
                  , optional =
                    [ nFormatted
                        "required"
                        "Whether a caller must supply it."
                        FieldFormat.Boolean
                    ]
                  }
                }
          , FieldRule::{
            , field = "executor"
            , description = Some "How a run is performed and what it returns."
            , objectFields = Some NestedRules::{
              , required =
                [ nPath "resource" "Run instructions: a non-Markdown file here."
                ,     nScalar "receipt" "Run-directory documents a run returns."
                  //  { cardinality = Cardinality.List }
                ]
              }
            }
          , FieldRule::{
            , field = "attester"
            , description = Some "Deterministic code that re-checks a run."
            , objectFields = Some NestedRules::{
              , required =
                [ nPath "resource" "The verifier: a non-Markdown file here." ]
              }
            }
          ]
        , optional =
          [ v02.status
          , v02.staleAfter
          ,     list "appliesTo" "Evidence kinds whose runs may name it."
            //  { allowedValues = kinds }
          , bundlePath "computation" "The computation file, when not inline."
          ,     scalar "supersedes" "The definition this one replaces."
            //  { reference = computationRef }
          ]
        }
      }

-- Verification Run ----------------------------------------------------------
let componentMembers =
      NestedRules::{
      , required =
        [ nFormatted
            "project"
            "Mori URI of the owning project."
            (FieldFormat.UriWithScheme "mori")
        , nScalar "package" "Cabal package name."
        , nScalar "version" "Exact resolved version."
        , nEnum "source" "Where the solver took it from." [ "hackage", "git" ]
        ,     nScalar "revision" "Full 40-character commit."
          //  { when = Some { field = "source", hasValue = [ "git" ] } }
        ]
      }

let environmentMembers =
      NestedRules::{
      , required =
        [ nScalar "os" "Operating system."
        , nScalar "arch" "CPU architecture."
        , nScalar "cpuModel" "CPU model string."
        , nFormatted "cores" "Logical cores." FieldFormat.NonNegativeInteger
        , nFormatted
            "memoryBytes"
            "Physical memory."
            FieldFormat.NonNegativeInteger
        , nScalar "ghc" "Compiler that built the harness."
        , nScalar "postgres" "PostgreSQL server version."
        ]
      , optional =
        [ nScalar "kernel" "Kernel release."
        , nScalar "machineType" "Cloud machine type of the driver."
        , nScalar "cell" "Name of the leased cell."
        , nScalar "cellRun" "The cell's own identifier for the leased run."
        , nScalar "zone" "Cloud zone."
        , nScalar "kafka" "Broker version, when a broker took part."
        ]
      }

let dataMembers =
      NestedRules::{
      , required =
        [ nEnum "kind" "What the object is." dataKinds
        , nFormatted
            "uri"
            "Where the object lives in durable storage."
            (FieldFormat.UriWithScheme "gs")
        , nScalar "digest" "Lowercase 64-hex SHA-256 of the object."
        , nScalar "mediaType" "IANA media type."
        , nFormatted "bytes" "Object size." FieldFormat.NonNegativeInteger
        ]
      }

let comparisonMembers =
      NestedRules::{
      , required =
        [ nEnum "verdict" "What the comparison concluded." comparisonVerdicts
        , nEnum
            "factor"
            "What differs between the arms."
            [ "cohort", "harness", "dimension", "knob" ]
        , nScalar "baselineValue" "The factor's value on the baseline arm."
        , nScalar "candidateValue" "The factor's value on the candidate arm."
        , nEnum
            "design"
            "How the arms were interleaved."
            [ "abba", "baab", "sequential" ]
        , nPaths "baselineRuns" "Recorded runs of the baseline arm."
        , nPaths "candidateRuns" "Recorded runs of the candidate arm."
        ]
      , optional =
        [ nScalar "factorName" "Which dimension, knob or package differs." ]
      }

let verificationRun =
      TypeRule::{
      , type = "Verification Run"
      , description = Some
          "One recorded run, or one recorded comparison of runs: what ran, against what, where, with which outcome, and where the data is."
      , pathPattern = Some "runs/*/*/*/*"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "runId" "UUIDv7 of the record. Equals the file name."
          , enum
              "recordKind"
              "One run, or a comparison of runs."
              [ "run", "comparison" ]
          , enum "purpose" "Why this was recorded." purposes
          , scalar "scenario" "Scenario identifier: layer/component/kind/name."
          , scalar "layer" "Runtime layer the scenario isolates."
          , scalar "component" "Component inside the layer."
          , enum "kind" "Kind of evidence." kinds
          , scalar "tier" "Cost tier."
          , enum "placement" "Where it ran." placements
          , enum "outcome" "What came of it." outcomes
          , formatted "startedAt" "UTC start." FieldFormat.Rfc3339Utc
          , formatted "finishedAt" "UTC finish." FieldFormat.Rfc3339Utc
          , formatted
              "subject"
              "Mori URI of the most specific runtime artifact under test."
              (FieldFormat.UriWithScheme "mori")
          , enum "subjectKind" "What `subject` names." [ "project", "package" ]
          , scalar "harnessRevision" "Full 40-character commit of the harness."
          , formatted
              "harnessDirty"
              "Whether the harness was built from a modified tree."
              FieldFormat.Boolean
          ,     list "computations" "Definitions that produced the outcome."
            //  { reference = computationRef }
          ,     list "data" "Digest-pinned links to the data."
            //  { elementFields = Some dataMembers, uniqueBy = Some "uri" }
          ,     scalar "cohort" "Name of the cohort the build linked."
            //  { when = isRun }
          ,     scalar "solverPlanHash" "Hash of the resolved solver plan."
            //  { when = isRun }
          ,     list "components" "Every runtime package the build linked."
            //  { elementFields = Some componentMembers
                , uniqueBy = Some "package"
                , when = isRun
                }
          , FieldRule::{
            , field = "environment"
            , description = Some "Flat excerpt of the environment fingerprint."
            , objectFields = Some environmentMembers
            , when = isRun
            }
          ,     formatted
                  "seed"
                  "Seed of every random choice."
                  FieldFormat.NonNegativeInteger
            //  { when = isRun }
          ,     scalar
                  "compatibilityKey"
                  "64-hex digest of what must match for two runs to be comparable."
            //  { when = isRun }
          , FieldRule::{
            , field = "comparison"
            , description = Some "The arms and the verdict."
            , objectFields = Some comparisonMembers
            , when = isComparison
            }
          ]
        , optional =
          [     list "knobs" "Knob values the run used."
            //  { elementFields = Some nameValue, uniqueBy = Some "name" }
          ,     list "dimensions" "Dimension values the run used."
            //  { elementFields = Some nameValue, uniqueBy = Some "name" }
          ,     list "knownDefects" "Known-defect references of the scenario."
            //  { format = Some FieldFormat.Uri }
          ,     list "produced" "Mori URIs of reports this run caused."
            //  { format = Some (FieldFormat.UriWithScheme "mori") }
          , bundlePath
              "previousRun"
              "Latest earlier record of the same scenario and compatibility key."
          ]
        }
      }

-- Attestation ---------------------------------------------------------------
let attestation =
      TypeRule::{
      , type = "Attestation"
      , description = Some
          "A deterministic verifier fetched a record's data, re-checked it, and this is what it concluded."
      , pathPattern = Some "attestations/*/*/*"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "attestationId" "UUIDv7. Equals the file name."
          , bundlePath "run" "The record attested."
          , formatted "attester" "The verifier, as an OKF actor." FieldFormat.Actor
          , scalar "attesterRevision" "Full 40-character commit of the verifier."
          , formatted "attestedAt" "UTC completion time." FieldFormat.Rfc3339Utc
          , enum
              "verdict"
              "What the verifier concluded."
              [ "confirmed", "refuted", "incomplete" ]
          ,     list "checks" "Every check, and what it found."
            //  { elementFields = Some NestedRules::{
                  , required =
                    [ nEnum "name" "Which check." checkNames
                    , nEnum
                        "result"
                        "What it found."
                        [ "passed", "failed", "skipped" ]
                    ]
                  , optional = [ nScalar "detail" "One line saying why." ]
                  }
                , uniqueBy = Some "name"
                }
          , list
              "dataDigests"
              "64-hex SHA-256 of every object fetched and matched."
          ]
        , optional =
          [ FieldRule::{
            , field = "exception"
            , description = Some "A human's acceptance of an anomaly."
            , objectFields = Some NestedRules::{
              , required =
                [ nFormatted
                    "authority"
                    "The human who accepted it."
                    FieldFormat.HumanActor
                , nScalar "reason" "Why the anomaly is acceptable."
                ]
              }
            }
          ]
        }
      }

-- Part 2. The shareable profile: what is lifted into okf-profiles.
let shared =
      Profile::{
      , name = "verification-evidence"
      , description = Some
          "Evidence about a runtime: definitions of how verdicts are computed, immutable records of runs that link to their data by digest, and attestations that a deterministic verifier re-checked that data."
      , okfVersion = "0.2"
      , requireBundleVersion = Some "0.2"
      , allowUnknownTypes = False
      , allowUnknownFields = False
      , idField = Some "computationId"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "type" "One of the three concept types."
          , scalar "title" "What this record is, in one line."
          , scalar "description" "One sentence a reader can evaluate alone."
          , v02.generated
          ]
        , optional = [ v02.verified ]
        }
      , types = [ attestedComputation, verificationRun, attestation ]
      }

-- Part 3. The local overlay. Profile and type scopes intersect vocabularies by
-- key, so an `optional` profile-scope rule closes `layer` and `tier` without
-- restating the type rule that demands them.
in      shared
    //  { frontmatter =
                shared.frontmatter
            //  { optional =
                      shared.frontmatter.optional
                    # [ enum
                          "layer"
                          "Runtime layer the scenario isolates."
                          runtimeSpecific.layers
                      , enum "tier" "Cost tier." runtimeSpecific.tiers
                      ]
                }
        }
```

Several policy choices in that descriptor deserve their reasons. `generated` is required and `verified` optional at profile scope, as everywhere in the catalog. The definition type takes OKF's own `status` and `stale_after` because a definition has a lifecycle; the two event types take neither, following `assurance.reviews`: an event is never redrafted and does not decay, and a later record supersedes it by existing. `guidance` is left at its default `None Text`, per the catalog's policy. Presence classes follow the rule that a field is `optional` when a complete, correct record would still lack it: a scenario with no knobs has no `knobs`, because okf treats an empty list as absent. The one-level nesting limit of the descriptor language (a nested rule cannot itself contain nested rules) is why `environment` is a flat mapping and why `components`, `data`, `knobs`, `dimensions` and `checks` are lists of flat records.

The `Verification Run` fields, one by one, with what checks each. "Profile" means `okf validate`; "local" means `kenshou evidence check` from Milestone 2.

- `runId` — the kernel's UUIDv7 for a run; for a comparison, the identifier the comparison document carries or, failing that, one minted by the recorder. Profile: required scalar. Local: lowercase UUID, version 7, RFC 4122 variant, equal to the file name.
- `recordKind` — `run` or `comparison`. Profile: closed enum; gates the conditional fields below.
- `purpose` — why the run was kept: `nightly`, `release`, `baseline` (a run made on purpose to give later comparisons a compatible reference; it does not make the run "the" baseline, which readers still derive), `investigation`. Profile: closed enum. Local: a dirty harness requires `investigation`.
- `scenario`, `layer`, `component`, `kind` — the scenario identifier and three of its segments, repeated as separate keys because `okf concepts --where` filters only by equality. Profile: `kind` closed; `layer` closed by the overlay. Local: `scenario` has four segments and they equal `layer`, `component`, `kind`; the path's layer segment equals `layer`.
- `tier`, `placement`, `outcome` — cost tier, where the run actually executed (`local` or `cell`; a scenario's `either` is resolved by then), and the kernel outcome. Profile: closed enums (`tier` by the overlay). Local: a comparison's `outcome` is the image of `comparison.verdict` (`pass` to `passed`, `regression` to `failed`, the other two unchanged), so one outcome query covers both record kinds.
- `startedAt`, `finishedAt` — from the run result. Profile: RFC 3339 UTC. Local: `startedAt <= finishedAt <= generated.at`; the path's year and month equal `startedAt`.
- `subject`, `subjectKind` — the Mori URI of the most specific runtime artifact under test and whether it is a `project` or a `package`, the identity pair borrowed from `assurance.reviews`. The default comes from a layer table in `Kenshou.Evidence.Subject` (`pgmq` to `mori://shinzui/pgmq-hs`, `kiroku` to `mori://shinzui/kiroku`, `shibuya` to `mori://shinzui/shibuya`, `kafka` to `mori://shinzui/shibuya-kafka-adapter`, `keiro` and `runtime` to `mori://shinzui/keiro`, `selftest` to `mori://shinzui/keiro-runtime-kenshou`), overridable with `--subject` and `--subject-kind`; when the component graph of `docs/plans/3-…` exists, use it to name the package instead. Profile: `mori` scheme, closed enum.
- `harnessRevision`, `harnessDirty` — commit of this repository that built the `kenshou` binary that ran, and whether its tree was modified. Profile: scalar; boolean. Local: 40 lowercase hex, a JSON string.
- `computations` — handles of the definitions under which the outcome was produced; at least `VC-1`. Profile: local `VC` references that must resolve in this bundle. Local: each definition's `appliesTo`, when present, contains the run's `kind`.
- `data` — one entry per linked object: `kind` (closed), `uri` (`gs` only), `digest`, `mediaType`, `bytes`. Profile: required members, `uniqueBy uri`, non-negative integer size. Local: digest is 64 lowercase hex and a JSON string; a run links exactly one `manifest`, one `run-spec` and one `run-result`, and a `cell-manifest` exactly when `placement` is `cell`; a comparison links exactly one `comparison`; every URI contains the record's identifier; with `--network`, each object exists with the stated size, and with `--network --deep` its bytes hash to the digest.
- `cohort`, `solverPlanHash`, `components` — the cohort's name, the hash of its resolved build plan, and every runtime package of the cohort identity (not transitive Hackage dependencies) with `project`, `package`, `version`, `source` (`hackage` or `git`) and, for `git`, `revision`. Profile: required when `recordKind` is `run`; `uniqueBy package`; `revision` required when `source` is `git`. Local: hex shapes.
- `environment` — a flat excerpt of the run result's fingerprint: `os`, `arch`, `cpuModel`, `cores`, `memoryBytes`, `ghc`, `postgres`, and optionally `kernel`, `machineType`, `cell`, `cellRun`, `zone`, `kafka`. Integers only, because the descriptor language has no decimal format. Profile: required members and integer formats. Local: `cell` and `cellRun` present exactly when `placement` is `cell`.
- `seed` — Profile: non-negative integer, required for runs. If the kernel's seed turns out to be textual, change this one rule to a plain scalar before the first record is committed and note it in the Decision Log.
- `compatibilityKey` — the SHA-256 of the canonical JSON (keys sorted, no insignificant whitespace) of `{"schema":"kenshou.compatibility-key/v1","scenario":…,"knobs":[…sorted by name…],"dimensions":[…sorted by name…],"placement":…,"environmentClass":{"arch","cpuModel","cores","memoryBytes","machineType","postgres"}}`. Two runs are comparable when their keys are equal; the cohort, the seed and the harness revision are deliberately outside it because they are what varies. If `docs/plans/4-…` already defines a compatibility key in its documents, copy that value verbatim instead and record the decision.
- `comparison` — required when `recordKind` is `comparison`: `verdict`, `factor` (what differs between the arms: `cohort`, `harness`, `dimension` or `knob`), optional `factorName`, `baselineValue`, `candidateValue`, `design` (`abba`, `baab` or `sequential`), and `baselineRuns` and `candidateRuns` as bundle paths to run records. Profile: every path must exist. Local: every target is a `recordKind: run` record of the same `scenario`.
- `knobs`, `dimensions` — lists of `{name, value}`. Profile: `uniqueBy name`. Local: every dimension value is a JSON string (this is what catches an unquoted `off`).
- `knownDefects` — absolute URIs the scenario declares as known defects. `produced` — Mori URIs of bug reports or improvement requests this run caused. `previousRun` — bundle path of the latest earlier record with the same `scenario` and `compatibilityKey` at recording time; a convenience chain, never a baseline. Profile: URI formats; path exists. Local: `previousRun` targets an earlier run of the same scenario.

The `Attestation` fields: `attestationId` (UUIDv7, equals the file name), `run` (bundle path to the record attested), `attester` (the actor `process:kenshou-attester/<kenshou-evidence version>`), `attesterRevision` (commit of this repository that built the attester), `attestedAt`, `verdict`, `checks` (all six names exactly once, which the profile's `uniqueBy` and the local completeness rule establish together), `dataDigests` (the digest of every object fetched and matched), and the optional `exception {authority, reason}` whose `authority` must be a `human:` actor.

Write the three first definitions. Each body explains the algorithm in prose and carries exactly one computation. The text of each `# Computation` must be written from the real implementation in `kenshou-core` and `kenshou-measure` at the time, not from this plan; the example shows the shape. The author writes their own actor in `generated.by`: an agent writes `<harness>/<model>`, never `human:`. This example validated as shown.

```markdown
---
type: Attested Computation
title: Run outcome from verdicts, diagnoses and health gates
description: How the harness folds a run's verdict, diagnosis and health-gate documents into the single outcome written to run-result.json.
status: stable
runtime: kenshou
parameters:
  - name: runDirectory
    type: path
    required: true
executor:
  resource: /references/executors/kenshou-run.sh
  receipt: [run-spec.json, run-result.json, manifest.json]
attester:
  resource: /references/attesters/kenshou-attest.sh
generated:
  by: claude-code/claude-fable-5-1
  at: 2026-09-20T17:30:00Z
algorithm: run-outcome
algorithmVersion: 1
appliesTo: [correctness, concurrency, soak, benchmark]
computationId: VC-1
implementation: Kenshou.Core.Outcome
inputs: [run-result, verdicts, diagnosis]
produces: outcome
---

# Run outcome

The outcome of a run is the worst of its inputs. The harness reads every verdict
document under `verdicts/`, every diagnosis document under `diagnosis/`, and the
health-gate section of `run-result.json`, and applies the rules below from top to
bottom; the first rule that matches decides.

# Computation

    infrastructure-failure  if any health gate tripped
    errored                 else if the scenario body or any checker could not be evaluated
    failed                  else if any contract-invariant verdict is failed
    inconclusive            else if any verdict or diagnosis is inconclusive
    passed                  otherwise

# Notes

A failed implementation-invariant verdict is reported but does not decide the
outcome.
```

`VC-2` is `computations/latency-summary.md` (`algorithm: latency-summary`, `produces: summary`, `inputs: [samples, run-result]`, `appliesTo: [benchmark, soak]`, implementation the summary module of `kenshou-measure`), and `VC-3` is `computations/paired-comparison.md` (`algorithm: paired-comparison`, `produces: comparison`, `inputs: [run-result, samples, comparison]`, parameters `baselineRuns` and `candidateRuns`). When `docs/plans/5-…` and `docs/plans/6-…` are implemented, their owners add `invariant-verdict`, `leak-verdict` and `stall-diagnosis` the same way: one file, one `okf id next`, one log entry. Paths inside frontmatter are written with a leading slash, because a bare `references/…` resolves against the concept's own directory.

The two reference files are short scripts. `references/executors/kenshou-run.sh` is `exec kenshou run "$1" --out "$2"` under `set -euo pipefail` with a comment saying it reproduces a run from its run specification; `references/attesters/kenshou-attest.sh` is `exec kenshou attest "$1" --bundle docs/verification` with a comment saying it contains no language model and makes no clock-dependent decision. Their job is to be findable: the profile's `path` rules fail validation if either disappears.

`scripts/test-verification-profile.sh` follows the okf-profiles pattern: it validates `docs/verification` and then, for each directory under `kenshou-evidence/test/fixtures/profile-invalid/<case>/` (a root `index.md` declaring the version plus the minimum concepts), asserts that enforced validation exits non-zero and that the expected diagnostic text appears. Each fixture fails for exactly one reason. Write one per probe listed under "What was verified while drafting"; these fixtures are what `docs/plans/19-…` lifts upstream.

Register the bundle by adding this element to the `okfBundles` list of `mori.dhall` (the list already holds the `adrs` bundle from `docs/plans/1-…`), then run `mori validate`:

```dhall
, Schema.OkfBundle::{
  , name = "verification"
  , path = "docs/verification"
  , profile = Some "docs/verification/profile.dhall"
  , okfVersion = "0.2"
  , description = Some
      "Immutable records of verification runs and attestations, with the definitions of how their verdicts are computed"
  }
```

A run record is then addressable as `mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/runs/<layer>/<YYYY>/<MM>/<run-id>` and a definition as `…/concepts/VC-1`.

### Milestone 2 — `kenshou record` and the digest and revision check

This milestone creates the package `kenshou-evidence` and two commands. At its end `kenshou record <run-dir> --data-base-uri gs://… --purpose …` uploads what is missing, writes a record that passes the Milestone 1 gate, appends the log entry and regenerates indexes; `kenshou evidence check` enforces what the profile cannot. Acceptance is the test suite plus a scratch demonstration with the store-root seam described below.

Create `kenshou-evidence/kenshou-evidence.cabal` (library plus the test suite `kenshou-evidence-test`, `default-language: GHC2024`) depending on `kenshou-core`, `kenshou-measure`, `okf-core ^>=0.9.0.0`, `aeson`, `bytestring`, `containers`, `directory`, `filepath`, `text`, `time`, `typed-process`, `optparse-applicative`, and whatever SHA-256 and UUIDv7 functions `kenshou-core` already exports (reuse them; add `cryptohash-sha256` only if the kernel keeps its hashing private). `okf-core` pulls in the `dhall` library, which is large; if `docs/plans/17-…` later finds the cell payload too big, put the evidence commands behind a cabal flag in `kenshou-cli`, since they never run on a cell. One hazard comes with `okf-core`: its Markdown parser (`cmark-gfm`) aborts the process if two threads parse at once, so evidence code walks and parses bundles from a single thread.

The modules and their central signatures:

```haskell
module Kenshou.Evidence.Types where

newtype Sha256 = Sha256 Text        -- 64 lowercase hex
newtype Revision = Revision Text    -- 40 lowercase hex
mkSha256 :: Text -> Either Text Sha256
mkRevision :: Text -> Either Text Revision

data RecordKind = RunRecord | ComparisonRecord
data Purpose = Nightly | Release | Baseline | Investigation
data DataKind
  = RunSpecData | RunResultData | ManifestData | CellManifestData | SamplesData
  | SeriesData | VerdictsData | DiagnosisData | LogsData | ComparisonData

data DataLink = DataLink
  { kind :: DataKind, uri :: Text, digest :: Sha256, mediaType :: Text, bytes :: Natural }

data ComponentRef = ComponentRef
  { project :: Text, package :: Text, version :: Text
  , source :: ComponentSource, revision :: Maybe Revision }

data EvidenceRecord = EvidenceRecord { {- every frozen field of Verification Run -} }
data Attestation = Attestation { {- every frozen field of Attestation -} }
```

```haskell
module Kenshou.Evidence.Frontmatter where

recordToDocument :: EvidenceRecord -> Okf.Document.OKFDocument
recordFromDocument :: Okf.Document.OKFDocument -> Either [FieldError] EvidenceRecord
attestationToDocument :: Attestation -> Okf.Document.OKFDocument
attestationFromDocument :: Okf.Document.OKFDocument -> Either [FieldError] Attestation
```

`recordToDocument` builds frontmatter with `Okf.Document.okfCommon`, `setGenerated` and `setField`, and the body from a fixed template of two or three sentences that links the first computation with `Okf.ConceptId.renderConceptLink` (a body link is what creates an OKF graph edge). `Okf.Document.serializeDocument` then emits core keys in OKF's fixed order and house keys alphabetically at every nesting level, so re-serialising an unchanged record is byte-identical. The property tests are the heart of this module: for generated records, `recordFromDocument (parse (serialize (recordToDocument r))) == Right r`, with generators that deliberately produce digests made only of digits with one `e`, dimension values `off`, `on`, `no`, `yes`, `null`, `~`, `true` and `18`, and titles containing `: ` and `#`. If any of these fails, the `yaml` encoder is not quoting what it must; fix it in this module by forcing a quoted style, not by changing the vocabulary.

`Kenshou.Evidence.Source` is the only module that knows the kernel's documents. It exposes `loadRunSource :: FilePath -> IO (Either SourceError RunSource)` and `loadComparisonSource :: FilePath -> IO (Either SourceError ComparisonSource)`, decodes with the kernel's own types rather than raw JSON paths, verifies `manifest.json` against the files on disk before anything else, and returns plain records holding exactly what the recorder needs. A change in a kernel format therefore touches one file here.

```haskell
module Kenshou.Evidence.Store where

data ObjectStat = ObjectStat { bytes :: Natural, recordedSha256 :: Maybe Sha256 }
data ObjectStore = ObjectStore
  { statObject :: Text -> IO (Either StoreError (Maybe ObjectStat))
  , fetchObject :: Text -> FilePath -> IO (Either StoreError ())
  , putObjectIfAbsent :: FilePath -> Text -> Text -> IO (Either StoreError PutResult)
  }

durableSchemes :: [Text]                       -- ["gs"]
gcloudStore :: Text -> ObjectStore             -- GCP project; every call passes --project
memoryStore :: IO ObjectStore                  -- tests
directoryStore :: FilePath -> ObjectStore      -- maps gs://bucket/key to <dir>/bucket/key
```

`gcloudStore` shells out to `gcloud storage` (`objects describe --format=json`, `cp` with `--if-generation-match=0` and a custom metadata entry `kenshou-sha256`, `cat`), always with an explicit `--project`, and refuses to start unless the active project equals the one given, mirroring the isolation preflight in `mori://shinzui/load-testing-infra` for project `tan-nb-exp`. GCS stores CRC32C and MD5 but not SHA-256, so presence checks compare size and the metadata entry, and a real digest check means downloading. If `docs/plans/17-…` has already delivered a GCS client in `kenshou-remote`, wrap it instead of duplicating it. `directoryStore` exists for tests and scratch demonstrations: the hidden flag `--store-root DIR` selects it, records still carry `gs://` URIs, and the command refuses the flag unless `--bundle` points outside this repository, so an emulated record can never be committed.

```haskell
module Kenshou.Evidence.Record where

data RecordOptions = RecordOptions
  { bundleRoot :: FilePath, dataBaseUri :: Text, purpose :: Purpose
  , uploadMode :: UploadMode          -- UploadMissing | VerifyOnly
  , deepVerify :: Bool, allowDirty :: Bool, linkLogs :: Maybe Bool
  , subjectOverride :: Maybe (Text, SubjectKind), produced :: [Text] }

data RecordOutcome = Recorded ConceptId | AlreadyRecorded ConceptId

recordRun :: ObjectStore -> RecordOptions -> FilePath -> IO (Either RecordError RecordOutcome)
recordComparison :: ObjectStore -> RecordOptions -> FilePath -> IO (Either RecordError RecordOutcome)
```

`recordRun` proceeds in a fixed order so that a failure leaves nothing half-written. It loads and self-verifies the run directory; refuses a base URI whose scheme is not in `durableSchemes`; refuses a dirty harness unless `--allow-dirty`, and then forces `purpose` to `investigation`; computes the object URI of every file as `<data-base-uri>/<run-id>/<relative path>`; for each file either confirms the remote object (size and recorded digest, or a download under `--deep-verify`) or uploads it with a no-clobber precondition, and treats an existing object with different content as a conflict.

It then builds the record; looks for an existing concept at the target path and returns `AlreadyRecorded` when its content is equal apart from `generated` and `verified`, or fails with a conflict when it differs (first valid fact wins, as in Mori's ADR-53); writes the file to a temporary name and renames it; appends `* **Addition**: Recorded run <id> (<scenario>, <outcome>).` to the month's `log.md` through `Okf.Log.parseLog`, `appendLogEntry` and `serializeLog`, dated by `generated.at` in UTC and titled the way `okf log add` titles a new log (`# runs/<layer>/<YYYY>/<MM> Update Log`); regenerates indexes with `Okf.Index.writeBundleIndexes`; and finally validates the bundle in process (`Okf.Profile.loadProfileFile`, `compileProfile`, `Okf.Bundle.walkBundle`, `walkBundleInventory`, `validateProfileWith`, `Okf.Validation.validateBundle`), removing the new file and restoring the log if validation reports anything. `recordComparison` does the same for a `kenshou.comparison/v1` document: every run it names must already be recorded (it resolves run identifiers to concepts and refuses otherwise), the document is stored at `<data-base-uri>/<record-id>/comparison.json`, and idempotence is keyed by the document's digest, because a minted identifier cannot be.

Only deliberately recorded runs enter the bundle: nightly, release, baseline and investigation runs, never every local run. At roughly one millisecond per concept for okf, and with Mori storing each concept's full frontmatter, a few thousand records per year is the comfortable envelope.

```haskell
module Kenshou.Evidence.Check where

data CheckOptions = CheckOptions
  { bundleRoot :: FilePath, baseRef :: Maybe Text, network :: Bool, deep :: Bool }
data Finding = Finding { concept :: Text, rule :: Text, message :: Text }

checkBundle :: ObjectStore -> CheckOptions -> IO (Either CheckError [Finding])
```

The rules, by name: `id-shape`, `path-consistency`, `hex-shape` (every digest, `compatibilityKey` and `solverPlanHash` is a JSON string of lowercase hex of the expected length; every revision is 40), `string-typing` (dimension values and every textual field are JSON strings), `time-order`, `event-keys` (no `status` or `stale_after` on a run or an attestation; `layer` and `tier` only on runs), `data-completeness`, `cell-fields`, `reference-targets`, `dirty-purpose`, `attestation-consistency` (Milestone 3), `immutability`, and `network` (opt-in). `immutability` asks git: for every file under `runs/` and `attestations/` other than `index.md` and `log.md`, in every commit that modified or deleted it (`git log --diff-filter=MD --name-status -- docs/verification/runs docs/verification/attestations`, or only `<base>..HEAD` with `--base`), plus the working tree, a deletion or rename is a finding, and a modification is a finding unless the body is unchanged, the frontmatter is equal once `verified` is removed from both sides, and the old `verified` list is a prefix of the new one. A shallow clone makes the rule unanswerable, so it is reported as an error with exit code 4 rather than passed. One escape hatch exists because a gate with no sanctioned override gets switched off the first time it is wrong: `docs/verification/.immutability-exceptions`, lines of `<commit> <path> <reason>`, each of which needs an ADR amendment to justify.

`Kenshou.Evidence.Cli` exports the option parsers; add them to `kenshou-cli` the same way `kenshou compare` from `docs/plans/4-…` was added. Register `record` and the nested `evidence check` command in the Evidence group and give both parsers visible option sections using the kernel's `parserOptionGroup` helper: `Record source`, `Evidence destination`, `Verification`, and `Output` for `record`; `Bundle selection`, `History scope`, `Verification`, and `Output` for `evidence check`. Register their leaf parsers in the completion registry, not a hand-maintained shell table. In human mode concise results go to stdout and diagnostics to stderr; whenever a JSON mode is present, stdout contains exactly one schema-valid JSON document and all progress, warnings, storage commands, and failures go to stderr. `kenshou record` exits 0 when recorded or already recorded, 1 on a conflict or digest mismatch, 2 on a usage error or refusal, 4 when storage or tools are unreachable. `kenshou evidence check` exits 0 when clean, 1 on findings, 2 on usage, 4 when it cannot run. `kenshou evidence check` is not listed among the verbs of Integration Point 6; it is this plan's addition, mandated by Integration Point 10.

Define `Kenshou.Evidence.Config.evidenceConfig` on EP-2's dependency-neutral `Kenshou.Core.Cli.Config` seam, with the Settei settings `evidence.bundle-root`, `gcp.project`, and optional `evidence.data-base-uri`, bound explicitly to `KENSHOU_EVIDENCE_BUNDLE`, `KENSHOU_GCP_PROJECT`, and `KENSHOU_EVIDENCE_DATA_BASE_URI`. Reuse EP-2's ordered strict-YAML files, diagnostics, redaction and named-flag precedence; `--bundle`, `--project`, and `--data-base-uri` are the highest-precedence sources. The record stores the effective durable URI, and command logs identify the project without credentials. Do not make `purpose`, `allow-dirty`, record subject/produced fields, attestation target, `accept-anomaly`, `authority`, `reason`, or any run/comparison document path configurable: they remain explicit command or versioned-document inputs. `history` and `evidence check` may consume the configured bundle root; they remain deterministic for equal bundle contents.

### Milestone 3 — `kenshou attest` and the verified trail

At the end of this milestone `kenshou attest <run-concept-path-or-run-id>` writes an attestation and exits 0 for `confirmed`, 1 for `refuted`, 3 for `incomplete`, 2 for usage and 4 when it could not run at all. Register it in the Evidence group and completion registry, with visible `Evidence source`, `Recomputation`, `Anomaly acceptance`, and `Output` option groups. Its JSON mode obeys the same single-document stdout rule; prompts and confirmation/refusal details use the terminal or stderr, never stdout. The tamper test is the acceptance.

```haskell
module Kenshou.Evidence.Attest where

data Recomputation = Recomputation
  { agreesWithDocuments :: Bool                    -- recomputed value equals what the fetched documents state
  , outcome :: Maybe Outcome                       -- set by algorithms that produce an outcome
  , comparisonVerdict :: Maybe ComparisonVerdict   -- set by algorithms that produce a comparison
  , detail :: Text }
data Recomputer = Recomputer
  { algorithm :: Text, algorithmVersion :: Natural
  , recompute :: FilePath -> IO (Either Text Recomputation) }   -- argument: fetched data root

coreRecomputers :: [Recomputer]     -- run-outcome v1, latency-summary v1, paired-comparison v1
attest :: ObjectStore -> [Recomputer] -> AttestOptions -> Text -> IO (Either AttestError Attestation)
```

The registry is a list passed in by `kenshou-cli` so that `kenshou-evidence` needs only its hard dependencies; when `kenshou-check` and `kenshou-diagnose` exist, `kenshou-cli` appends their recomputers. The attester is deterministic: no language model, no decision that depends on the clock, the same inputs give the same checks. It fetches every object named in `data` into a temporary directory and then every file named by the fetched `manifest.json` (or only the linked objects with `--linked-only`, which the check's `detail` then says), and evaluates six checks.

- `digests-match` — every fetched object has the recorded size and SHA-256, and every entry of the fetched manifest matches the object it names.
- `revisions-resolve` — `harnessRevision` exists in this repository (`git cat-file -e <sha>^{commit}`), and each git-sourced component's `revision` exists in its repository, looked up first in the local clone that `mori path <project-uri>` names and otherwise with `git fetch --depth=1 <url> <sha>` into a scratch bare repository, the URL taken from the cohort identity. Under `--offline`, or when neither route is available, the result is `skipped`.
- `cohort-matches-plan` — the record's `cohort`, `solverPlanHash` and `components` equal the cohort identity inside the fetched `run-result.json`, and that identity satisfies the cohort expectation in `run-spec.json`.
- `verdict-recomputed` — for each handle in `computations`, read the definition's `algorithm` and `algorithmVersion`, find the recomputer, and run it over the fetched data. It passes when every recomputation agrees with what the fetched documents state (a recomputed summary equals the summary inside `run-result.json`, which is how a figure is attested without ever entering a record) and every recomputed outcome or comparison verdict equals the record's `outcome` or `comparison.verdict`. It fails on any disagreement. A definition with no registered recomputer yields `skipped`.
- `environment-captured` — the record's `environment` equals the fingerprint in the run result, every required key is non-empty, and a cell run carries the cell's fingerprint and health observations.
- `clean-worktree` — the record and the run result agree that the harness was built from an unmodified tree, and so was the attester.

The verdict separates a contradicted claim from an unestablished one. It is `refuted` when `digests-match`, `cohort-matches-plan` or `verdict-recomputed` failed, because then the data contradicts the record. Otherwise it is `incomplete` when any check failed or was skipped, because then the claim stands but was not fully established (an investigation run from a dirty harness can never be better than this). Otherwise it is `confirmed`.

The attestation is written, logged, indexed and validated exactly as a run record is, under `attestations/<YYYY>/<MM>/`. Each attestation is a new event with a new UUIDv7; attesting again later, for example after registering a new recomputer, adds a record and changes none. This example validated as shown:

```markdown
---
type: Attestation
title: Attestation of run 01a0c001 — confirmed
description: The kenshou attester fetched every linked object of run 01a0c001-fd58-7a4a-bb26-00e256f29344, matched the digests, recomputed the outcome under VC-1, and confirmed it.
generated:
  by: process:kenshou-attester/0.1.0.0
  at: 2026-09-20T18:30:31Z
attestationId: 01a0c00e-ce98-713a-89a2-96973e35545c
attestedAt: 2026-09-20T18:30:31Z
attester: process:kenshou-attester/0.1.0.0
attesterRevision: 22d64225bfd5e78eedc3a90a5a244007a400a851
checks:
  - name: digests-match
    result: passed
  - name: revisions-resolve
    result: passed
  - name: cohort-matches-plan
    result: passed
  - detail: run-outcome v1 and latency-summary v1 agree with the documents; outcome passed
    name: verdict-recomputed
    result: passed
  - name: environment-captured
    result: passed
  - name: clean-worktree
    result: passed
dataDigests:
  - 05b3abf2579a5eb66403cd78be557fd860633a1fe2103c7642030defe32c657f
  - 8ce77c849d5d81c35663e4b97d6178958cdff6392086b142d68192fa46a3c547
  - 2b03ddb79f54934771b40fb32fd5b54357feb41f98a00fbc1ba01413e2c939fd
  - 24baa7a731ce04b431af93d94cba8e0160a0e6a4607edc2d70c595dd098e56cf
run: /runs/kiroku/2026/09/01a0c001-fd58-7a4a-bb26-00e256f29344.md
verdict: confirmed
---

The attester confirmed [run 01a0c001](/runs/kiroku/2026/09/01a0c001-fd58-7a4a-bb26-00e256f29344.md).
```

When, and only when, the verdict is `confirmed`, the attester parses the run record, appends `{by: process:kenshou-attester/<version>, at: <attestedAt>}` to `verified` unless an entry with the same `by` is already there, and re-serialises it; because the serialiser is deterministic the diff is exactly the added lines. `generated` does not change, since a confirmation is not a change of content, so no log entry is needed on the run's side. This is the one sanctioned mutation, and the `immutability` rule from Milestone 2 already allows exactly it; add the `attestation-consistency` rule now: every `process:` entry in a run's `verified` list is backed by a `confirmed` attestation of that run with the same `attester` and `attestedAt`, every attestation's verdict equals the derivation from its checks stated above, all six check names are present, and `dataDigests` covers the run's `data` digests whenever `digests-match` passed.

A human sign-off is a `human:<id>` entry that a person adds to `verified` by hand and commits under their own name; `kenshou attest` has no flag that writes one, and it rejects any actor beginning with `human:` for `attester`. The separate case of a person accepting an anomaly (for example an `incomplete` attestation of a run whose component revision lives in a repository that can no longer be fetched) is `kenshou attest <run> --accept-anomaly --authority human:<id> --reason "<text>"`, which writes a new attestation whose verdict is still the computed one and which carries `exception {authority, reason}`. The command refuses these flags when standard input is not a terminal or when `CI` is set, so that an automated job can never claim a person's authority.

### Milestone 4 — `kenshou history`, validation gates and the seeded corpus

At the end of this milestone the bundle holds real records, `just verify` enforces the local evidence gates, and `kenshou history` emits the reporting input.

```haskell
module Kenshou.Evidence.History where

data HistoryQuery = HistoryQuery
  { scenario :: Text, cohortComponent :: Maybe (Text, Maybe Text)
  , outcomes :: [Outcome], since :: Maybe Day, confirmedOnly :: Bool }

history :: FilePath -> HistoryQuery -> IO (Either HistoryError HistoryDocument)
deriveBaseline :: [HistoryEntry] -> HistoryEntry -> Maybe ConceptId
```

`history` walks the bundle with `Okf.Bundle.walkBundle` (which, unlike `okf concepts --json`, keeps each concept's path), decodes records and attestations, and emits a `kenshou.evidence-history/v1` document with no timestamp of its own so that equal bundles give equal output. Register it in the Analysis group and completion registry, with visible `Bundle selection`, `Scenario filters`, `Trust filters`, and `Output` option groups. `--cohort-component kiroku-store` keeps runs whose `components` include that package, and `--cohort-component kiroku-store=0.8.0.1` (or `=<revision>`) narrows to a version or commit. Add its JSON Schema to `schemas/` using the file naming the kernel established there. In `--json` mode stdout is exactly the history document and remains byte-stable for equal bundles; diagnostics use stderr.

Add `kenshou-cli/help/evidence.md` as an embedded `HelpTopic` and register it with the kernel. It explains the lifecycle from `record` through `attest` and `evidence check` to `history`, the immutability boundary, exit-code meanings, and where machine-readable output is written. It is reachable as `kenshou help evidence`, is wrapped by the kernel's explicit/terminal-width policy, and needs no duplicated prose in the optparse descriptions.

```json
{
  "schema": "kenshou.evidence-history/v1",
  "bundle": "mori://shinzui/keiro-runtime-kenshou/okf/verification",
  "query": { "scenario": "kiroku/append/benchmark/single-stream-throughput" },
  "entries": [
    {
      "concept": "runs/kiroku/2026/09/01a0c001-fd58-7a4a-bb26-00e256f29344",
      "ref": "mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/runs/kiroku/2026/09/01a0c001-fd58-7a4a-bb26-00e256f29344",
      "record": { "runId": "01a0c001-fd58-7a4a-bb26-00e256f29344", "outcome": "passed", "data": [] },
      "trust": "machine-confirmed",
      "attestations": [
        { "concept": "attestations/2026/09/01a0c00e-ce98-713a-89a2-96973e35545c", "verdict": "confirmed" }
      ],
      "derivedBaseline": "runs/kiroku/2026/09/01a0bffb-94b8-7792-94a0-2f9cfbb82871"
    }
  ]
}
```

`record` is the complete frontmatter (abridged above), entries are ordered by `startedAt`, and comparison records appear in the same series with their `comparison` object. `deriveBaseline` answers, for a run, the latest earlier run with the same `scenario` and `compatibilityKey` whose outcome is `passed` and which has at least one `confirmed` attestation and no later `refuted` one. It is computed on every read and stored nowhere.

The corpus needs a durable bucket. If `docs/plans/16-…` has delivered the cell's results bucket, use it and pass the prefix that holds the run directory as `--data-base-uri`. Otherwise create a plain bucket by hand, but first stop and obtain the platform owner's confirmation, because this creates a billable cloud resource: a bucket in project `tan-nb-exp`, region `us-west1`, with uniform bucket-level access, public access prevention, object versioning and an unlocked retention period (the commands are in Concrete Steps). Never lock the retention policy without a separate decision by the owner; a locked policy cannot be shortened or removed.

Seed at least one recorded and attested run per evidence kind (`correctness`, `concurrency`, `soak`, `benchmark`) and one comparison of two benchmark runs. Prefer real layers (kiroku first) when their coverage plans have landed; otherwise use the `selftest` layer, and if no scenario of some kind exists yet, record that gap in Progress rather than inventing one. Use `--purpose baseline` for the first runs and `--purpose release` for the comparison. This example of a run record validated as shown; a comparison record differs only in `recordKind: comparison`, the absence of the run-only fields, `computations: [VC-3]`, a single `data` entry of kind `comparison`, and the `comparison` object.

```markdown
---
type: Verification Run
title: kiroku/append/benchmark/single-stream-throughput passed on head
description: Benchmark run of kiroku single-stream append throughput against the head cohort on cell alpha, recorded for a release comparison.
generated:
  by: kenshou-record/0.1.0.0
  at: 2026-09-20T18:40:00Z
cohort: head
compatibilityKey: 2b33a9570d42f8af1c84dbe8b8c9bb50664f9b19ca8f7ee100548b9945a52f5d
component: append
components:
  - package: kiroku-store
    project: mori://shinzui/kiroku
    revision: 95e122e3988b8e64d55ff67b960dd22493fd44fe
    source: git
    version: 0.8.0.1
  - package: pg-migrate
    project: mori://shinzui/pg-migrate
    source: hackage
    version: 1.1.0.0
computations: [VC-1, VC-2]
data:
  - bytes: 4312
    digest: 05b3abf2579a5eb66403cd78be557fd860633a1fe2103c7642030defe32c657f
    kind: manifest
    mediaType: application/json
    uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0c001-fd58-7a4a-bb26-00e256f29344/manifest.json
  - bytes: 1877
    digest: 8ce77c849d5d81c35663e4b97d6178958cdff6392086b142d68192fa46a3c547
    kind: run-spec
    mediaType: application/json
    uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0c001-fd58-7a4a-bb26-00e256f29344/run-spec.json
  - bytes: 9120
    digest: 2b03ddb79f54934771b40fb32fd5b54357feb41f98a00fbc1ba01413e2c939fd
    kind: run-result
    mediaType: application/json
    uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0c001-fd58-7a4a-bb26-00e256f29344/run-result.json
  - bytes: 262144
    digest: 24baa7a731ce04b431af93d94cba8e0160a0e6a4607edc2d70c595dd098e56cf
    kind: samples
    mediaType: application/octet-stream
    uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0c001-fd58-7a4a-bb26-00e256f29344/samples/append.hist
  - bytes: 6044
    digest: 6e1b3c2f0f1b3f6a1d2c8a3b5e7f90a1b2c3d4e5f60718293a4b5c6d7e8f9a0b
    kind: cell-manifest
    mediaType: application/json
    uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0c001-fd58-7a4a-bb26-00e256f29344/cell/manifest.json
dimensions:
  - name: pg.durability
    value: durable
  - name: pg.version
    value: "18"
  - name: telemetry.metrics
    value: "off"
  - name: telemetry.tracing
    value: "off"
environment:
  arch: x86_64
  cell: alpha
  cellRun: lease-20260920-180105
  cores: 16
  cpuModel: AMD EPYC 7B13
  ghc: 9.12.4
  machineType: n2d-standard-16
  memoryBytes: 68719476736
  os: linux
  postgres: "18.0"
  zone: us-west1-a
finishedAt: 2026-09-20T18:12:41Z
harnessDirty: false
harnessRevision: 0a4ca4ce7e4990cd01a24d592212e71d0a5c3237
kind: benchmark
knobs:
  - name: kiroku.pool-size
    value: 8
  - name: load.rate-per-second
    value: 2000
layer: kiroku
outcome: passed
placement: cell
purpose: release
recordKind: run
runId: 01a0c001-fd58-7a4a-bb26-00e256f29344
scenario: kiroku/append/benchmark/single-stream-throughput
seed: 8675309
solverPlanHash: b8789db0c2da6b48ff31471423dc7ffa2386902c666fa2691e636c29b539936a
startedAt: 2026-09-20T18:02:11Z
subject: mori://shinzui/kiroku/packages/kiroku-store
subjectKind: package
tier: standard
---

Single-stream append throughput ran on cell alpha against the head cohort and the
harness reported passed, under [the run-outcome definition](/computations/run-outcome.md).
Every measurement lives in the linked data; this record holds none.
```

The keys that distinguish a comparison record, from the comparison that validated in the same throwaway bundle:

```yaml
recordKind: comparison
outcome: passed
computations: [VC-3]
comparison:
  baselineRuns:
    - /runs/kiroku/2026/09/01a0bffb-94b8-7792-94a0-2f9cfbb82871.md
  baselineValue: released
  candidateRuns:
    - /runs/kiroku/2026/09/01a0c001-fd58-7a4a-bb26-00e256f29344.md
  candidateValue: head
  design: sequential
  factor: cohort
  verdict: pass
```

Finally the gates. Since Milestone 1 the `Justfile` has had `evidence-validate` (the strict, enforced `okf validate`), `evidence-index-check` (`okf index docs/verification --write` followed by `git diff --exit-code docs/verification`, which is a complete drift check because index generation is deterministic and clock-free) and `evidence-profile-test` (the rejection-fixture script); it now gains `evidence-check` (`cabal run kenshou -- evidence check`), and all four are dependencies of `verify`. The opt-in network rule is checked separately with storage credentials. Write `docs/guides/recording-evidence.md`: when to record, the three commands, how to read a record, how a person signs off, what to do when a gate is red. Re-run the scale probe (copy one record to 2,000 synthetic files in a temporary directory, time `okf validate` and `okf index --write`) and note the figures; if validation exceeds ten seconds, record it as a reason to split the bundle by year.

Upstream requests to write down, not to implement here: a decimal `FieldFormat`, a hex or pattern `FieldFormat` for digests and revisions, a way for a type rule to forbid a core key such as `status`, and a concept-typed path reference. List them in Outcomes & Retrospective and in the ADR's consequences, and file them as improvement requests against `mori://shinzui/okf` (that repository keeps a `docs/improvement-requests/` bundle) only with the owner's agreement. End with the ADR distillation pass and a short hand-off note at the bottom of this plan for `docs/plans/19-…` listing the fixture cases and any rule the real corpus forced you to change.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`). Commit after each Progress item with a Conventional Commits message and these three trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Check prerequisites.

```bash
okf --version && dhall --version
ls cabal.project Justfile docs/adr/profile.dhall schemas
cabal run kenshou -- list --json | head -c 300
cabal run kenshou -- compare --help | head -5
```

```text
okf v0.9.0.0 (c466eeb)
1.42.3
```

Build the Milestone 1 bundle.

```bash
mkdir -p docs/verification/computations docs/verification/references/executors docs/verification/references/attesters
# write profile.dhall, log.md, the two scripts and the three definitions as described
dhall freeze docs/verification/profile.dhall && dhall format docs/verification/profile.dhall
okf id next docs/verification VC --profile docs/verification/profile.dhall
okf index docs/verification --write --okf-version 0.2
okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce
okf show docs/verification VC-1 --computation
bash scripts/test-verification-profile.sh
mori validate
```

```text
VC-1
Wrote index.md files
OK: 3 concepts (okf_version 0.2)
infrastructure-failure  if any health gate tripped
…
ok: docs/verification
rejected as expected: undeclared-measurement-key (frontmatter field not declared by profile: p99Millis)
rejected as expected: non-durable-data-uri (must match format uri-with-scheme(gs))
…
```

The root `log.md` needs an entry dated on or after the newest `generated.at`, or `--log-enforce` fails with a line like `log: computations/run-outcome: generated date 2026-09-22 is newer than log.md newest entry 2026-09-20`. Add it with `okf log add docs/verification --kind Addition -m "Added the profile and the first three computation definitions."`.

Build and test Milestone 2 and 3, then demonstrate against a scratch bundle without touching the cloud.

```bash
cabal build kenshou-evidence && cabal test kenshou-evidence:kenshou-evidence-test
SCRATCH=$(mktemp -d) && cp -R docs/verification "$SCRATCH/bundle"
cabal run kenshou -- run selftest/harness/correctness/always-passes --out "$SCRATCH/out"
RUN=$(ls "$SCRATCH/out")
cabal run kenshou -- record "$SCRATCH/out/$RUN" --bundle "$SCRATCH/bundle" \
  --store-root "$SCRATCH/store" --data-base-uri gs://scratch-bucket/runs --purpose investigation
okf validate "$SCRATCH/bundle" --strict --profile "$SCRATCH/bundle/profile.dhall" --profile-enforce --log-enforce
cabal run kenshou -- attest "$RUN" --bundle "$SCRATCH/bundle" --store-root "$SCRATCH/store" --offline; echo "exit=$?"
```

The scenario name is illustrative; use any `selftest` scenario `kenshou list` prints. Expected, with identifiers that will differ:

```text
recorded runs/selftest/2026/10/0199…-….md (7 objects uploaded, 0 already present)
OK: 4 concepts (okf_version 0.2)
attestation attestations/2026/10/0199…-….md: incomplete (revisions-resolve skipped: offline)
exit=3
```

Tamper test: overwrite one byte of `"$SCRATCH/store/scratch-bucket/runs/$RUN/run-result.json"`, run `attest` again, and expect `refuted (digests-match failed: run-result.json …)` and `exit=1`.

Create the bucket only after the owner confirms. Read `gcloud storage buckets create --help` and `gcloud storage buckets update --help` first, because these flags were not exercised while drafting.

```bash
PROJECT=tan-nb-exp
BUCKET=gs://kenshou-evidence-tan-nb-exp
gcloud storage buckets create "$BUCKET" --project="$PROJECT" --location=us-west1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "$BUCKET" --project="$PROJECT" --versioning --retention-period=5y
gcloud storage buckets describe "$BUCKET" --project="$PROJECT" --format="value(retention_policy,versioning_enabled)"
```

Seed and gate.

```bash
cabal run kenshou -- record out/<run-id> --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs --purpose baseline
cabal run kenshou -- attest <run-id>
cabal run kenshou -- record --comparison out/<comparison>.json --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs --purpose release
cabal run kenshou -- history --scenario <scenario-id> --json | head -40
just verify
```


## Validation and Acceptance

Milestone 1 is accepted when strict, enforced validation of `docs/verification` prints `OK: 3 concepts (okf_version 0.2)`; `okf computations docs/verification` lists three definitions each ending in `executor + attester`; `okf id list docs/verification --profile docs/verification/profile.dhall` prints `VC-1` to `VC-3`; deleting `references/attesters/kenshou-attest.sh` makes validation fail with `attester.resource references /references/attesters/kenshou-attest.sh, which does not exist in this bundle`; every rejection fixture is rejected for its one stated reason; and `mori validate` passes.

Milestone 2 is accepted when the test suite passes, including the serialisation round-trip properties over hazardous strings; `kenshou --help` lists `record` and `evidence` under Evidence; the Bash, Zsh, and Fish completion tests expose `record`, `evidence check`, and their parser options; the help snapshot shows the named option groups; Settei tests prove built-in < ordered YAML < explicit environment < named-flag precedence for bundle/project/data URI, that the effective URI is the one stored in a new record, and that purpose and anomaly-authority keys are rejected as unknown configuration; recording the same run twice prints `already recorded` the second time and leaves `git status` clean; recording with `--data-base-uri file:///tmp/x` exits 2 with a message naming the allowed schemes on stderr; recording a run from a dirty harness exits 2 without `--allow-dirty` and produces `purpose: investigation` with it; a JSON-mode success parses when stdout is consumed alone while an induced warning appears only on stderr; hand-editing `outcome` in a committed record makes `kenshou evidence check` exit 1 with an `immutability` finding naming the file and the changed key; adding `status: stable` to a run yields an `event-keys` finding even though `okf validate` stays green; and writing `value: off` unquoted in a dimension yields a `string-typing` finding.

Milestone 3 is accepted when `kenshou --help` lists `attest` under Evidence and all three completion protocols expose its parser options; attesting an untouched recorded run with network access yields `confirmed`, exit 0, a new file under `attestations/`, and exactly one added `verified` entry in the run whose diff is only those lines; `okf trust docs/verification` then shows that run as `machine-confirmed`; `kenshou evidence check` stays green after the append; attesting the same run again adds a second attestation and no second `verified` entry; the tamper test yields `refuted` and exit 1 and adds no `verified` entry; and `--accept-anomaly` is refused with exit 2 when `CI=true`.

Milestone 4 is accepted when `kenshou --help` lists `history` under Analysis; `kenshou help evidence --width 80` is an 80-column-or-narrower golden snapshot and the piped default is byte-stable; Bash, Zsh, and Fish completion tests expose `history` and its parser options; the bundle contains at least one attested run for each of the four kinds (or Progress names the missing kind and why) and one comparison record whose arms resolve; `kenshou history --scenario … --json` emits no non-JSON stdout, validates against its schema, and gives the newer of two compatible confirmed runs the older one's `derivedBaseline`; `just verify` runs all four evidence recipes; and `gcloud storage cat` of any `data[].uri` piped to `shasum -a 256` prints the recorded digest.

The plan as a whole is accepted when a person who has never seen the run can open one record, state the Git revision of each Git-sourced runtime package and the released version of each Hackage-sourced package it linked, fetch its raw samples, and find the attestation that confirmed it, using nothing but this repository and read access to the bucket. The solver-plan hash identifies the resolved build cohort. The earlier wording asked for a commit for every package, which is not a meaningful identity for a Hackage release.


## Idempotence and Recovery

Every step of Milestone 1 can be repeated: `dhall freeze` and `dhall format` are stable, `okf index --write` is deterministic, and `okf id next` writes nothing. The exception is `okf log add`, which adds another bullet every time; if you ran it twice, delete the duplicate line by hand.

`kenshou record` is idempotent by construction: uploads use a no-clobber precondition, an identical existing record is a no-op, and a different record at the same path is a refusal rather than an overwrite. If it fails after uploading and before writing, run it again; the objects are found and verified, not re-sent. If it dies between writing the concept and regenerating indexes, run `okf index docs/verification --write` and add the missing log line with `okf log add docs/verification runs/<layer>/<YYYY>/<MM>/<run-id> --kind Addition -m "…"`. A record that has been written but not committed may be deleted freely; a committed record may not. If a committed record turns out to be wrong, do not edit it: attest it (when the data contradicts it the result is `refuted`, which removes it from derived baselines) and record a corrected run. Only if a recorder defect wrote a structurally invalid file that keeps the gate red is an entry in `docs/verification/.immutability-exceptions` warranted, together with an amendment to the ADR.

Two people recording on different branches will conflict in `index.md` files and in a month's `log.md`, never in record files. Resolve an index conflict by taking either side and running `okf index docs/verification --write`; resolve a log conflict by keeping both bullets under one date heading. Prefer recording from one place at a time (the nightly job, or a person on `master` after `git pull --rebase`).

`kenshou attest` leaves one attestation file per invocation. An attestation written by mistake and not yet committed can be deleted together with its log line and, if it was `confirmed`, the `verified` entry it appended. Objects in the bucket cannot be deleted or replaced before the retention period ends; that is the point, so upload only run directories you mean to keep, and use the store-root seam with a scratch bundle for experiments. Removing the bucket requires removing the unlocked retention policy first and is the owner's decision. Temporary directories created by `attest` are removed on exit, including on failure.

Profile changes after the corpus exists must be relaxations: a new optional field, a wider vocabulary. Before committing any profile change, run the full gate over the whole committed corpus; if an old record fails, the change is wrong.


## Interfaces and Dependencies

Tools: `okf` 0.9.0.0 or later (`okf validate`, `index`, `log add`, `id next`, `id list`, `computations`, `trust`, `show`, `concepts`), `dhall` 1.42 or later, `mori` for `mori validate`, `git` with full history, and `gcloud` for durable storage. Libraries: `okf-core ^>=0.9.0.0` from Hackage, using `Okf.Document` (`okfCommon`, `setField`, `setGenerated`, `setVerified`, `serializeDocument`, `parseDocument`), `Okf.Bundle` (`walkBundle`, `walkBundleInventory`, `conceptFromDocument`, `conceptIdOf`), `Okf.ConceptId` (`parseConceptId`, `renderConceptLink`), `Okf.Log` (`parseLog`, `appendLogEntry`, `serializeLog`), `Okf.Index` (`writeBundleIndexes`), `Okf.Profile` (`loadProfileFile`, `compileProfile`, `validateProfileWith`), `Okf.Validation` (`validateBundle`) and `Okf.Actor`; plus `kenshou-core` (including `Kenshou.Core.Cli.Config`), `kenshou-measure` for document types, identifiers, hashing and comparison, and the Settei 0.2.0.0 family for the evidence declaration. The Dhall side depends on okf-profiles v0.18.0 by tag and hash and on nothing else.

At the end of Milestone 1 these files exist: `docs/verification/{index.md,log.md,profile.dhall}`, `docs/verification/computations/{run-outcome,latency-summary,paired-comparison}.md`, `docs/verification/references/executors/kenshou-run.sh`, `docs/verification/references/attesters/kenshou-attest.sh`, `scripts/test-verification-profile.sh`, fixtures under `kenshou-evidence/test/fixtures/profile-invalid/`, the `verification` entry in `mori.dhall`, and one new ADR. At the end of Milestone 2 the package `kenshou-evidence` exposes `Kenshou.Evidence.Types`, `.Frontmatter`, `.Source`, `.Subject`, `.Store`, `.Record`, `.Check`, `.Config` and `.Cli` with the signatures given above, and `kenshou-cli` gains `record` and `evidence check` in the Evidence group. At the end of Milestone 3 it also exposes `Kenshou.Evidence.Attest` (`Recomputation`, `Recomputer`, `coreRecomputers`, `attest`) and `kenshou-cli` gains `attest` in the Evidence group. At the end of Milestone 4 it exposes `Kenshou.Evidence.History` (`history`, `deriveBaseline`), `schemas/` holds the schema of `kenshou.evidence-history/v1`, `kenshou-cli/help/evidence.md` is registered as an embedded help topic, `kenshou-cli` registers `history` in Analysis, `docs/guides/recording-evidence.md` exists, and the `Justfile` has `evidence-validate`, `evidence-index-check`, `evidence-profile-test` and `evidence-check` under `verify`.

Other plans consume the following. `docs/plans/19-publish-the-verification-evidence-profile-in-okf-profiles.md` lifts the value `shared` from the local descriptor as the export `assurance.verificationEvidence`, mirrors the seeded corpus as its acceptance fixture, lifts the rejection fixtures, and afterwards replaces the middle of `docs/verification/profile.dhall` (the generic vocabularies, the type rules and `shared`) with the pinned import of the published profile while keeping the runtime-specific vocabularies, the `enum` helper and the overlay, switching `mori.dhall` to a `Published` binding with `derived = True`; it must respect the frozen names. `docs/plans/17-…` hands `kenshou record` a fetched run directory and the bucket prefix that holds it, and may supply the GCS client. `docs/plans/5-…` and `docs/plans/6-…` add computation definitions and register recomputers through `kenshou-cli`. The future reporting plan reads `kenshou history --json` and dereferences `data[].uri`. `kotei` or any script may branch on the exit codes stated in Milestones 2 and 3.

### Handoff to the profile publication plan

The committed corpus is the acceptance fixture. Mirror its three definitions,
run and comparison records, and attestations while preserving type names, field
names, discriminator values, and existing validation outcomes. The local
rejection fixtures are `unknown-field`, `non-durable-uri`,
`duplicate-data-uri`, `dangling-computation`, `dangling-previous-run`,
`missing-cohort`, `git-component-without-revision`, `textual-seed`,
`textual-dirty-flag`, `unknown-outcome`, `invalid-layer`, `invalid-kind`,
`missing-generated`, `wrong-run-path`, `missing-comparison`,
`dangling-baseline`, `non-actor-attester`, `nonhuman-exception`,
`duplicate-check`, and `unknown-check`, plus the separate
missing-attester-resource control. No profile rule had to be tightened for the
real corpus. The VC-1 definition text was corrected to describe the runner's
actual outcome source; that changed a definition before the corpus was seeded,
not the profile contract. The local checker covers decimal/hex formats,
forbidden event `status`, path identity, and typed concept references until OKF
can express them directly.

Revision note, 2026-09-20: first complete draft. It incorporates three constraints relayed from the drafting of `docs/plans/19-…`: reference targets are non-Markdown files, the handle field `computationId` and the discriminator `recordKind` are stated once under "Frozen field names", and the descriptor separates runtime-specific vocabularies so the shared profile can be lifted with an overlay left behind.

Revision note, 2026-09-20: aligned the evidence command surfaces with the adopted Haskell Jitsurei CLI patterns: stable top-level groups, named option sections, parser-derived Bash/Zsh/Fish completions, embedded width-aware help, and strict machine-output channel separation.

Revision note, 2026-09-20: routed evidence location/project defaults through EP-2's Settei seam while keeping purpose, authority and evidence-bearing inputs explicit.

Revision note, 2026-09-27: limited VC-2 references to records with a stored measurement summary after the Kafka stability soak exposed a diagnosis-only record that could not replay VC-2.
