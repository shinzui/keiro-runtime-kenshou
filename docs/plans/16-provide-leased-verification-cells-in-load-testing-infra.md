---
id: 16
slug: provide-leased-verification-cells-in-load-testing-infra
title: "Provide leased verification cells in load-testing-infra"
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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:53:09Z
      mode: "update"
      note: "Consolidated Progress into delivered outcomes and remaining acceptance"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T05:00:16Z
      mode: "implement"
      note: "Started cell project-isolation plumbing in load-testing-infra"
    - model: "gpt-6"
      harness: "codex-cli"
      at: 2026-09-25T12:33:35Z
      mode: "implement"
      note: "Recorded tested storage, lease, and client foundation without live GCP acceptance"
    - model: "gpt-6"
      harness: "codex-cli"
      at: 2026-09-25T12:45:52Z
      mode: "implement"
      note: "Recorded validated submission and local client path"
---

# Provide leased verification cells in load-testing-infra

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

THE IMPLEMENTATION WORK OF THIS PLAN HAPPENS IN ANOTHER REPOSITORY. This document lives in `keiro-runtime-kenshou`, but every source file it creates or changes belongs to `mori://shinzui/load-testing-infra`, checked out at `/Users/shinzui/Keikaku/bokuno/load-testing-infra`. Only updates to this plan file are committed in this repository.

Today that repository can do one thing: build machine images that contain a benchmark binary, create three Google Cloud virtual machines with one fixed set of names, run one benchmark, copy the results to the operator's laptop over a fragile tunnel, and destroy everything. Any change to the code under test means rebuilding and re-registering a multi-gigabyte image, only one environment can exist at a time, nothing stops two people from using it at once, nothing resets state between runs, and the results exist only on a laptop.

After this plan a maintainer can create any number of named, long-lived "verification cells" (`cell-alpha`, `cell-pg17`, ...), each a controlled set of machines: PostgreSQL, one or more driver machines, a monitoring machine with VictoriaMetrics, Grafana and an OpenTelemetry Collector, and optionally a Redpanda broker. A cell is started and stopped without being destroyed, stops itself when idle, is leased exclusively by one client at a time, is reset to a declared state before every run, and receives its work at run time: a client uploads a content-addressed Nix closure, an opaque work file and a small submission document to Google Cloud Storage, and a generic agent on the driver realises the closure, runs `<entry point> <work-file> <out-dir>` under resource limits, streams logs, and publishes the output directory verbatim, together with the cell's own fingerprint, reset evidence, health observations and an exact-window metrics export, under an immutable prefix `gs://<results-bucket>/runs/<run-id>/` sealed by a manifest of SHA-256 digests. Anyone with read access to the bucket can later fetch a run by its identifier and verify every digest without Pulumi, without a VM, and without the cell still existing.

You can see it working with the fixture payloads this plan ships: two terminals race to lease one cell and exactly one wins; a "contaminate" payload dirties PostgreSQL and the driver, and the next "probe" payload reports a clean machine; a simulated host-maintenance event turns a run into `infrastructure-failure` rather than a slow result; and `cellctl verify` on a fetched run prints one `ok` line per artifact. The cell knows nothing about kenshou. For kenshou (plan `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`) the work file will be a run plan and the entry point `kenshou execute`, but any project can use the same protocol. The existing disposable characterization lane (`scripts/run-benchmark.sh`) keeps working unchanged.


## Progress

- [x] (2026-09-24) Started Milestone 1 in `mori://shinzui/load-testing-infra` at commit `588da3e`: the committed-project allowlist and shared preflight are wired into the disposable-lane scripts. Bash syntax and allowed, wrong-active-project, and disallowed-project probes passed without contacting GCP.
- [x] (2026-09-24) Extracted the existing image build, hash, tarball lookup, upload, and registration functions into a sourceable library at commit `d8e0bf4`. Bash syntax and staged-diff checks passed; an image build awaits the cell image outputs.
- [x] (2026-09-24) Committed the shared and per-cell Pulumi stacks, four NixOS image outputs, cell lifecycle scripts, descriptor and policy schemas, and idle-stop simulation in `mori://shinzui/load-testing-infra` at `f264dce`. The cell Pulumi program compiles after an audited lockfile refresh, Nix evaluates all four image outputs, and both schemas validate. Live GCP acceptance is still pending.
- [x] (2026-09-25) Defined the draft version-one cell storage protocol, payload, submission, status, and environment schemas, and golden examples in `mori://shinzui/load-testing-infra` at `396ff30`. All six current schemas validated against their examples; negative submissions with an invalid bundle digest, escaping command path, or unsupported protocol version were rejected by schema validation. The agent implementation and live GCP acceptance remain pending.
- [x] (2026-09-25) Added the Rust storage and lease foundation, the `cellctl lease` commands, a Nix package, and lease/quarantine schemas in `mori://shinzui/load-testing-infra` at `74871bc`. The Nix build passed with checks enabled; ten Rust tests passed, including concurrent single-owner acquisition, expiry and stale-generation fencing, cancellation fencing, a local CLI acquire/release cycle, and an HTTP 412 create-race mapping. Both new JSON examples validated and the Linux package derivation evaluated. The driver service still uses its placeholder; the agent, payload execution, and live GCP lease race remain pending.
- [x] (2026-09-25) Added typed payload/submission documents and preflight rejection codes in `mori://shinzui/load-testing-infra` at `9650c6b`, then `cellctl submit` with descriptor, active-lease, quarantine, work-digest, and run-ID checks at `013e6f9`. Fourteen Rust tests passed through a checked Nix build, including malformed submissions and a local client cycle that writes work before `submission.json` and refuses reuse. No driver agent has consumed a submission yet; the Cloud Storage path has only the local HTTP precondition test, with live GCP acceptance pending.
- [x] (2026-09-25) Added create-only artifact publication, a last-written manifest, streamed GCS fetch, and local digest verification in `mori://shinzui/load-testing-infra` at `87b52ce`. The checked Nix build passed 16 library tests, including sealed-tree fetch, tamper and extra-object detection, and a mock GCS generation-pinned download; the manifest example validated against its schema. No live results bucket was contacted.
- [x] (2026-09-25) Added generation-fenced driver admission, machine-readable rejection, a local sealed-run loop, and the run-result schema at `8516343`; then added a Nix bundle digest/import executor, supervised entry wrapper, driver CLI, and the quarantined-lease exit-code correction at `34ffd25` in `mori://shinzui/load-testing-infra`. The checked Nix package build passed; 18 library and two CLI tests passed locally, including a fixture entry that exited 3 while preserving separate stdout and stderr. The image deliberately retains its placeholder agent: the Nix import and systemd execution paths, reset, health, environment generation, active-run lease checks, log streaming, and crash recovery have not been verified live or completed.
- [x] (2026-09-25) Added `cellctl watch`, generation-aware lease holding, and quarantine set/clear at `02aaeed`; added the hello fixture output to both flakes at `4717a6b`; and added content-addressed Nix payload publication with a project-preflight wrapper at `285044e` in `mori://shinzui/load-testing-infra`. The checked Nix package build and 19 library plus three client tests passed. The fixture shell produced its requested exit code 3, separate streams, JSON result, and 33,554,432-byte artifact; its local package built and the Linux derivation evaluated. The publisher's local store test covered matching-object reuse and corrupted-object refusal. Actual x86 closure export, GCS upload, and VM import await live acceptance.
- [x] (2026-09-25) Defined `cell.reset-evidence/v1` and `cell.health/v1`, moved health thresholds into the generated policy, and added a pure five-gate evaluator at `1e9413d`; centralized the PostgreSQL reset setting allowlist and safe SQL builders at `36b5bbc`; and required the full descriptor structure before admission at `ced41d6` in `mori://shinzui/load-testing-infra`. The three schema examples validated; negative examples with contradictory pass/verification flags failed validation. Local tests reproduced maintenance and disk-pressure reasons, refused unsupported settings and system-database drops, and rejected a mismatched driver count before status creation. The checked Nix build passed with 23 library and three CLI tests. The role agents do not yet collect observations or execute reset SQL, and the driver does not yet use the evaluator for outcomes.
- [x] (2026-09-25) Exercised the reset SQL sequence against a freshly initialised, isolated PostgreSQL 18.6 server on a temporary Unix socket: created a role and scratch database, ran `ALTER SYSTEM RESET ALL` and `ALTER SYSTEM SET work_mem = '16MB'`, restarted, force-dropped the scratch database, created `benchmark` from `template0`, and ran `CHECKPOINT`. PostgreSQL reported `work_mem=16384` with source `configuration file`; the final non-template database list was exactly `benchmark,postgres`. The first probe stalled because the Python test process captured a background server's inherited output pipe; it was stopped and rerun with server output redirected. This validates the SQL sequence on PostgreSQL 18, not the Rust role agent, PostgreSQL 17, or GCP reset acceptance.
- [x] (2026-09-25) Added the lease-authorized role reset HTTP boundary, typed request and evidence, create-only reset claim, and a request schema/example in `mori://shinzui/load-testing-infra` at `6d58acd`. A real localhost HTTP request returned typed reset evidence from a fake executor; local tests refused a mismatched lease, changed reset specification, wrong run phase, and duplicate claim. The request schema example validated, 25 library and three CLI tests passed, and the checked Nix package build passed after moving packaged tests off root-level example files. This is only the request boundary: no real role executor or service runs on the cell image, and cancellation during a long reset remains unhandled.
- [x] (2026-09-25) Removed the driver's no-op reset at `687eebc` in `mori://shinzui/load-testing-infra`: payload preparation and execution now require internally consistent, verified reset evidence. An unavailable reset seals `infrastructure-failure`, publishes a failed reset document, and does not run the payload. The local test fetched and digest-verified that failure tree and checked the missing payload output; the checked Nix package build passed. The production executor deliberately reports reset unavailable until the real role service and driver-to-role call are implemented.
- [x] (2026-09-25) Implemented a PostgreSQL role reset executor and process command adapter at `4a2458f` in `mori://shinzui/load-testing-infra`. It validates requested settings and database names before altering state, resets server overrides, applies allowlisted settings, restarts for warm or cold cache, recreates databases, checkpoints, and reads back `pg_settings`, `pg_file_settings`, server version, database list, and WAL position. Injected-command tests covered ordered success, restart failure, and rejection before mutation; the checked Nix package build passed. An isolated PostgreSQL 18.6 probe confirmed the exact `pg_file_settings` readback query after restart (`work_mem=16384`, source `configuration file`, `pendingRestart=false`, requested `16MB` applied). This adapter is not yet launched as a role service or called by the production driver; PostgreSQL 17 and VM cache behavior remain unverified.
- [x] (2026-09-25) Connected the driver's typed, timeout-bounded HTTP reset client to a PostgreSQL role CLI and configured both agent services in the driver and PostgreSQL image outputs at `a346a3a` in `mori://shinzui/load-testing-infra`; monitoring retains its placeholder. The private role port was added to host and cell-subnet firewall rules. A parallel role test initially reused a temporary store path and failed setup lease acquisition; a process-local sequence fixed the fixture, and the full 29-library, three-CLI Rust suite passed. The checked Nix package build, TypeScript cell-stack build, and driver/PostgreSQL-17/PostgreSQL-18 image derivation evaluations passed. The VM images were not built or booted, and no live role reset or GCS lease race has passed acceptance.
- [x] (2026-09-25) Generated `cell.environment/v1` from the descriptor and submission, published its bytes in the sealed run, passed a readable file to payloads through `CELL_ENV_FILE`, and rejected multi-driver cells until coordination exists at `7a542d9` in `mori://shinzui/load-testing-infra`. The local run test fetched and digest-verified the environment document and checked the endpoint addresses; the wrapper test checked that the payload could read the file path while preserving exit code 3 and separate streams. A first wrapper test used `cat`, which was unavailable under its intentionally restricted Mac test PATH; shell builtins replaced it and the full 29-library Rust suite and checked Nix package build passed. The generated environment currently has no broker or OTLP endpoint because those roles are not implemented.
- [x] (2026-09-25) Added active-lease identity checks after reset and preparation, polling of the supervised payload process, and a stop attempt on lease loss at `f8b4659` in `mori://shinzui/load-testing-infra`. A local test cancelled the lease during preparation and confirmed a sealed `cancelled` run with `lease-lost` reason and no payload output. The full 31-library, three-CLI Rust suite and checked Nix package build passed. Polling, stopping a real systemd unit, and lease loss through GCS during a run remain live acceptance work; role-side cancellation during a long reset is also pending.
- [x] (2026-09-25) Rechecked the same active lease between PostgreSQL role reset stages at `71126d0` in `mori://shinzui/load-testing-infra` and made the driver classify a lease lost during reset as cancellation. A local test revoked the lease after `ALTER SYSTEM RESET ALL` and confirmed no later setting SQL or restart ran; 32 library tests and the checked Nix package build passed. Individual long PostgreSQL commands cannot yet be interrupted, and VM/GCS acceptance remains pending.
- [x] (2026-09-25) Resumed live acceptance with the reauthenticated `nadeem@topagentnetwork.com` account and explicit `tan-nb-exp` project scope. `gcloud projects describe` returned project number `1087727631858`; `scripts/cell/bootstrap.sh` created the versioned regional state bucket and KMS key, and `scripts/cell/create.sh shared` created eight Pulumi resources: control and results buckets, the agent service account, and its bucket IAM bindings. Readback confirmed the bucket locations, control-bucket versioning, and agent roles. The default gcloud project remained `tan-ng`; every command was scoped to `tan-nb-exp`. No cell VM, image, or live agent run has passed acceptance yet.
- [x] (2026-09-25) Built and uploaded all four NixOS cell images, waited for each GCE image to reach `READY`, and committed their exact self-links in `mori://shinzui/load-testing-infra` at `df84a2a`. The driver, PostgreSQL 17, PostgreSQL 18, and monitoring image names are respectively `cell-image-driver-c4jvny5p5i8r`, `cell-image-postgres17-pjswh700w0zq`, `cell-image-postgres18-mj6wl8rvjg99`, and `cell-image-monitoring-kw3x5q6ip3z2`. The uploader's first execution exited after the last registration, before writing `images.json`; `bash -n` on the current file passed and an idempotent rerun reused all four images and wrote the complete map. The builder's automatic start branch also ran successfully on that rerun.
- [x] (2026-09-25) Created the live `cell-alpha` stack with ten Pulumi resources: a dedicated network, subnet, firewalls, PostgreSQL data disk, and three private VMs using the registered PostgreSQL 18, driver, and monitoring images. Descriptor and policy schemas passed before upload; `scripts/cell/status.sh alpha` showed all three VMs running with no public IP, no quarantine, and no prior lease. IAP checks found the driver agent, PostgreSQL role agent, and PostgreSQL service active. A real GCS lease was acquired, the x86 hello closure published, and two submissions were made. Run `01a0d972-a5e1-71c2-a2ce-a8617c4d3677` remained at `accepted` after the driver exited because its work-root directory was absent. After creating that directory on the VM, run `01a0d975-7dec-708e-abf1-01c47b99798f` sealed `infrastructure-failure` with reason `payload-fetch-failed`; `cellctl fetch` and `verify` passed for its five manifest artifacts. Its reset evidence is a real, verified PostgreSQL 18.3 reset: settings reset and `work_mem=16384` applied from the configuration file, server restarted, `benchmark` recreated, and checkpoint/readback completed. The payload did not run.
- [x] (2026-09-25) Rebuilt only the driver image after fixing work-root creation and explicit Nix `nix-command` use at `ec80646`, registered `cell-image-driver-24vd3ay7yr3d` and the `cell-alpha` stack configuration at `250b6a0`, and recorded the protocol's live boundary at `ad5ac14` in `mori://shinzui/load-testing-infra`. Pulumi preview and apply replaced exactly the driver VM; nine other stack resources were unchanged. The fresh driver agent was active and had created its work root. A new GCS lease and submission ran the published hello closure through the PostgreSQL reset, NAR import and hash verification, supervised payload unit, and immutable publication. Run `01a0d98b-2a41-75c8-87d4-a72aa4970248` sealed `completed` with entry exit code `3` preserved; separate stdout and stderr, the 33,554,432-byte output file, and the environment and reset documents were fetched. `cellctl verify` printed `ok` for all 11 artifacts and manifest SHA-256 `86aead6e0191fd98487826601768e2a90649673caabf7c74d065f03afe744bf5`. The PostgreSQL 18.3 reset was verified again with `work_mem=16384`, source `configuration file`, exactly `benchmark` and `postgres`, and a checkpoint. After releasing the lease and stopping all three VMs, a fresh fetch and verification passed with the same manifest hash. This is live warm-cache, single-driver acceptance; cold-cache, lease races, health and metrics evidence, and crash recovery remain pending.
- [x] (2026-09-25) Created `cell-beta` with PostgreSQL 17 alongside `cell-alpha`; six labelled private VMs ran at once, then stopping `alpha` left all three `beta` VMs running. Run `01a0d994-acb2-70f5-b503-8659133d32fb` on `beta` sealed `completed` with entry exit code `3`, separate stdout and stderr, and the 33,554,432-byte output. Its reset evidence reports PostgreSQL 17.9, warm cache, all four reset steps successful, `work_mem=16384` from `configuration file`, exactly `benchmark` and `postgres`, and a checkpoint. A fresh fetch verified all 11 artifacts with manifest SHA-256 `8f224cd5461f8dcbe2cdc8c6a29e7055f45cda673f1bd7cfba8998b9d5e3f38d`. The lease was released and all six cell VMs are now stopped. The cells Pulumi backend lists `shared`, `cell-alpha`, and `cell-beta`; the disposable backend lists only `dev`. `scripts/cell/accept-race.sh beta 20` reported `20/20 rounds: exactly one winner` against the live GCS control bucket while the cell was stopped. The idle-stop safety probe now covers expired and cancelled lease objects as well as active, malformed, missing, and lookup-failed cases. Milestone 1 still needs idle-stop and determinism measurements; Milestones 2–5 retain the gaps listed below.
- [x] (2026-09-25) A fresh `pulumi preview --stack cell-alpha` against the cells backend reported ten unchanged resources while all VMs were stopped. This confirms that the stopped state is outside Pulumi's declared drift for the current cell stack.
- [ ] Deliver leased, resettable multi-instance verification cells with the generic agent, payload delivery, health gates, immutable result publication, broker, and collector roles; verify the cell protocol in Validation and Acceptance.

