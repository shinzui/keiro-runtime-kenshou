---
id: 26
slug: adopt-the-extracted-kenshou-harness
title: "Adopt the extracted Kenshou harness"
kind: exec-plan
intention: "intention_01m7n3zt05ebprsa4q29efgp1f"
created_at: 2026-11-17T15:49:01Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-17T15:49:01Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-17T15:57:11Z
      mode: "implement"
      note: "Implement consumer assembly and source-pinned dependency migration"
---

# Adopt the extracted Kenshou harness

## Purpose / Big Picture

Use the reusable harness from mori://shinzui/kenshou while this repository owns only Keiro runtime verification. The `kenshou` executable keeps its scenarios, worker protocols, recorded verdicts and comparison keys.

## Progress

- [x] 2026-11-17: Both runtime and isolated Shibuya lanes build against the extracted kernel. The isolated lane also passes 34 tests and its PostgreSQL 18 atomicity scenario.
- [x] 2026-11-17: Removed generic source copies; Cabal fetches the upstream pin and Nix evaluates the full released payload derivation from the matching fixed-hash source.
- [x] 2026-11-17: All verification recipes pass: 350 unit/integration examples, cohort and graph checks, strict documentation/evidence validation, schemas, publication/replay/tamper checks and live harness fault selftests. ADR-24 records ownership. The assembled catalog contains 369 scenarios; both lanes register the same 61 Shibuya identifiers.

## Surprises & Discoveries

The extraction pin a1648293443ad88ff1695ed800ff44c99993574e has no generic-code divergence through this checkout's HEAD. On 2026-11-17 Hackage's kenshou-core registry endpoint returned 404 and upstream advertised no tags. Upstream HEAD is b90da77822002de46dfe310ab378f3ccd44cb1db. Its release plan records candidates only.

The historical runtime needs the scoped `kiroku-cli:http-client-tls` exception because extracted remote requires 0.4. The upstream TLS changelog says 0.4 replaces internal MD5 dependencies; `tlsManagerSettings :: ManagerSettings` remains unchanged. Nix mirrors the exception with a patch while retaining other bounds. Concurrent Cabal builds cannot share a build directory; the isolated lane now has validation output under `dist-shibuya-current`. Its standalone runner validates the isolated descriptor directly; the generic cohort CLI still expects the active cohort name.

The graph check identified three stale kernel-to-runtime-migration edges; these now belong to the consumer support component. A consumer integration test exercises real cell preparation and confirms that named Kafka registration retains the legacy broker wipe. The 80-column evidence help snapshot now includes the extracted subject and bundle URI configuration keys.

## Decision Log

Use the immutable available upstream commit pending publication. Never publish dependencies as a side effect of consumer adoption. Preserve runtime cohort versions. Keep migration names and layer strings unchanged when expressing them as bundle contributions.

## Outcomes & Retrospective

The migration is complete. `nix develop -c just verify` passed the build, all 350 examples, link-proof, cohort, graph and documentation checks. Its generated-index check exposed trailing blank-line drift. After refreshing only those derived indexes, the remaining evidence recipes exposed an old help snapshot missing the extracted configuration keys. Updating that snapshot made `just evidence-index-check evidence-profile-test evidence-check schemas-check selftest` pass (the evidence and final schema/selftest recipes were rerun after the snapshot fix). No Haskell code changed after the passing final test run. The isolated Shibuya lane passes 34 examples and a live PostgreSQL 18 atomicity scenario. Nix evaluates the released payload derivation. Full broker-backed smoke/change execution is unavailable in this environment: `container system status` reports that the API server is not running or registered with launchd. No existing verification records were regenerated; only derived indexes changed whitespace. The consumer keeps eight upstream packages at one immutable Git pin until publication. No upstream release or lifecycle gate was marked complete.

## Context and Orientation

`cabal.project` imports the active cohort, an exact dependency selection. `cohort/*.project` and their JSON descriptors must agree. The eight generic directories are copies of the extracted harness. `kenshou-suite` will own executable assembly, the runtime graph and performance contracts. The six layer packages continue to own scenarios. A bundle is a value registering scenarios, worker roles, migrations and other suite facts with the harness.

[ADR-1](../adr/0001-layer-packages-never-import-one-another.md) keeps layer fixtures independent; [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md) requires resolved identities; [ADR-4](../adr/0004-scenarios-use-provisioned-databases-and-one-ledger.md) requires one composed migration ledger. Adoption follows mori://shinzui/kenshou/docs/adopting-kenshou and mori://shinzui/kenshou (path `docs/guides/adopt-in-keiro-runtime-kenshou.md`; artifact-level URI pending).

## Plan of Work

First assemble `kenshou-suite` with `Kenshou.Cli.mainWith` and suite-owned contributions, relocate runtime oracles and attestation replay modules, then compile against the pinned dependency. Preserve shared runtime migration names in a small consumer support package so independent layers can declare them without importing one another. Next remove generic copies, update cohort solver files and descriptors and Nix package wiring. Finally update active scripts and gates, run tests and exercise list, cohort check, selftests and selected live layer runs. Inspect changed verdicts and comparison keys against retained baseline fixtures; never regenerate evidence records.

## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal build all
nix develop -c cabal run kenshou -- cohort check
nix develop -c cabal run kenshou -- list --json
nix develop -c just verify
```

Use `--project-file=cohort/shibuya-current.project --builddir=dist-shibuya-current` to build the isolated lane. Pass `--plan-json dist-shibuya-current/cache/plan.json` to `kenshou-shibuya-run` for live runs. Source dependencies must use the immutable upstream HTTPS commit, never an absolute local checkout. Run `just use-cohort released` after cohort edits to invalidate Cabal's plan cache.

## Validation and Acceptance

Both lanes compile. `cohort check` exits zero for the active released cohort, and the standalone Shibuya runner validates its isolated identity before a live run. Scenario registration retains all runtime scenario identifiers and revisions. Consumer attestation replay tests pass against immutable existing fixtures, including known defects. `just verify` passes. Run smoke and change suites with the planning commands in `docs/planning.md` when required services are available, and report any external prerequisite separately from compile or unit-test acceptance.

## Idempotence and Recovery

All changes remain reviewable in Git. Preserve recorded verification evidence. Re-run builds after fixes; invalidate solver caches through the cohort recipe. Do not restore whole working trees or discard user edits.

## Interfaces and Dependencies

Pin the eight packages of mori://shinzui/kenshou at b90da77822002de46dfe310ab378f3ccd44cb1db. `Kenshou.Core.Bundle.mkBundle` takes a `LayerId`, scenarios and worker roles. `Kenshou.Core.Env.MigrationSet` registers named migration components. `Kenshou.Core.Resource.ResourceProvider` owns named resource normalization and lifecycle. `Kenshou.Core.Cli.Program` carries graph bytes and `Kenshou.Perf.Contracts.PerfContracts`.