## Surprises & Discoveries

- Observation: the first live driver boot briefly restarted until `descriptor.json` existed, then the first admitted run crashed at `fs::create_dir` because the default work-root parent did not exist. The agent skipped the resulting nonterminal `accepted` status on restart, so that run remains visibly incomplete. The VM was given the missing directory for the next live probe, and the source now creates its configured work root at driver startup. Crash recovery still needs implementation and a new image.
  Evidence: `mori://shinzui/load-testing-infra` at project-relative paths `nixos/pkgs/cell-agent/src/src/bin/cell-agent.rs` and `nixos/pkgs/cell-agent/src/src/agent.rs` (artifact-level URIs pending); live driver journal and control-bucket `status.json` for run `01a0d972-a5e1-71c2-a2ce-a8617c4d3677` on 2026-09-25.

- Observation: the second live run proved the PostgreSQL role reset end to end but failed during payload preparation. The bundle was present on the driver at its declared 12,982,416 bytes, and `nix-store --import` printed the imported closure paths. An explicit VM probe reproduced the next command's failure: `nix path-info` refused to run because `nix-command` was disabled. The same query with `--extra-experimental-features nix-command` and `--json-format 1` returned the submitted NAR hash. The agent now supplies those flags and logs the full preparation or execution error before sealing a failure; the replacement driver image and repeat run passed live acceptance as recorded in Progress.
  Evidence: `mori://shinzui/load-testing-infra` at project-relative path `nixos/pkgs/cell-agent/src/src/runner.rs` (artifact-level URI pending); run `01a0d975-7dec-708e-abf1-01c47b99798f` fetched and digest-verified locally, with reset and result documents inspected on 2026-09-25.

- Observation: the first live `scripts/cell/upload-cell-images.sh` attempt stopped before any build because it read `imageBucket` from the disposable Pulumi program while `PULUMI_BACKEND_URL` selected the cell backend; Pulumi correctly reported "no stack selected." `scripts/cell/create.sh` had the same cross-backend dependency for the Grafana password. The cell scripts now use the fixed project image bucket and a cell-stack secret generated once or supplied explicitly. The existing builder was stopped, so the uploader now starts it before probing for cached image outputs. Bash syntax and `git diff --check` passed, and the corrected uploader completed on its idempotent rerun.
  Evidence: `mori://shinzui/load-testing-infra` at project-relative paths `scripts/cell/upload-cell-images.sh` and `scripts/cell/create.sh` (artifact-level URIs pending), commit `01b1818`, plus the live command output on 2026-09-25.

- Observation: The first parallel Rust test run failed one lease acquisition while the isolated expiry case passed. The test stores used process ID and clock nanoseconds for their paths; adding a process-local sequence removed a possible simultaneous path collision. The subsequent full ten-test suite and checked Nix package build passed. This was a test-fixture reliability issue, not a reproduced GCP lease failure.
  Evidence: `mori://shinzui/load-testing-infra` at project-relative paths `nixos/pkgs/cell-agent/src/src/store.rs` and `nixos/pkgs/cell-agent/src/src/lease.rs` (artifact-level URIs pending), commit `74871bc`.

- Observation: The earlier illustrative submission omitted fields that the standalone payload description required (`schema`, `narHash`, `closurePaths`, and `system`). The draft schema embeds the complete `cell.payload/v1` descriptor in `cell.submission/v1`, so the agent can validate the referenced closure without relying on an unstated side object. This is an interface clarification for EP-17, not live agent evidence.
  Evidence: `mori://shinzui/load-testing-infra` at project-relative paths `schemas/cell/cell.payload.v1.schema.json`, `schemas/cell/cell.submission.v1.schema.json`, and `docs/cells/protocol.md` (artifact-level URIs pending), commit `396ff30`; all golden examples and three malformed-submission controls validated locally.

- Observation: the copied Pulumi lockfile initially held `@pulumi/pulumi` 3.239.0 and `@pulumi/gcp` 8.41.1 and reported 27 transitive advisories. Refreshing the new cell program's lockfile within its existing direct version bounds resolved all reported advisories; the disposable program retains its own lockfile. The Nixpkgs revision names the standalone `rpk` package `redpanda-client`, and its Business Source License requires a package-specific Nix allowance.
  Evidence: the npm registry and upstream tags identified Pulumi SDK 3.264.0 as current; the GCP provider's latest 8.x release remains 8.41.1. The refreshed `infra/cells/package-lock.json` resolves SDK 3.264.0, provider 8.41.1, and `tar` 7.5.22; `npm ci`, `npm run build`, and `npm audit` report zero vulnerabilities. `nix eval --raw .#packages.x86_64-linux.cell-image-driver.drvPath` passed after a `redpanda-rpk`-specific `allowUnfreePredicate` was added.


## Decision Log

- Decision: Extend the storage seam with a streamed `get_file` operation for payload bundles and fetched artifacts; keep `get` for bounded JSON documents.
  Rationale: A payload closure or result may exceed the document reader's 128 MiB limit. The GCS implementation pins the observed object generation during streaming, and the agent checks both byte count and SHA-256 before Nix import. The driver image keeps its placeholder service until reset and health evidence can prevent a no-op reset from being presented as a verified run.
  Date: 2026-09-25

- Decision: A `cell.submission/v1` embeds the complete `cell.payload/v1` descriptor, including NAR hash, closure paths, target system, and command. The descriptor is separately printable by the payload publisher and can be reused unchanged across submissions.
  Rationale: The agent can validate one self-contained submission against a stable JSON Schema and verify the content-addressed closure before import. The earlier illustrative submission omitted fields that its payload producer was already required to emit.
  Date: 2026-09-25

- Decision: Build cells as a second Pulumi program, `infra/cells/`, with one stack per cell (`cell-<name>`) plus one `shared` stack, and leave the existing program `infra/pulumi/` (stack `dev`) untouched.
  Rationale: The existing program hard-codes instance names and is driven by per-run configuration edits; a cell must be durable and must never be reconfigured per run. Separate state also means a mistake in one lane cannot destroy the other.
  Date: 2026-09-20

- Decision: Keep Pulumi state for cells in a Google Cloud Storage backend selected with the `PULUMI_BACKEND_URL` environment variable, with a Cloud KMS secrets provider; never run `pulumi login` for cells.
  Rationale: `pulumi login` changes the workstation-wide current backend and would silently repoint the disposable lane, which relies on `file://./.pulumi-state` with an empty passphrase. The environment variable is per invocation. Verified in the Pulumi sources that the self-managed backend accepts `gs://` and that `pulumi stack init --secrets-provider="gcpkms://..."` exists.
  Date: 2026-09-20

- Decision: Implement leases with Google Cloud Storage object generation preconditions, and judge expiry with timestamps that both come from the storage service.
  Rationale: Creating an object with `ifGenerationMatch=0` succeeds for exactly one of any number of simultaneous writers, and rewriting with `ifGenerationMatch=<generation>` is a compare-and-swap, which is everything a lease needs, with no extra service, no database and no VM required to be running. Rejected: Pulumi configuration (mutable, not atomic, the cause of recorded cross-run leaks), a PostgreSQL advisory lock on the cell's own database (unavailable when the cell is stopped, and reset restarts that database), instance labels (no compare-and-swap that clients can rely on), Firestore (a new service for one document).
  Date: 2026-09-20

- Decision: A payload is a "NAR bundle": the zstd-compressed output of `nix-store --export` over the whole closure, named by its SHA-256, realised with `nix-store --import`. `nix copy --from` was evaluated and not adopted for version 1.
  Rationale: Nix has no released `gs://` store; the S3-compatibility route needs long-lived HMAC secrets on every VM and has a reported 403 regression in Nix 2.33 against private buckets; an HTTP cache cannot present the OAuth bearer token that the VM's service account provides. One immutable object with one digest is also the simplest possible evidence identity. The submission's `payload.kind` is an enumeration so a `nix-binary-cache` kind can be added when native support lands. This deviates from the wording of the drafting brief, which suggested `nix copy --from`.
  Date: 2026-09-20

- Decision: Write the agent and the reference client in Rust as one crate with two binaries (`cell-agent`, `cellctl`); bash is used only for thin lifecycle wrappers around `pulumi` and `gcloud`.
  Rationale: The repository already packages a Rust program with `rustPlatform.buildRustPackage` (`nixos/pkgs/haskell-bench-sidecar`), so the build path is proven; most recorded harness bugs lived in several hundred lines of bash, awk and inline Python; compare-and-swap, JSON, SHA-256 and resumable uploads need real error handling and unit tests. TypeScript would drag Node.js into every image.
  Date: 2026-09-20

- Decision: Use two buckets per GCP project: a mutable control bucket (leases, submissions, status, log chunks, payloads) and an immutable results bucket (`runs/<run-id>/`).
  Rationale: A retention policy applies to a whole bucket and would forbid the lease heartbeat's overwrites. In the results bucket the agent's service account holds only object-creator and object-viewer roles, so it cannot overwrite or delete even if the code is wrong; every write also carries `ifGenerationMatch=0`; a retention policy and versioning protect against operators.
  Date: 2026-09-20

- Decision: The PostgreSQL major version (18 by default, 17 selectable) is a property of a cell chosen at creation, not of a run.
  Rationale: NixOS runs one PostgreSQL service per machine; switching majors per run would need two data directories and custom units for little gain, because multiple cells can now coexist. A submission that asks for a major the cell does not have is rejected before anything runs.
  Date: 2026-09-20

- Decision: Reset is mandatory before every submission and cannot be skipped; per-run PostgreSQL settings are applied with `ALTER SYSTEM` from an allowlist and verified from `pg_settings`.
  Rationale: The deterministic boundary is the point of a cell. `ALTER SYSTEM RESET ALL` followed by the requested values and a restart is standard, leaves the image's `postgresql.conf` untouched, and the verification dump doubles as evidence.
  Date: 2026-09-20

- Decision: The idle policy is implemented by each VM powering itself off; Pulumi does not manage instance power state, and starting is a `gcloud compute instances start` in `scripts/cell/start.sh`.
  Rationale: Needs no extra IAM permission on the VMs, mirrors the idle watchdog the repository already uses for its builder VM, and keeps power state out of infrastructure-as-code as IR-1 asks.
  Date: 2026-09-20

- Decision: Role agents on the PostgreSQL and broker machines expose a small HTTP interface inside the cell's private network; each request carries the lease identifier and the role agent checks it against the lease object.
  Rationale: The driver cannot restart PostgreSQL remotely without SSH. A synchronous call is faster and simpler than coordinating through storage objects, and possession of the active lease is the authorisation that already governs the cell.
  Date: 2026-09-20

- Decision: Redpanda runs as its official container image, pinned by digest, fetched at image build time with `dockerTools.pullImage` and run by podman with host networking.
  Rationale: Cell VMs have no internet egress, so the image must be inside the NixOS closure. nixpkgs reliably maintains only the Redpanda client (`rpk`), and the rest of the house already runs Redpanda as a container, so versions stay comparable.
  Date: 2026-09-20

- Decision: The collector exposes two OTLP endpoints, one wired to a null exporter and one to a file exporter, instead of being reconfigured per run.
  Rationale: No per-run mutation of a shared service; the payload chooses a sink by choosing an endpoint from the environment file.
  Date: 2026-09-20

- Decision: Cell image flake outputs are named `cell-image-<role>`, not `cell-<role>-image`.
  Rationale: `scripts/upload-images.sh` treats every output ending in `-driver-image` as a disposable-lane project and would build and register a `cell-driver-image` on every lane run.
  Date: 2026-09-20

- Decision: With more than one driver, the agent on every driver runs the same command concurrently with `CELL_DRIVER_INDEX` and `CELL_DRIVER_COUNT` set; the default is one driver and kenshou will start with one.
  Rationale: The brief asks for one or more drivers. "Same program, many hosts" needs no remote-execution channel and leaves coordination to the payload.
  Date: 2026-09-20

- Decision: The project-isolation preflight becomes a sourced library that accepts a project only if it appears in a committed allowlist file whose sole entry is `tan-nb-exp`.
  Rationale: The brief asks for parameterisation; the repository's `CLAUDE.md` forbids targeting another project without a recorded decision. An allowlist makes a second project a deliberate, reviewed commit.
  Date: 2026-09-20

- Decision: Do not re-pin the disposable lane or change its `setup.sh`; do not create an ADR corpus in `load-testing-infra`.
  Rationale: The lane's pinned kiroku revision still ships the older migration executable that reads the `CODD_*` variables, so the lane works as pinned and acceptance 8 does not need the fix; re-pinning is a kiroku-characterization task. That repository has no ADR convention, and the ADR workflow forbids inventing one as an incidental edit; its durable decisions go into the normative `docs/cells/protocol.md`.
  Date: 2026-09-20

- Decision: Milestones are the five the MasterPlan lists, with unchanged meaning. Storage buckets are created in Milestone 1 because the agent needs somewhere to write, while the immutability guarantees and the manifest arrive in Milestone 4.
  Rationale: Keeps every milestone independently verifiable.
  Date: 2026-09-20

- Decision: The run role may create databases, a generic fault hook and a clock-offset bound are part of the environment file, and the fingerprint lists PostgreSQL extensions.
  Rationale: Requested by the first consumer's draft (`docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`) and by the toolkits behind it; each is generic, optional for a payload that does not need it, and cleared or re-measured by the reset, so the cell stays project-agnostic.
  Date: 2026-09-20

- Decision: Ship `pg_partman` in both PostgreSQL 17 and 18 cell images through the same `withPackages` composition already used by the local verification fixture.
  Rationale: PGMQ's partitioned queues need the extension available at server startup. The cell's later reset agent will decide which databases install it, and the fingerprint will list that installed state.
  Date: 2026-09-24


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about either repository.

The keiro runtime is a family of Haskell libraries for event sourcing and messaging on PostgreSQL. `keiro-runtime-kenshou` is a new repository that will verify that runtime. Its MasterPlan, `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`, splits the work into nineteen plans. This is plan 16. It has no hard dependency and can start immediately. It owns Integration Point 9 of the MasterPlan, "the cell protocol", which that document states as follows: a cell is a long-lived, named set of GCP machines that is leased exclusively, reset deterministically, and given work at run time rather than baked into a machine image; the protocol is generic and knows nothing about kenshou; a submission is a content-addressed payload (a Nix closure plus an entry point), an opaque work file, and an output contract (the entry point is invoked with the work file and an output directory; whatever it writes there is published, immutably and with digests, under the run's prefix in the cell's results bucket together with the cell's own fingerprint, reset evidence and health observations). The consumer is `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`, which will implement its own client in Haskell against the documents this plan defines, so everything below that a client touches is specified as storage objects and JSON, not as a library API. The kernel plan `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` is a soft relation only: its run plan travels through the cell as the opaque work file and its run directories come back inside the opaque output directory; the cell parses neither. The entry point's exit status is recorded verbatim and never interpreted, which is how kenshou's exit codes (0 passed, 1 failed, 2 usage, 3 inconclusive, 4 errored or infrastructure failure) survive the trip.

Terms. GCP is Google Cloud Platform; a VM (virtual machine, "instance") is a rented computer in Compute Engine; a zone is a data-centre location such as `us-west1-a`. Pulumi is an infrastructure-as-code tool: a program (here TypeScript) declares cloud resources, a stack is one named instantiation of that program with its own configuration and recorded state, the backend is where that state is stored, and the secrets provider encrypts secret configuration values. NixOS is a Linux distribution whose whole system is built by the Nix package manager; the Nix store (`/nix/store`) holds immutable build outputs; the closure of a store path is that path plus everything it references at run time, which is exactly what must be copied for a program to run elsewhere; a NAR is Nix's archive format and `nix-store --export` writes a stream of NARs for a list of paths that `nix-store --import` can load on another machine; a flake is a Nix project with pinned inputs and named outputs. GCS is Google Cloud Storage: buckets hold objects; every object has a generation number that changes on every overwrite; a write may carry a precondition, `ifGenerationMatch=0` meaning "only if the object does not exist" and `ifGenerationMatch=<n>` meaning "only if nobody changed it since I read generation n", and the service answers HTTP 412 when the precondition fails. A lease is a time-limited exclusive claim that must be renewed by a heartbeat and lapses by itself if the holder dies. Quarantine marks a cell as unfit until a human clears it. The reset boundary is the set of actions that return a cell to a declared state before a run. A health gate is a check whose failure means the environment, not the software under test, misbehaved; such a run is an infrastructure failure, never a regression. IAP (Identity-Aware Proxy) is Google's authenticated tunnel to VMs that have no public address, and OS Login ties SSH access to Google identities; both are used here only for debugging. Private Google Access lets a VM without an external address reach Google APIs such as storage. A service account is a non-human identity a VM runs as. VictoriaMetrics is a Prometheus-compatible time-series database and Grafana draws dashboards from it. OpenTelemetry is the tracing and metrics standard the runtime uses, OTLP is its wire protocol, and the Collector is a stand-alone process that receives OTLP and forwards or discards it. Redpanda is a Kafka-compatible message broker. A systemd unit is a supervised process on Linux, a cgroup is the kernel's accounting group for it, and `MemoryMax` is the cgroup limit beyond which the kernel kills the unit. In PostgreSQL, WAL is the write-ahead log, a checkpoint flushes dirty pages so the log can be recycled, and `shared_buffers` is its page cache. Live migration is GCP moving a running VM to another host during host maintenance. ABBA is an interleaving of candidate (A) and baseline (B) runs that cancels slow drift. SHA-256 is the digest used everywhere here, written as 64 lowercase hexadecimal characters.

What exists in `mori://shinzui/load-testing-infra` today (all paths relative to `/Users/shinzui/Keikaku/bokuno/load-testing-infra`). `CLAUDE.md` states the GCP project-isolation policy: every resource lives in project `tan-nb-exp`, region `us-west1`, zone `us-west1-a`; every script starts with a preflight that refuses to run unless the active gcloud project equals `tan-nb-exp`; every `gcloud` call passes `--project` explicitly; targeting another project is a deliberate architectural change that must be recorded before code is written. `.envrc` exports `CLOUDSDK_CORE_PROJECT`, the region and zone, `PULUMI_HOME=$PWD/infra/pulumi/.pulumi-home`, and `PULUMI_CONFIG_PASSPHRASE=""`, and loads the root `flake.nix` dev shell, which pins Pulumi 3.239.0 and provides Node.js 20, TypeScript, the Google Cloud SDK and `socat` for `x86_64-linux` and `aarch64-darwin`. `infra/pulumi/` is the existing Pulumi program (`@pulumi/pulumi` 3.239.0 and `@pulumi/gcp` 8.41.1 in `package-lock.json`): `index.ts` reads the configuration of the single stack `dev` from the committed `Pulumi.dev.yaml` and instantiates `src/components/BenchmarkEnvironment.ts`, which creates a network, a subnet `10.0.0.0/24`, an internal firewall rule for TCP 22, 5432, 9100, 9187, 3000, 8428 and 9569, an IAP SSH rule for `35.235.240.0/20`, and the components `PostgresServer.ts` (VM plus a data disk with device name `postgres-data`), `BenchmarkDriver.ts` and `MonitoringStack.ts`. Instance names are fixed (`loadtest-postgres`, `loadtest-driver`, `loadtest-monitoring`), no instance has a service account, labels or a scheduling policy, and `src/projects/index.ts` turns per-run knobs into instance metadata, which is why `scripts/run-benchmark.sh` edits Pulumi configuration before every run and forwards only a literal list of twenty-three environment variable names. State is a local file backend.

`nixos/flake.nix` builds GCE images for `x86_64-linux` with a helper `mkImage` that combines nixpkgs' `google-compute-image.nix`, `configuration-base.nix` (which enables `modules/gcp.nix`: OS Login, hardened sshd, chrony, sysctls, journald limits) and role modules. `modules/postgres.nix` (option namespace `services.benchmarkPostgres`) installs PostgreSQL 17, formats and mounts the data disk as XFS at `/var/lib/postgresql` with a carefully ordered `format-postgres-data` unit (`DefaultDependencies=false`, which fixed a boot race; keep it), disables transparent huge pages, enables `pg_stat_statements` and `auto_explain`, trusts role `benchmark` on database `benchmark` from `10.0.0.0/8`, runs node and postgres exporters on 9100 and 9187, and sets `effective_cache_size = 24GB` on a 16 GB machine, which is wrong. `modules/monitoring.nix` (`services.benchmarkMonitoring`) runs VictoriaMetrics on 8428 with a fifteen-second scrape interval whose targets are rendered at boot from the instance metadata key `victoriametrics-targets` (a JSON list of `role:ip:port` strings), plus Grafana on 3000 with provisioned dashboards; there is no OpenTelemetry Collector anywhere. `modules/haskell-bench.nix` bakes a project's binary into the driver image and runs it as `haskell-bench.service` with `MemoryMax=12G`, although the default driver has 8 GB, so the VM would run out of memory before the limit acts. `nixos/pkgs/haskell-bench-sidecar/` is a small Rust program packaged with `rustPlatform.buildRustPackage` and `cargoLock.lockFile`; it is the packaging precedent for this plan. `scripts/upload-images.sh` builds every image on the remote builder VM `nix-builder-x86` (created by `scripts/setup-nix-builder.sh`; it has internet egress and powers itself off when idle through a timer installed by `scripts/nix-builder-startup.sh.tpl`), uploads the tarball from the builder to the bucket `tan-nb-exp-load-testing-images`, registers a GCE image named `<role>-<first twelve characters of the Nix hash>`, and writes the self-link into the `dev` stack's configuration; it discovers driver images by the suffix `-driver-image`. `scripts/run-benchmark.sh <project> <experiment>` is the disposable lane: upload images, `pulumi up`, wait for readiness over IAP SSH (`scripts/iap-ssh.sh`, which wraps a `socat` workaround for a macOS OpenSSH problem), run the project's `setup.sh` and the benchmark unit, pull artifacts to `experiments/<name>/` on the laptop with `scripts/collect-results.sh` (including a full VictoriaMetrics snapshot and rendered dashboards), write `metadata.json`, and `pulumi destroy`. `nixos/projects/kiroku/setup.sh` migrates the schema by running `kiroku-store-migrate` with `CODD_*` variables; the current kiroku executable is a different program that reads `DATABASE_URL` and takes an `up` subcommand, but the lane pins kiroku revision `786282e` from June 2026, where the older executable still exists, so the lane works as pinned. `docs/masterplans/2-pluggable-per-project-haskell-library-benchmark-drivers.md` defines the lane's driver interface as its integration points IP-8 to IP-12 (project directory layout, metric names on port 9569, the `summary.json` schema, Pulumi configuration keys, and the metadata bag); the cell protocol replaces none of them and reuses none of them. `docs/user/onboarding.md`, `running-a-benchmark.md` and `benchmarking-kiroku.md` are the operator guides and record the lessons this plan acts on: the dominant noise source was PostgreSQL checkpoints (one roughly 270-second checkpoint per 600-second window, plus or minus twenty percent between runs); IAP SSH is a fragile data path; mutable shared configuration leaked between runs; a builder VM once vanished mid-build, probably through host maintenance, and nothing detects that on a measurement VM; eventlogs can fill a disk so that nothing is collected.

This plan implements the improvement request `mori://shinzui/load-testing-infra/okf/improvement-requests/concepts/IR-1` (file `docs/improvement-requests/provide-leased-low-latency-benchmark-cells-with-durable-run-evidence.md`, status `proposed`). Its nine requirements and eight acceptance criteria are quoted here because they are this plan's specification.

```text
The fast lane must provide:
1. An exclusive lease with a run id, owner, heartbeat, expiry, cancellation, and quarantine state. A cell runs at most
   one comparison at a time, and an expired lease cannot leave it silently busy.
2. A generic benchmark-runner image that accepts a content-addressed benchmark payload at runtime. Changing library
   source must not require rebuilding and registering a GCE image.
3. A deterministic reset boundary for PostgreSQL, driver work directories, and runner processes. Warm-cache and
   cold-cache policies are explicit inputs rather than accidental consequences of a previous run.
4. Candidate and baseline execution on the same active cell lease, with the order and repetitions supplied by the
   benchmark run specification.
5. Per-run directories and immutable artifact publication keyed by run id. A later run must never overwrite an earlier
   result.
6. Durable retention of the submitted run specification, runner result, stdout/stderr, raw samples, exact-window
   monitoring data, infrastructure fingerprint, reset evidence, and failure diagnostics. Each object carries a content
   digest and remains retrievable after the cell is stopped or rebuilt.
7. A compact collection path for frequent comparisons. Full monitoring snapshots, dashboard images, eventlogs, and
   long-duration profiles remain available in the existing characterization lane.
8. Health gates that identify host maintenance, unexpected background load, storage pressure, incomplete reset, and
   runner-version mismatch as infrastructure failures or inconclusive evidence, never as performance regressions.
9. An idle policy that may keep a cell warm during an active work window and otherwise stops its VMs without
   destroying their durable configuration.

Acceptance:
1. A warm cell accepts an exclusive run within 90 seconds at p95, and a stopped existing cell accepts one within three
   minutes at p95, measured over an agreed observation window.
2. Two simultaneous acquisition attempts for one cell result in one lease and one queued or rejected request; no
   benchmark processes overlap.
3. A fixture contaminates PostgreSQL and the driver workspace, releases the cell, and proves that the next run begins
   from its declared reset and cache policy.
4. Candidate and baseline payloads execute under one recorded cell lease and produce independent, immutable artifact
   trees.
5. Stopping, starting, upgrading, or quarantining the cell does not remove previously published run manifests,
   samples, logs, metrics, or machine fingerprints.
6. An operator can retrieve a run by run id and verify every artifact digest without consulting the active Pulumi stack
   or logging in to a VM.
7. A maintenance or health-gate fixture yields an infrastructure-failure or inconclusive outcome and cannot be reported
   as a regression.
8. The existing disposable characterization workflow continues to run sustained benchmarks and collect its full
   evidence set.
```

Mapping to milestones: requirement 9 and the durable, startable and stoppable stack are Milestone 1; requirement 2 is Milestone 2; requirements 1, 3, 4 (several submissions under one lease) and 8, with acceptance 1, 2, 3 and 7, are Milestone 3; requirements 5, 6 and 7, with acceptance 4, 5 and 6, are Milestone 4; acceptance 8 is Milestone 5, which also adds the two roles kenshou needs beyond IR-1 (collector and broker). IR-1's non-goals stand: the cell selects no statistical thresholds, owns no pipeline policy, and does not guarantee one physical host across stop and start. Orchestration and history belong to `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-3`, and the benchmark protocol to `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`, whose verdict vocabulary (`pass`, `regression`, `inconclusive`, `infrastructure-failure`) is why the cell's only judgement is "infrastructure failure or not".

ADR context. There is no local ADR corpus yet in this repository: `docs/adr/` does not exist and is created by `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` as a profile-governed OKF bundle (OKF is the house format of Markdown files with YAML frontmatter validated by the `okf` tool). `load-testing-infra` has no ADR corpus either. Three cross-repository decisions shape this plan. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` treats only structural checks and controlled candidate-versus-control workloads as authoritative performance evidence and historical numbers as telemetry; the cell therefore optimises for paired runs inside one lease on one reset machine rather than for comparable absolute numbers across weeks. `mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence and an explicit run identity; the run prefix, the manifest and the refusal to reuse a run identifier follow it. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact-level URI is pending; the record is `mori://shinzui/shibuya` at `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`, whose candidate manifest of exact revisions and service versions is the precedent for the cell fingerprint. The decision of this plan that the MasterPlan wants as an ADR here is "GCP infrastructure is extended in `load-testing-infra` rather than copied". When this plan completes, if `docs/adr/` exists, create it with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`; if it does not exist yet, write the ADR text into Outcomes & Retrospective and add a Progress item to promote it once plan 1 has landed. Decisions internal to the other repository (lease primitive, payload format, two buckets) are recorded in its normative `docs/cells/protocol.md`.

Conventions of `load-testing-infra` to follow there instead of the Haskell house conventions: bash scripts start with `set -euo pipefail`, the preflight, a `log()` helper writing to stderr, and pass `--project` on every `gcloud` call; shell embedded in NixOS modules goes through `pkgs.writeShellApplication` so that shellcheck runs at build time; TypeScript is strict (`tsconfig.json`), components extend `pulumi.ComponentResource` with a typed `Args` interface and `registerOutputs`, and `npm run build` is `tsc --noEmit`; NixOS role options live under a `services.<name>` namespace with `mkEnableOption`; Rust packages live in `nixos/pkgs/<name>/` with `default.nix` and `src/`. Commits are Conventional Commits made directly on the current branch.


## Plan of Work

Unless stated otherwise every path in this section is relative to `/Users/shinzui/Keikaku/bokuno/load-testing-infra`. The normative description of every document named below is written into `docs/cells/protocol.md` as the milestones proceed, and each has a JSON Schema in `schemas/cell/<name>.v1.schema.json` with a golden example in `schemas/cell/examples/`. All documents are JSON with a `schema` field of the form `cell.<name>/v1`. Identifiers (cell names, run identifiers, lease identifiers) match `[a-z0-9][a-z0-9-]{2,62}`; kenshou will use lowercase UUIDv7 text for run and lease identifiers, and the cell does not care.

### Milestone 1 — a parameterised, multi-instance cell stack

Scope: infrastructure only. At the end two named cells exist side by side in the same GCP project, each with a PostgreSQL VM, a driver VM and a monitoring VM that have no external addresses yet can read and write Cloud Storage, every resource carries labels, state is remote, cells can be stopped, started and destroyed individually, and they power themselves off when idle. Acceptance is observed with `scripts/cell/status.sh` and read-only `gcloud` listings.

First make the shared script plumbing. Create `scripts/lib/preflight.sh`, sourced by every script, which sets `LTI_GCP_PROJECT="${LTI_GCP_PROJECT:-tan-nb-exp}"`, refuses to continue unless that value appears on a line of the new committed file `config/allowed-gcp-projects` (initial content: the single line `tan-nb-exp`) and unless the active gcloud project equals it, and exports `PROJECT`, `REGION="${LTI_GCP_REGION:-us-west1}"` and `ZONE="${LTI_GCP_ZONE:-us-west1-a}"`. Replace the copied preflight block at the top of each existing script in `scripts/` with `source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"`; behaviour with default settings must be byte-for-byte the same messages. Move `build_image`, `image_hash`, `locate_tarball`, `upload_if_missing` and `register_if_missing` out of `scripts/upload-images.sh` into `scripts/lib/images.sh` and source it from there. Update `CLAUDE.md` to describe the allowlist and to say that adding a project requires a Decision Log entry citing the owning MasterPlan by `mori://` URI.

`scripts/cell/bootstrap.sh` creates, idempotently and with `gcloud` (because Pulumi cannot store state in a bucket that Pulumi has yet to create): the APIs `compute`, `storage`, `iam`, `cloudkms` and, if a billing account is configured, `billingbudgets`; the bucket `gs://${PROJECT}-pulumi-state` with uniform bucket-level access and versioning; and the KMS key ring `pulumi` with key `cells` in `${REGION}`. `scripts/cell/lib.sh` exports `PULUMI_BACKEND_URL="gs://${PROJECT}-pulumi-state/cells"`, `CELLS_DIR=infra/cells`, and the secrets provider URI `gcpkms://projects/${PROJECT}/locations/${REGION}/keyRings/pulumi/cryptoKeys/cells`, and defines `cell_pulumi() { pulumi --cwd "${CELLS_DIR}" "$@"; }`. No cell script may call `pulumi login`.

Images. Add `nixos/modules/cell-common.nix` (namespace `services.cell`: `role`, `agentPackage`; creates the unprivileged user `cellrun`, the directories `/var/lib/cell-agent` and `/run/cell-agent`, the `cell-agent.service` unit and the `cell-idle-stop` service and timer), `nixos/modules/cell-postgres.nix` (imports `modules/postgres.nix`, adds the option `services.benchmarkPostgres.package` override for major 17 or 18, raises nothing else; the settings that were wrong or run-specific are handled by reset in Milestone 3), and configurations `nixos/configuration-cell-driver.nix`, `configuration-cell-postgres.nix`, `configuration-cell-monitoring.nix`. The driver image contains no workload at all: Nix (already part of NixOS), `zstd`, PostgreSQL client tools of both majors, `rpk`, `curl`, `jq`, and the agent. Add flake outputs `cell-image-driver`, `cell-image-postgres17`, `cell-image-postgres18` and `cell-image-monitoring` to `nixos/flake.nix`. In this milestone `cell-agent.service` runs a placeholder that only writes a heartbeat file, so the stack can be proven before the agent exists. `scripts/cell/upload-cell-images.sh` builds, uploads and registers those outputs with the shared functions and records the self-links in the committed file `infra/cells/images.json`.

The Pulumi program `infra/cells/` has its own `package.json` (same two dependencies and versions as `infra/pulumi/package.json`), `tsconfig.json`, `Pulumi.yaml` (project name `load-testing-cells`) and `index.ts`, which branches on the required configuration key `kind`. For `kind: shared` (stack name `shared`) it instantiates `src/SharedResources.ts`: the control bucket `${project}-cells-control` (versioning on, a lifecycle rule deleting noncurrent versions after thirty days), the results bucket `${project}-cells-results` (hardened in Milestone 4), the service account `cell-agent` with `roles/storage.objectUser` on the control bucket and `roles/storage.objectCreator` plus `roles/storage.objectViewer` on the results bucket, and an optional `gcp.billing.Budget`. For `kind: cell` it instantiates `src/Cell.ts`.

```typescript
export interface CellArgs {
    cellName: string;                 // "alpha" -> resources named cell-alpha-*
    owner: string;                    // label value
    region: string;
    zone: string;
    subnetCidr: string;               // default "10.0.0.0/24"; each cell has its own network
    postgresMajor: 17 | 18;           // default 18
    postgres: { machineType: string; diskType: string; diskSizeGb: number; provisionedIops?: number };
    driver: { machineType: string; count: number; bootDiskSizeGb: number };
    monitoring: { machineType: string };
    broker?: { machineType: string; diskSizeGb: number };   // Milestone 5
    images: Record<"driver" | "postgres" | "monitoring" | "broker", string>;
    serviceAccountEmail: string;
    controlBucket: string;
    resultsBucket: string;
    scheduling: { onHostMaintenance: "MIGRATE" | "TERMINATE"; minCpuPlatform?: string; compactPlacement: boolean };
    grafanaAdminPassword: pulumi.Input<string>;
}
```

`Cell` creates the network `cell-<name>-net` and a subnet with `privateIpGoogleAccess: true`, the internal firewall rule (TCP 22, 5432, 9100, 9187, 3000, 8428, 9600 for role agents, and ICMP; Milestone 5 adds 4317, 4318, 4327, 4328, 8888, 9092 and 9644), the IAP SSH rule, and the instances `cell-<name>-postgres`, `cell-<name>-driver-<i>`, `cell-<name>-monitoring`. Every instance and disk gets the labels `lti-lane=cell`, `lti-cell=<name>`, `lti-role=<role>`, `lti-owner=<owner>`, `lti-managed-by=pulumi`; a `serviceAccount` block with the shared account and the single scope `https://www.googleapis.com/auth/devstorage.read_write`; a `scheduling` block from the arguments; `allowStoppingForUpdate: true`; no `desiredStatus`, so that Pulumi never fights the power state; and the metadata keys `enable-oslogin=TRUE`, `cell-name`, `cell-role`, `cell-control-bucket`, `cell-results-bucket`, `cell-peers` (a JSON object of role to private address) and, on monitoring, `victoriametrics-targets`. Defaults: PostgreSQL `n2-standard-8` with a 200 GB `pd-ssd`, driver `n2-standard-8` with one instance, monitoring `n2-standard-4`. The driver default is deliberately four times the old one: the recorded failure was a two-core driver saturating before PostgreSQL did. Stack outputs list instance names, zone, addresses and machine types.

Lifecycle scripts under `scripts/cell/`, each taking the cell name as first argument: `create.sh <name> [key=value ...]` initialises the stack `cell-<name>` with the KMS secrets provider, sets configuration from the `shared` stack's outputs, `images.json` and the overrides, runs `pulumi up`, and writes `cells/<name>/descriptor.json` (`cell.descriptor/v1`: name, project, zone, instance names, machine and disk shapes, PostgreSQL major, image self-links, bucket names, agent protocol version) and a default `cells/<name>/policy.json` (`cell.policy/v1`: `idleStopMinutes` 30, `keepWarmUntil` null, `allowFaultInjection` false) into the control bucket; `start.sh` and `stop.sh` call `gcloud compute instances start|stop --project` for the instances in the descriptor; `status.sh` prints power state, lease, quarantine and agent state; `upgrade.sh` takes the lease with purpose `upgrade` (from Milestone 3 on), runs `pulumi up` and a self-check, and releases; `destroy.sh` refuses while a lease is active, runs `pulumi destroy`, removes the stack, and leaves both buckets untouched. The idle timer fires every five minutes on every VM and powers the machine off when there is no unexpired lease, the agent state's `lastActivityAt` is older than the policy's `idleStopMinutes`, `keepWarmUntil` has passed, and uptime exceeds ten minutes; because every VM evaluates the same three objects, they stop within one timer period of one another.

Finally evaluate the determinism options on `cell-alpha` and write `docs/cells/determinism.md` with the measurements and the adopted defaults. `minCpuPlatform`: N2 machines may land on Cascade Lake or Ice Lake hosts; record the platform reported by the metadata server over ten stop and start cycles with and without `Intel Ice Lake`, and adopt the pin if the unpinned cell ever changes platform. `onHostMaintenance`: keep `MIGRATE` by default, because Milestone 3 detects the event and a terminated cell is unavailable for longer; record the reasoning. Compact placement (a resource policy with `collocation: COLLOCATED` attached to driver and PostgreSQL): measure driver-to-PostgreSQL round-trip p50 and p99 over sixty seconds with and without; adopt only if p99 improves by more than ten percent and ten consecutive starts succeed; if the provider demands `TERMINATE` for the machine family, record that and leave it off. Provisioned IOPS: `pd-ssd` performance scales with disk size and is capped by vCPU count; record the limits that apply to the chosen shape, and evaluate a Hyperdisk Balanced volume with explicit IOPS only if the machine family supports it (confirm with `gcloud compute disk-types list --project "$PROJECT" --zones "$ZONE"`), noting the monthly cost of a stopped cell either way. Add the `lti-lane=disposable` labels to the instances and the disk in `infra/pulumi/src/components/*.ts`.

### Milestone 2 — the generic cell agent and run-time payload delivery

Scope: work reaches a cell at run time. At the end, with no image rebuild and no SSH, a store path built moments ago runs on `cell-alpha`, its logs can be followed from a laptop, and its output directory appears under the run's prefix. Leases are not enforced yet; submissions are accepted from anyone who can write to the control bucket.

Create the crate `nixos/pkgs/cell-agent/` (`default.nix` with `cargoLock.lockFile`, `doCheck = true`, platforms Linux and Darwin; `src/Cargo.toml` with `serde`, `serde_json`, `sha2`, `ureq` with rustls, `anyhow`, `clap`, `time`, `tiny_http` and `zstd` only if needed). Library modules: `store` (object storage), `token`, `docs` (every `cell.*` document as a serde type), `lease`, `submission`, `runner`, `publish`, `reset`, `health`, `manifest`. Binaries: `cell-agent --role driver|postgres|broker` and `cellctl`. The storage abstraction is the seam that makes everything testable on a laptop.

```rust
pub enum Precondition { None, DoesNotExist, GenerationIs(u64) }
pub struct ObjectMeta { pub generation: u64, pub size: u64, pub updated: OffsetDateTime }
pub enum PutOutcome { Written(ObjectMeta), PreconditionFailed }

pub trait ObjectStore {
    fn get(&self, bucket: &str, name: &str) -> Result<Option<(Vec<u8>, ObjectMeta)>>;
    fn put(&self, bucket: &str, name: &str, body: &[u8], content_type: &str, pre: Precondition) -> Result<PutOutcome>;
    fn put_file(&self, bucket: &str, name: &str, path: &Path, content_type: &str, pre: Precondition) -> Result<PutOutcome>;
    fn delete(&self, bucket: &str, name: &str, pre: Precondition) -> Result<bool>;
    fn list(&self, bucket: &str, prefix: &str) -> Result<Vec<(String, ObjectMeta)>>;
    fn server_time(&self) -> Result<OffsetDateTime>;   // from the Date header of a cheap request
}
```

`GcsStore` speaks the Cloud Storage JSON API directly (`POST /upload/storage/v1/b/<bucket>/o?uploadType=media&name=...&ifGenerationMatch=...`, resumable uploads for files above 8 MiB, `GET .../o/<name>?alt=media`, HTTP 412 mapped to `PreconditionFailed`), with bearer tokens from a `TokenProvider` that is the metadata server on a VM (`http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`), `gcloud auth print-access-token` on a laptop, or the variable `CELL_GCS_TOKEN`. `FileStore` keeps objects in a directory and emulates generations under an exclusive file lock; unit tests use it exclusively and need no network.

Payloads. `scripts/cell/payload-publish.sh <flake-attr-or-store-path> <command...>` builds the path for `x86_64-linux` (on the remote builder when `BUILDER_INSTANCE` is set, as `upload-images.sh` does, because copying large closures back over IAP is the recorded weak point), runs `nix-store --export $(nix-store -qR <path>) | zstd -19`, computes the SHA-256, uploads the bundle to `payloads/sha256/<hex>.nar.zst` in the control bucket with the does-not-exist precondition (an existing object with the same name is, by construction, the same bytes), and prints a `cell.payload/v1` document: `kind: "nix-nar-bundle"`, `bundle {uri, sha256, bytes}`, `storePath`, `narHash` from `nix path-info --json`, `closurePaths`, `system`, and `command`, an array whose first element is relative to `storePath` (for kenshou `["bin/kenshou", "execute"]`). Add `nixos/pkgs/cell-fixtures/` with three `writeShellApplication` payloads exported as flake outputs `cell-fixture-hello`, `cell-fixture-contaminate` and `cell-fixture-probe`: `hello` copies the work file into the output directory, writes `result.json` and a 32 MiB random file, prints to both streams, sleeps for the number of seconds named in the work file and exits with the code named there; the other two are described in Milestone 3.

A submission is two objects under `cells/<cell>/submissions/<run-id>/` in the control bucket: `work` (opaque bytes) and then `submission.json`, written last and with the does-not-exist precondition, which is what the agent watches for.

```json
{
  "schema": "cell.submission/v1",
  "runId": "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9",
  "leaseId": "0199a3c1-0d52-7f10-8a77-6e0c4b2d9f01",
  "payload": { "kind": "nix-nar-bundle",
               "bundle": { "uri": "gs://tan-nb-exp-cells-control/payloads/sha256/9f2c...e1.nar.zst", "sha256": "9f2c...e1", "bytes": 48211934 },
               "storePath": "/nix/store/<hash>-cell-fixture-hello", "command": ["bin/cell-fixture-hello"] },
  "work": { "sha256": "41b7...0c", "bytes": 212, "mediaType": "application/json" },
  "env": { "EXAMPLE": "value" },
  "reset": { "postgres": { "major": 18, "databases": [{ "name": "benchmark", "owner": "benchmark", "template": "template0" }],
                           "settings": { "checkpoint_timeout": "30min", "max_wal_size": "16GB" } },
             "cachePolicy": "cold", "broker": { "wipe": true } },
  "limits": { "wallClockSeconds": 3600, "memoryMaxBytes": 25769803776, "outputMaxBytes": 21474836480 },
  "requires": { "protocol": "cell.protocol/v1", "minAgentVersion": "0.1.0" },
  "labels": { "arm": "candidate" }
}
```

The driver agent polls the submissions prefix every second. For a new submission it validates the document (an invalid or unsupported one gets `rejected.json` with a reason such as `unsupported-payload-kind`, `unsupported-postgres-setting`, `postgres-major-unavailable` or `run-id-already-used`, the last decided by listing `runs/<run-id>/` in the results bucket), then moves through the phases `accepted`, `resetting` (a no-op until Milestone 3), `fetching`, `running`, `publishing`, `sealed`, writing `status.json` (`cell.status/v1`: phase, timestamps, log chunk count, and at the end the outcome and manifest digest) on every transition and every ten seconds. Fetching downloads the bundle to `/var/lib/cell-agent/payloads/`, verifies size and SHA-256 before anything is unpacked, imports it with `zstd -dc | nix-store --import` (the agent runs as root, which the Nix daemon trusts to import unsigned archives; the digest, not a signature, is the identity), checks that `storePath` is now valid and that its `narHash` matches, and registers a garbage-collection root under `/nix/var/nix/gcroots/cell-agent/`. Running creates `/var/lib/cell-agent/work/<run-id>/{out,scratch}` owned by `cellrun`, writes the work file and the environment file, and starts the command as `<storePath>/<command[0]> <command[1..]> <work-file> <out-dir>` with `systemd-run --unit cell-run-<run-id> --wait --collect` and the properties `User=cellrun`, `WorkingDirectory=<scratch>`, `KillMode=control-group`, `LimitNOFILE=65536`, `RuntimeMaxSec=<wallClockSeconds>`, and `MemoryMax` set to the smaller of the submission's limit and eighty percent of the machine's memory, which repairs the old unit's limit that exceeded the machine. Standard output and error go to files; the agent uploads new bytes as numbered chunk objects `log/stdout.<n>` and `log/stderr.<n>` every five seconds, which is what `cellctl watch` follows. The environment is the submission's `env` plus `CELL_ENV_FILE`, `CELL_RUN_ID`, `CELL_SCRATCH_DIR`, `CELL_DRIVER_INDEX` and `CELL_DRIVER_COUNT`.

```json
{
  "schema": "cell.environment/v1",
  "cell": "alpha", "runId": "0199a3c2-...", "leaseId": "0199a3c1-...",
  "postgres": { "major": 18, "host": "10.0.0.2", "port": 5432, "database": "benchmark", "user": "benchmark",
                "connectionString": "host=10.0.0.2 port=5432 dbname=benchmark user=benchmark" },
  "broker": null,
  "otlp": null,
  "metrics": { "victoriaMetricsUrl": "http://10.0.0.4:8428" },
  "drivers": [{ "index": 0, "host": "10.0.0.3" }]
}
```

Publishing in this milestone uploads the output directory verbatim to `runs/<run-id>/output/` and the two log files to `runs/<run-id>/logs/`, each with the does-not-exist precondition; if the output exceeds `outputMaxBytes` the run is published without the excess and marked as an infrastructure failure in Milestone 3's terms. With several drivers, driver 0 is the coordinator: it alone writes status and, later, the manifest; the others publish to `runs/<run-id>/output-driver-<i>/` and write a marker `driver-<i>.done` in the submission prefix, which the coordinator waits for. `cellctl submit --cell <name> --payload <payload.json> --work <file> [--env K=V] [--reset <file>]` writes the two objects and prints the run identifier; `cellctl watch --cell <name> <run-id>` prints log chunks and phases until the run is sealed or rejected and exits 0 when the outcome is `completed`, 4 on `infrastructure-failure`, 1 on `cancelled` or `timed-out`, 2 on usage errors. Add `packages.<system>.cellctl` to the root `flake.nix` and put it in the dev shell.

### Milestone 3 — leases, deterministic reset and health gates

Scope: safety and determinism. At the end a cell runs at most one client's work at a time, every run starts from a declared state and proves it, and environmental trouble is reported as such.

The lease is the single object `cells/<cell>/lease.json` in the control bucket.

```json
{
  "schema": "cell.lease/v1",
  "leaseId": "0199a3c1-0d52-7f10-8a77-6e0c4b2d9f01",
  "cell": "alpha", "owner": "nadeem@workstation", "purpose": "fixture-abba",
  "ttlSeconds": 120, "acquiredAt": "2026-09-20T18:00:00Z", "heartbeatAt": "2026-09-20T18:00:40Z",
  "cancelRequested": false, "runsStarted": 2
}
```

```rust
pub enum AcquireOutcome { Acquired(Lease, u64), Busy(Lease), Quarantined(Quarantine) }
pub fn acquire(store: &dyn ObjectStore, bucket: &str, cell: &str, req: &LeaseRequest) -> Result<AcquireOutcome>;
pub fn renew(store: &dyn ObjectStore, bucket: &str, lease: &Lease, generation: u64) -> Result<Option<u64>>; // None = lost
pub fn release(store: &dyn ObjectStore, bucket: &str, lease: &Lease, generation: u64) -> Result<bool>;
pub fn request_cancel(store: &dyn ObjectStore, bucket: &str, cell: &str, force: bool) -> Result<bool>;
```

Acquire writes the object with the does-not-exist precondition. On a precondition failure it reads the existing lease and its metadata; the lease is expired when the object's `updated` time plus `ttlSeconds` plus a thirty-second grace is earlier than `server_time()`, both of which come from the storage service, so no client clock is trusted; an expired lease is taken over by writing the new lease with `GenerationIs(observed)`, which again succeeds for exactly one contender; otherwise the answer is `Busy`. After winning, the client reads `cells/<cell>/quarantine.json` and, if it exists, releases and reports `Quarantined`. Renew rewrites the object with the known generation every `ttlSeconds / 3`; `None` means the lease was lost and the holder must stop submitting. Release deletes with the generation precondition. Cancel sets `cancelRequested` with compare-and-swap; `--force` lets an operator cancel someone else's lease. `cellctl lease acquire --cell <name> --owner <who> --purpose <text> [--ttl 120] [--wait <seconds>] [--start]` prints the lease and exits 0 when acquired, 1 when busy, 3 when quarantined, 4 on storage errors; `--wait` polls (a client-side queue, which satisfies "queued or rejected"), and `--start` starts the cell's instances from the descriptor when they are stopped. `cellctl lease hold` renews until interrupted, and `renew`, `release`, `status`, `cancel` and `cellctl quarantine set|clear` complete the surface. The agent now refuses any submission whose `leaseId` is not the active lease (`rejected.json`, reason `lease-mismatch`), increments `runsStarted`, polls the lease every five seconds while a run is active, and on `cancelRequested`, on a changed `leaseId` or on expiry sends SIGTERM to the unit, SIGKILL after thirty seconds, publishes what exists with outcome `cancelled` or `infrastructure-failure` (`lease-expired`), and resets to idle, so an expired lease can never leave the cell silently busy. Any number of submissions may run one after another under one lease, which is how candidate and baseline share a lease.

Reset runs before every run and cannot be skipped. On the driver: stop any `cell-run-*` unit, kill every process of user `cellrun`, delete `/var/lib/cell-agent/work/*` and that user's files under `/tmp` and `/dev/shm`, keep the garbage-collection roots of the five most recent payloads (garbage collection itself runs only when idle and free space is low, never inside a lease), and verify that no `cellrun` process and no work directory remain. On PostgreSQL the driver agent calls the role agent, `POST http://<postgres>:9600/v1/reset` with the lease identifier, run identifier and the submission's `reset` block. The role agent checks the lease object, then: terminates all client backends; drops every database except `postgres`, `template0` and `template1`; runs `ALTER SYSTEM RESET ALL`; applies `shared_buffers` as twenty-five percent and `effective_cache_size` as seventy-five percent of the machine's memory unless the submission overrides them (this is the fix for the 24 GB value on a 16 GB machine); applies each requested setting with `ALTER SYSTEM SET` if and only if it is on the allowlist in `reset/postgres_settings.rs` (memory, WAL and checkpoint settings, `synchronous_commit`, `fsync`, `full_page_writes`, `wal_level`, `wal_compression`, planner cost constants, worker counts, autovacuum settings, logging thresholds, `track_io_timing`, and the `pg_stat_statements.*` and `auto_explain.*` families); restarts PostgreSQL; for `cachePolicy: "cold"` additionally runs `sync` and writes `3` to `/proc/sys/vm/drop_caches`, while `warm` leaves the operating system's page cache alone; recreates the requested databases from the named template; resets `pg_stat_statements` and the cumulative statistics; issues `CHECKPOINT`, so that every run begins at the same point of the checkpoint cycle, which addresses the dominant recorded noise source; and returns `cell.reset-evidence/v1`: each step with start and end times and outcome, the complete `pg_settings` rows that differ from built-in defaults with their `source`, the list of databases, the WAL position, the checkpoint statistics, the PostgreSQL version string and the cache policy applied. A failed step is retried once; a second failure quarantines the cell (`cell.quarantine/v1` with reason, run and time) and the run ends as an infrastructure failure with `incomplete-reset`.

Requests from the first consumer. The kenshou remote-execution plan (`docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` in `mori://shinzui/keiro-runtime-kenshou`) was drafted against this protocol and lists seven things that only the cell can provide; its final section, "Requests to the cell plan", is the consumer's statement of them and its client is written to tolerate their absence. All seven are generic, so they are specified here and none mentions kenshou. First, and required before any real-cell acceptance of that plan: a payload may manage its own databases. Kenshou's harness creates one fresh database per run (plus a template beside it) on the server it is given and drops them afterwards, so the run role must have the `CREATEDB` attribute, `pg_hba.conf` must admit that role to every database from the cell subnet (the inherited `nixos/modules/postgres.nix` trusts `benchmark` on the `benchmark` database only), and the reset must drop every database the role owns, not only those named in the submission; databases named in `reset.postgres.databases` are still created for payloads that prefer them. Second: decide in Milestone 1 whether the cell PostgreSQL images ship `pg_partman` (through `services.postgresql.extensions`); PGMQ's partitioned queues need it. Either way, list the available extensions in the fingerprint. Third: an optional, privileged fault hook. It is an executable on the driver named by an optional `faultHook` member of `cell.environment/v1`, it talks to the root role agents, and it implements `inject <fault> <json-args>` (printing a token), `heal <token>` and `heal-all` for the faults `net-reject`, `net-drop`, `net-delay`, `disk-fill` and `memory-limit`. It exists only when the cell policy sets `allowFaultInjection`, every injection is recorded in the published run tree, the reset always runs `heal-all`, and an injected fault suppresses the matching health gate for its declared window so that a deliberate disk-fill is not reported as `storage-pressure`. Fourth: health observations readable by the payload during the run, as a JSON-lines file named by a new environment variable `CELL_HEALTH_FILE` that the driver agent appends to (or, if a file proves awkward, a documented lease-authorised `GET /v1/health`), so that a payload can stop trusting a measurement the moment a maintenance event is announced instead of learning of it afterwards. Fifth: chrony tracking figures for every machine in the fingerprint, and a measured `clock.skewBoundMicros` in the environment file whenever a cell has more than one measurement machine, because a payload that orders events across machines needs the bound. Sixth, optional and reserved: a second PostgreSQL role machine (`postgres-b`) and a lease-authorised restart endpoint on the PostgreSQL role agent; together they would let a payload restart one of two servers independently. The capability names `postgres.second-server` and `postgres.control-hook` are reserved for them in `requires`; do not build them in this plan unless time remains after Milestone 5. Seventh: the broker's implementation and version in the environment file, so that a payload records what served it without probing an admin interface. The consumer's payload command is `["bin/kenshou", "cell", "exec"]`, a wrapper that reads the environment file and then executes its work file; nothing in the cell depends on that.

Health gates. Each role agent keeps a background hanging request on `http://metadata.google.internal/computeMetadata/v1/instance/maintenance-event?wait_for_change=true` and records every value other than `NONE` with its time; it samples `/proc/stat` and disk usage once a second into a ring buffer; `GET /v1/health?from=<t0>&to=<t1>` returns the observations for a window. The driver agent evaluates five gates and writes `cell.health/v1` (one entry per gate and machine with `status` `ok` or `tripped`, the measured value, the threshold and the time). `host-maintenance` trips when any measurement machine saw an event between reset start and run end. `background-load` trips when, in the ten-second settle window after reset and before the command starts, non-idle CPU exceeds five percent on the driver or PostgreSQL, or when CPU steal exceeds two percent over any thirty-second window during the run. `storage-pressure` trips when free space on the driver's work volume or on the PostgreSQL data volume is below twenty percent at start or below five percent at any time, or when the output exceeded `outputMaxBytes`. `incomplete-reset` trips on any reset verification failure. `version-mismatch` trips when role agents report different agent versions or system closure identifiers from the descriptor, or when the submission's `requires` cannot be met. Thresholds live in the policy object. The run result is `cell.run-result/v1`: `outcome` is `completed` when the command ran to an exit and no gate tripped, `infrastructure-failure` when any gate tripped or the cell failed (with `reasons`), `cancelled`, or `timed-out`; `entryExitCode` and `entrySignal` are always preserved. The cell has no outcome that means "slower" or "failed test": that is how a health problem can never be reported as a regression.

Fixtures. `cell-fixture-contaminate` creates tables and a second database, leaves a detached background process, fills files in its scratch directory, `/tmp` and `/dev/shm`, and warms the cache by reading its tables. `cell-fixture-probe` writes into its output directory the list of databases and relations, the processes of its user, the files it can see in those places, and the value of every setting named in its work file. `scripts/cell/accept-race.sh` starts two `cellctl lease acquire` processes at the same instant twenty times; `scripts/cell/measure-accept-latency.sh <cell> warm|stopped <n>` measures the time from the start of `cellctl lease acquire --start` to the `accepted` phase of a hello submission and prints p50 and p95. The maintenance fixture is GCP's own `gcloud compute instances simulate-maintenance-event <instance> --project "$PROJECT" --zone "$ZONE"` issued while a sixty-second hello run is active; the storage fixture fills the work volume with `fallocate` through a payload; when the policy sets `allowFaultInjection`, the agent also honours `/run/cell-agent/inject-health.json` for cheap repeatable tests.

### Milestone 4 — the immutable results bucket and artifact manifest

Scope: durable evidence. At the end every run is a sealed, digest-listed tree that outlives the cell, and retrieval and verification need nothing but read access to one bucket.

Harden the results bucket in `SharedResources.ts`: uniform bucket-level access; `retentionPolicy.retentionPeriod` from configuration (default 400 days, not locked, because locking is irreversible; record when it is locked); versioning enabled (if the provider rejects the combination at preview, keep the retention policy, drop versioning and record it); a lifecycle rule that moves objects older than ninety days to a colder storage class and never deletes; the agent's account keeps creator and viewer only, and human readers get `roles/storage.objectViewer`. Prove with a test submission that reuses a sealed run identifier, and with a direct `cellctl` debug write, that overwriting fails.

The run tree is fixed by `docs/cells/protocol.md` as layout version 1.

```text
gs://<results-bucket>/runs/<run-id>/
  manifest.json                cell.artifact-manifest/v1   written last; its presence seals the run
  submission/submission.json   the submission, byte for byte
  submission/work              the work file, byte for byte
  output/...                   the entry point's output directory, verbatim (output-driver-<i>/ for further drivers)
  logs/stdout.log  logs/stderr.log  logs/agent.log
  metrics/export.jsonl.zst     VictoriaMetrics export of every series for exactly [reset start, run end]
  metrics/window.json          the window in Unix milliseconds
  cell/result.json             cell.run-result/v1
  cell/fingerprint.json        cell.fingerprint/v1
  cell/reset-evidence.json     cell.reset-evidence/v1
  cell/health.json             cell.health/v1
```

The metrics export is `GET http://<monitoring>:8428/api/v1/export` with `match[]={__name__!=""}` and the window's `start` and `end`, streamed through zstd; it is the compact collection path, while full snapshots and rendered dashboards stay in the disposable lane. The fingerprint records, for every machine, instance name and numeric identifier, zone, machine type, CPU platform, scheduling policy, boot identifier and uptime, kernel release and command line, the transparent-huge-page mode and the `vm.*` sysctls the images set, the NixOS system closure path, the registered image name, disk types, sizes and provisioned IOPS, plus the PostgreSQL version, the agent version, the Nix version and the descriptor's digest. The manifest lists every object of the tree except itself.

```json
{
  "schema": "cell.artifact-manifest/v1", "layout": 1,
  "runId": "0199a3c2-...", "cell": "alpha", "leaseId": "0199a3c1-...", "leaseSequence": 2,
  "sealedAt": "2026-09-20T18:21:07Z", "agentVersion": "0.1.0",
  "payload": { "kind": "nix-nar-bundle", "sha256": "9f2c...e1", "storePath": "/nix/store/<hash>-cell-fixture-hello" },
  "outcome": "completed",
  "retention": { "policy": "bucket-retention", "retentionSeconds": 34560000 },
  "artifacts": [
    { "path": "cell/result.json", "sha256": "5d0e...aa", "bytes": 412, "mediaType": "application/json" },
    { "path": "output/result.json", "sha256": "77c1...3b", "bytes": 96, "mediaType": "application/json" }
  ]
}
```

Digests are computed from the local file before upload and the agent compares the size reported by the service afterwards. Media types come from a small extension table with `application/octet-stream` as the default. The agent writes the manifest's own SHA-256 into the final `status.json` so that the submitter learns it through a second channel; this is the "raw artifact manifest digest" that orchestration and evidence records cite. A crash before the manifest leaves an unsealed prefix; on restart the agent seals it with outcome `infrastructure-failure` and reason `agent-restarted`, listing what exists. `cellctl fetch --results-bucket <b> <run-id> <dir>` downloads the tree; `cellctl verify <dir-or-gs-uri>` recomputes every digest, fails on any missing, extra or different object, prints one line per artifact and the manifest digest, and exits 0, 1 (mismatch), 2 (usage) or 4 (unreadable). The guide also documents verification with no custom tool: copy the prefix with `gcloud storage cp -r`, then check each `artifacts[]` entry with `jq` and `sha256sum`.

Cost and safety close the milestone. The optional budget in the `shared` stack is a `gcp.billing.Budget` scoped to the project with thresholds at 50, 90 and 100 percent of a configured monthly amount; when the operator lacks permission on the billing account, set `budgetEnabled=false` and record it. `scripts/cell/janitor.sh [--apply]` is a dry run by default and reports: leases expired for more than an hour (deletes them), cells whose instances are running with no lease beyond the idle policy (stops them), labelled resources whose cell has no descriptor or stack (lists them with the exact `destroy` command), payload bundles older than the configured age (deletes them from the control bucket; sealed manifests still name their digests), and unsealed run prefixes older than a day.

### Milestone 5 — broker and collector roles, with the disposable lane still working

Scope: the two roles kenshou's telemetry and Kafka plans need, and proof that nothing old broke. Collector: add `services.opentelemetry-collector` to the cell monitoring image with two OTLP receivers, gRPC 4317 and HTTP 4318 feeding a pipeline whose exporter is `nop`, and gRPC 4327 and HTTP 4328 feeding a pipeline whose exporter writes JSON lines to `/var/lib/otelcol/traces.jsonl` with rotation; both pipelines use the batch processor; the collector's own metrics on 8888 are added to the scrape targets so that `otelcol_receiver_accepted_spans` and `otelcol_receiver_refused_spans` land in every run's metrics export. Reset truncates the file sink; a submission may set `collect.traces: true` to have the file published as `telemetry/traces.jsonl.zst`. The environment file's `otlp` becomes `{ "null": { "grpc": "http://<ip>:4317", "http": "http://<ip>:4318" }, "file": { "grpc": "http://<ip>:4327", "http": "http://<ip>:4328" } }`. The monitoring default is an N2 machine rather than the lane's shared-core E2 so that a slow collector does not masquerade as tracing overhead. Broker: add `nixos/modules/cell-broker.nix` and the flake output `cell-image-broker`; the Redpanda image is fetched by digest with `pkgs.dockerTools.pullImage`, loaded through `virtualisation.oci-containers` with podman and host networking, in development-container mode with one core pinned per `--smp` setting recorded in the fingerprint, data under `/var/lib/redpanda`; the role agent's reset stops the container, wipes the data directory, starts it and waits for `rpk cluster health`; its health endpoint is the same as PostgreSQL's. `Cell.ts` creates the instance only when `broker` is configured; the environment file's `broker` becomes `{ "bootstrapServers": "<ip>:9092", "adminUrl": "http://<ip>:9644" }`, and 9644 is scraped. Add two fixture payloads: `cell-fixture-otlp` posts a hundred spans as OTLP/HTTP JSON with `curl`, and `cell-fixture-kafka` uses `rpk` from its closure to create a topic, produce and consume.

Then run the disposable lane twice, exactly as its guide says, and compare the produced files with the list in `docs/user/running-a-benchmark.md` and `docs/user/benchmarking-kiroku.md`. Finish the documents: `docs/cells/protocol.md` (normative: objects, schemas, state machines, the entry-point contract, outcomes, layout version, design decisions), `docs/user/verification-cells.md` (operator guide: bootstrap, create, lease, submit, watch, fetch, verify, upgrade, quarantine, janitor, teardown, costs), a row in `docs/user/README.md`, the two lanes side by side in `CLAUDE.md`, and a `cell-agent` package entry plus the updated description in `mori.dhall`. Mark IR-1 `completed` with `completedAt`, a `resolution` that cites the run identifiers used as acceptance evidence, and an `okf log add` entry.


## Concrete Steps

Commits in `/Users/shinzui/Keikaku/bokuno/load-testing-infra` are Conventional Commits made directly on the current branch (check with `git branch --show-current`; do not create a feature branch) and end with these trailers.

```text
MasterPlan: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
ExecPlan: mori://shinzui/keiro-runtime-kenshou/plans/16-provide-leased-verification-cells-in-load-testing-infra
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Updates to this plan file are committed in `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` with the local form.

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Check the starting state. This plan expects nothing from other kenshou plans; it expects the other repository to be as described above.

```bash
cd /Users/shinzui/Keikaku/bokuno/load-testing-infra
git status --short && git log -1 --format='%h %s'
direnv allow && pulumi version                      # expect v3.239.0
gcloud auth list --filter=status:ACTIVE --format='value(account)'
gcloud config get-value project                     # expect tan-nb-exp
gcloud compute instances describe nix-builder-x86 --project tan-nb-exp --zone us-west1-a --format='value(status)'
gcloud storage buckets describe gs://tan-nb-exp-load-testing-images --project tan-nb-exp --format='value(name)'
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

The operator needs, on `tan-nb-exp`, permission to administer Compute Engine, Cloud Storage, service accounts, project IAM bindings and Cloud KMS; budget creation additionally needs a role on the billing account and is optional.

Milestone 1.

```bash
scripts/cell/bootstrap.sh
scripts/cell/upload-cell-images.sh
( cd infra/cells && npm ci && npm run build )
scripts/cell/create.sh shared
scripts/cell/create.sh alpha owner=nadeem
scripts/cell/create.sh beta owner=nadeem postgresMajor=17
scripts/cell/status.sh alpha
```

```text
cell alpha   project tan-nb-exp   zone us-west1-a   postgres 18
  cell-alpha-postgres    RUNNING  n2-standard-8  Intel Ice Lake
  cell-alpha-driver-0    RUNNING  n2-standard-8  Intel Ice Lake
  cell-alpha-monitoring  RUNNING  n2-standard-4
lease: none   quarantine: none   agent: placeholder
```

The transcript is illustrative. Then `scripts/cell/stop.sh alpha`, `scripts/cell/start.sh alpha`, and `gcloud compute instances list --project tan-nb-exp --filter='labels.lti-lane=cell' --format='table(name,status,labels.lti-cell)'` to see both cells. Confirm storage access from a VM with no external address using the debugging path: `ZONE=us-west1-a scripts/iap-ssh.sh ssh cell-alpha-driver-0 -- 'curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'`.

Milestone 2.

```bash
( cd nixos/pkgs/cell-agent/src && cargo test )
nix build .#cellctl
scripts/cell/payload-publish.sh ./nixos#cell-fixture-hello bin/cell-fixture-hello > /tmp/hello.payload.json
printf '{"sleepSeconds":5,"exitCode":3}' > /tmp/hello.work.json
RUN=$(cellctl submit --cell alpha --payload /tmp/hello.payload.json --work /tmp/hello.work.json)
cellctl watch --cell alpha "$RUN"
```

```text
[accepted]   0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9
[fetching]   bundle 9f2c...e1 46 MiB verified
[running]    cell-run-0199a3c2-... MemoryMax=25.6G
stdout | hello from cell alpha, work file has 31 bytes
stderr | this line goes to stderr
[publishing] 3 objects
[sealed]     outcome=completed entryExitCode=3
```

Exit code 3 came from the work file and was recorded, not judged. Edit the fixture's message, publish and submit again, and observe the new text without any image build.

Milestone 3.

```bash
scripts/cell/accept-race.sh alpha 20                # expect "20/20 rounds: exactly one winner"
L=$(cellctl lease acquire --cell alpha --owner "$USER" --purpose reset-proof --start --json | jq -r .leaseId)
cellctl lease hold --cell alpha --lease "$L" &
cellctl submit --cell alpha --lease "$L" --payload contaminate.payload.json --work /dev/null --wait
cellctl submit --cell alpha --lease "$L" --payload probe.payload.json --work probe-settings.json --reset cold.reset.json --wait
cellctl lease release --cell alpha --lease "$L"
scripts/cell/measure-accept-latency.sh alpha warm 20
scripts/cell/measure-accept-latency.sh alpha stopped 20
```

```text
probe: databases=[benchmark] relations=0 stray_processes=0 stray_files=0 checkpoint_timeout=30min cache_policy=cold
warm:    p50 11.4s  p95 19.8s   (limit 90s)
stopped: p50 96s    p95 141s    (limit 180s)
```

Numbers are illustrative; the limits are IR-1's. For the maintenance fixture start a sixty-second hello run, issue `gcloud compute instances simulate-maintenance-event cell-alpha-postgres --project tan-nb-exp --zone us-west1-a`, and expect the final line `[sealed] outcome=infrastructure-failure reasons=[host-maintenance:cell-alpha-postgres]` and `cellctl watch` exiting 4.

Milestone 4.

```bash
cellctl fetch --results-bucket tan-nb-exp-cells-results "$RUN" /tmp/run
cellctl verify /tmp/run
```

```text
ok  cell/fingerprint.json      sha256 1c9a...
ok  cell/health.json           sha256 8b20...
ok  output/result.json         sha256 77c1...
...
manifest sha256 e4f1...  14 artifacts  0 mismatches
```

Repeat `cellctl verify gs://tan-nb-exp-cells-results/runs/$RUN` after each of `scripts/cell/stop.sh alpha`, `start.sh`, `upgrade.sh`, `cellctl quarantine set`, and finally `scripts/cell/destroy.sh beta` for a run that was made on `beta`. Run `scripts/cell/janitor.sh` and read the dry-run report.

Milestone 5.

```bash
scripts/cell/upload-cell-images.sh && scripts/cell/upgrade.sh alpha broker.machineType=n2-standard-4
cellctl submit --cell alpha --lease "$L" --payload otlp.payload.json --work /dev/null --wait
cellctl submit --cell alpha --lease "$L" --payload kafka.payload.json --work /dev/null --wait
BENCHMARK_SCENARIO=$(pwd)/benchmarks/pgbench/smoke.sh scripts/run-benchmark.sh pgbench ep16-lane-pgbench
RUN_DURATION_SECONDS=180 KIROKU_BENCH_MODE=append-only KIROKU_BENCH_WRITERS=32 scripts/run-benchmark.sh kiroku ep16-lane-kiroku
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Both lane runs must end with `[run-benchmark] Done. Artifacts in .../experiments/<name>` and leave no `loadtest-*` instances.


## Validation and Acceptance

Milestone 1 is accepted when `cell-alpha` (PostgreSQL 18) and `cell-beta` (PostgreSQL 17) exist at the same time; `gcloud compute instances list --project tan-nb-exp --filter='labels.lti-lane=cell'` shows six instances with their cell labels; a VM without an external address reads the descriptor object from the control bucket; stopping and starting one cell does not touch the other; a cell left without a lease powers itself off after the policy's idle time and `pulumi preview` for its stack still shows no changes; `pulumi stack ls` with the cells backend lists `shared`, `cell-alpha` and `cell-beta` while `pulumi --cwd infra/pulumi stack ls` still shows the local `dev` stack; and `docs/cells/determinism.md` records measurements and a decision for all four options.

Milestone 2 is accepted when `cargo test` passes on a laptop with no network; the hello payload runs on the cell within one command sequence that contains no SSH and no image build; a changed payload runs minutes later with a different bundle digest; the entry point's exit code, standard output and standard error arrive unmodified; a bundle whose bytes were altered after upload is refused with `payload-digest-mismatch` before anything is imported; a payload that allocates beyond its limit is killed by the cgroup and reported, while the driver stays responsive; and on a two-driver cell both output trees appear.

Milestone 3 is accepted when the race script reports exactly one winner in every round and no two `cell-run-*` units ever overlap in the agent log (IR-1 acceptance 2); the probe after a contamination reports only the declared databases, no relations, no stray processes or files, the requested settings with source `configuration file` from `postgresql.auto.conf`, and the declared cache policy, under both `cold` and `warm` (acceptance 3); a submission with a setting outside the allowlist is rejected before reset; killing `cellctl lease hold` in the middle of a run ends the run within one TTL plus grace and the next client acquires the cell; the simulated maintenance event, the storage-pressure payload and a deliberately mismatched `minAgentVersion` each produce `infrastructure-failure` with the right reason and never `completed` (acceptance 7); two consecutive forced reset failures quarantine the cell and acquisition then answers 3; and the measured p95 is under 90 seconds warm and under three minutes stopped over twenty observations each (acceptance 1). If the stopped figure misses, record the boot-time breakdown and the remedy in Surprises & Discoveries before proceeding.

Milestone 4 is accepted when a candidate and a baseline fixture submitted under one lease produce two sealed trees whose manifests carry the same `leaseId` and `leaseSequence` 1 and 2 (acceptance 4); resubmitting a sealed run identifier is rejected and a direct overwrite attempt with the agent's credentials fails with HTTP 403 or 412; `cellctl verify` passes from a machine that has neither Pulumi state nor SSH access, and the `jq` plus `sha256sum` recipe agrees with it (acceptance 6); flipping one byte in a fetched copy makes `verify` exit 1 naming the file; verification of old runs still passes after stop, start, upgrade, quarantine and after destroying the cell that produced them (acceptance 5); the metrics export contains samples only inside the recorded window; and the janitor's dry run lists a deliberately abandoned lease.

Milestone 5 is accepted when the OTLP fixture's run shows `otelcol_receiver_accepted_spans` increasing by one hundred in its own metrics export and, with the file endpoint and `collect.traces`, a published trace file with one hundred spans; the Kafka fixture succeeds and a following probe finds no topics; a cell created without `broker` has no broker instance and `"broker": null` in the environment file; and both disposable-lane runs complete and produce the documented artifact sets, including `summary.json`, the VictoriaMetrics snapshot and the rendered dashboards for kiroku (acceptance 8).

The plan as a whole is accepted when all eight IR-1 acceptance criteria have recorded evidence (run identifiers and transcripts) in IR-1's `resolution`, `docs/cells/protocol.md` is sufficient for the author of `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` to write a client without reading Rust, and nothing in the cell's code, documents or schemas mentions kenshou except as an example.


## Idempotence and Recovery

Every script is written to be re-run. `bootstrap.sh`, `upload-cell-images.sh` and `create.sh` create only what is missing; images are named by content hash and payload bundles by digest, so repeated uploads are no-ops; `pulumi up` on an unchanged cell reports no changes. A `pulumi up` that fails half way is repaired by running it again; if a stack is wedged, `cell_pulumi refresh --stack cell-<name>` reconciles state with reality, and `cell_pulumi cancel` clears a stale lock left by an interrupted update. State bucket versioning allows a damaged checkpoint to be restored from the previous object version.

A client that dies leaves a lease that expires by itself; nothing needs to be cleaned for correctness, and `janitor.sh --apply` tidies the object. A lease can be force-cancelled with `cellctl lease cancel --force`. An agent that dies mid-run seals the run as an infrastructure failure on restart; a VM that dies loses nothing that was already uploaded, and because every object is written with the does-not-exist precondition a retried upload of an existing object is detected and skipped after comparing size and digest. A quarantined cell is recovered by reading the reason, running `scripts/cell/upgrade.sh <name>` or rebooting the machines, submitting the probe fixture, and then `cellctl quarantine clear`. Reset itself is idempotent: every step checks the state it wants rather than assuming the previous one.

Dangerous operations are fenced. `destroy.sh` refuses under an active lease and never touches buckets; the results bucket has a retention policy, so even a project owner cannot delete a run early; do not lock the retention policy until the layout has survived real use, because locking cannot be undone. Nothing in this plan edits or destroys the `dev` stack, the image bucket or the builder VM. Costs: a running default cell is roughly one US dollar per hour and a stopped one costs only its disks (approximate; confirm in the pricing calculator and record actual figures in the guide); if the idle timer is suspected, `scripts/cell/stop.sh <name>` is always safe without a lease. Complete teardown is `destroy.sh` for every cell, then `cell_pulumi destroy --stack shared` after deliberately emptying the control bucket; the results bucket is meant to remain.

If the disposable lane breaks after the library refactoring, `git revert` the refactoring commit; it is isolated from every cell change for exactly this reason.


## Interfaces and Dependencies

Tools, all from the repository's dev shell: Pulumi 3.239.0 with `@pulumi/pulumi` 3.239.0 and `@pulumi/gcp` 8.41.1 (keep the two programs on identical versions); Node.js 20 and TypeScript 5; Google Cloud SDK; Nix with flakes on the workstation and on the builder; Rust from nixpkgs through `rustPlatform.buildRustPackage`, with the crates `serde`, `serde_json`, `sha2`, `ureq`, `anyhow`, `clap`, `time` and `tiny_http`; on the images NixOS 26.05 (`system.stateVersion` already set), PostgreSQL 17 and 18, VictoriaMetrics, Grafana, the OpenTelemetry Collector, podman and a digest-pinned Redpanda image, `zstd`, and `rpk`. Google services: Compute Engine, Cloud Storage (JSON API with generation preconditions), IAM, Cloud KMS, optionally Cloud Billing budgets, and the metadata server's token and `maintenance-event` endpoints.

At the end of Milestone 1 these exist: `config/allowed-gcp-projects`; `scripts/lib/preflight.sh` and `scripts/lib/images.sh`; `scripts/cell/{lib,bootstrap,upload-cell-images,create,start,stop,status,upgrade,destroy}.sh`; `infra/cells/{Pulumi.yaml,package.json,tsconfig.json,index.ts,images.json,src/Cell.ts,src/SharedResources.ts}` exporting `CellArgs`; `nixos/modules/{cell-common,cell-postgres}.nix`, `nixos/configuration-cell-{driver,postgres,monitoring}.nix` and the four `cell-image-*` outputs; `docs/cells/determinism.md`; and the documents `cell.descriptor/v1` and `cell.policy/v1`. At the end of Milestone 2: `nixos/pkgs/cell-agent/` with the `ObjectStore` trait exactly as shown, `GcsStore`, `FileStore`, the binaries `cell-agent` and `cellctl` with `submit` and `watch`; `nixos/pkgs/cell-fixtures/`; `scripts/cell/payload-publish.sh`; `schemas/cell/` with `cell.payload/v1`, `cell.submission/v1`, `cell.status/v1`, `cell.environment/v1`; and the entry-point contract `<storePath>/<command...> <work-file> <out-dir>` with the five `CELL_*` variables. At the end of Milestone 3: the `lease` module with `acquire`, `renew`, `release` and `request_cancel` as shown; `cellctl lease acquire|hold|renew|release|status|cancel` and `cellctl quarantine set|clear` with the exit codes 0, 1, 2, 3, 4 as defined; role-agent endpoints `POST /v1/reset` and `GET /v1/health` on port 9600; `cell.lease/v1`, `cell.quarantine/v1`, `cell.state/v1`, `cell.reset-evidence/v1`, `cell.health/v1`, `cell.run-result/v1`; the settings allowlist; `scripts/cell/accept-race.sh` and `measure-accept-latency.sh`. At the end of Milestone 4: layout version 1 of `runs/<run-id>/`, `cell.artifact-manifest/v1`, `cell.fingerprint/v1`, `cellctl fetch` and `verify`, `scripts/cell/janitor.sh`, the hardened results bucket and the optional budget. At the end of Milestone 5: `nixos/modules/cell-broker.nix`, the `cell-image-broker` output, the collector configuration, the extended environment file, the two extra fixtures, `docs/cells/protocol.md`, `docs/user/verification-cells.md`, and the updated `CLAUDE.md`, `docs/user/README.md`, `mori.dhall` and IR-1.

What other plans consume. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` consumes `docs/cells/protocol.md` and the schemas: it writes `cell.lease/v1` and `cell.submission/v1`, publishes a `nix-nar-bundle` with command `["bin/kenshou", "cell", "exec"]` (a wrapper around run-plan execution that first reads the cell's environment file), passes per-run PostgreSQL settings in `reset.postgres.settings` with `pg.durability` fixed to durable, reads `CELL_ENV_FILE` to build its PostgreSQL and Kafka environments and its OTLP endpoint, follows `cell.status/v1`, fetches `runs/<run-id>/`, verifies against `cell.artifact-manifest/v1` as well as kenshou's own manifests inside `output/`, merges `cell/fingerprint.json` and `cell/health.json` into its run result, and maps the cell outcome `infrastructure-failure` to its own. It may reuse `scripts/iap-ssh.sh` for a debugging escape hatch. Note for that plan: the cell's run identifier names one submission, whereas a kenshou run plan executed by one submission produces many kenshou run directories, each with its own UUIDv7, inside `output/`. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` may use the results bucket as the durable home of linked data and the manifest digest as the link's anchor. `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` and `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` find their external broker and collector addresses in the environment file. If implementation changes any of this, update Integration Point 9 in `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` first and then tell the consuming plans.
