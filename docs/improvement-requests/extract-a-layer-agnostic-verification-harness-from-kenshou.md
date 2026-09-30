---
type: Improvement Request
title: Extract a layer-agnostic verification harness from Kenshou
description: >-
  Remove hard-coded Keiro, Kiroku, PGMQ, Shibuya, and Kafka knowledge from the kernel and toolkit
  packages so they can be published as a reusable verification harness that other projects consume
  with their own layer suites.
generated: {by: 'process:claude-code', at: '2026-09-30T02:40:00Z'}
requestId: IR-1
status: proposed
origin: mori://shinzui/keiro-runtime-kenshou
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: '2026-09-30T02:38:00Z'
    document_timestamp: '2026-09-30T02:30:36Z'
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Independent subagent audit of the first revision against kenshou-*/src, the cabal files,
      and docs/adr. Every stated coupling site, the ADR references, and the ~27k/74k line counts
      were confirmed. The review found omissions, all applied in this revision: the broker-shaped
      wire types in Kenshou.Remote.Cell.Docs, the layer-named evidence layout and frontmatter,
      the Kiroku schema requirement in Kenshou.Remote.Selftest, the plan URI in
      Kenshou.Core.Selftest, the kenshou-core synopsis, and layer-named test fixtures. It also
      found that the kafka field is a Bool in EnvRequirements, that ADR 4 names the three
      migration sets and must be amended, and that AC-1 and AC-4 needed tightening.
acceptanceCriteria:
  - id: AC-1
    statement: >-
      No module in kenshou-core, kenshou-check, kenshou-measure, kenshou-diagnose,
      kenshou-telemetry, kenshou-evidence, or kenshou-remote names a runtime layer, imports a
      layer migration library, or hard-codes a layer's Mori URI, schema name, lock label, or
      tuning constant.
    verification: >-
      A case-insensitive search for keiro, kiroku, pgmq, shibuya, and kafka across those packages'
      src and test trees and cabal metadata returns only generic prose; no type in them is shaped
      around one resource (such as the broker types in Kenshou.Remote.Cell.Docs); and their cabal
      files no longer depend on keiro-migrations, kiroku-store-migrations, or pgmq-migration.
  - id: AC-2
    statement: >-
      Runtime layers are identified by an open, suite-registered identifier rather than a closed
      sum type, and each suite supplies its own schema migrations, environment resources, oracles,
      diagnostic labels, and default evidence subject.
    verification: >-
      Code review of Kenshou.Core.Id, Kenshou.Core.Env, and the registry wiring, plus a
      toolkit-only test suite that registers a synthetic layer without touching the Keiro-cohort
      packages.
  - id: AC-3
    statement: >-
      Protocol documents keep their current wire shape, or change it under a new versioned schema
      identifier with a reader for the old one, so sealed evidence records remain readable.
    verification: >-
      Existing JSON Schemas under schemas/ and committed records in docs/verification still
      validate, the evidence layout and frontmatter keep rendering the same layer strings, and
      golden decode tests cover every changed document, including the cell descriptor and reset
      documents.
  - id: AC-4
    statement: >-
      The Keiro runtime suite still produces equivalent verdicts after the refactor.
    verification: >-
      The smoke and change suites pass, and a paired comparison against the baseline derived from
      the last confirmed pre-refactor records shows no verdict or comparison-key change.
  - id: AC-5
    statement: >-
      The generic packages build and pass their self-tests in a cabal project that contains none
      of the Keiro-cohort layer packages.
    verification: >-
      A standalone cabal project (or CI job) listing only the generic packages builds and runs
      their selftests.
---

# Improvement Request: Extract a Layer-Agnostic Verification Harness from Kenshou

## Status

Proposed and deferred. This work waits until
[MasterPlan 1](../masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md)
(`mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime`)
is complete, so that the protocol, cell, and evidence surfaces it is still shaping are stable
before they are generalized. No plan implements this request.

Only the first two steps below are in scope for this repository. Publishing the harness as a
separate Mori project is a later decision; this request only makes that split mechanical.

## Context

About 27k of Kenshou's roughly 74k lines of Haskell are generic verification machinery:

| Package | Generic content |
|---|---|
| `kenshou-core` | run specs, scenarios, roles and worker spawn, knobs, dimensions, manifests, cohort identity, fingerprints, the change-selection component graph |
| `kenshou-check` | fact ledger, invariants (no-loss, gapless, order, duplicates, ownership, quiescence), Postgres, network, time, and process faults, linearizability checking |
| `kenshou-measure` | open- and closed-loop load, histograms, host, RTS, Postgres, and process samplers, statistics, paired comparison, health gates |
| `kenshou-diagnose` | heap-leak verdicts on post-major-GC live bytes, stall capture and classification, thread and lock graphs, profiling guards |
| `kenshou-telemetry` | telemetry arms, endpoint scraping, pipeline diagnostics, observability-overhead reports |
| `kenshou-evidence` | immutable run records, bundles, attestation, history |
| `kenshou-remote` | leased cell sessions, Nix payload publishing, file and GCS object stores |

[ADR 1](../adr/0001-layer-packages-never-import-one-another.md) already keeps the dependency
direction correct: no toolkit depends on a layer package. The remaining coupling is a finite set of
places where the kernel and toolkits *name* the layers they happen to test today.

## Coupling to Remove

Kernel (`kenshou-core`), the root of the coupling:

- `Kenshou.Core.Id` declares the closed `data Layer = Selftest | Pgmq | Kiroku | Shibuya | Kafka |
  Keiro | Runtime`, which the evidence and registry code pattern-match on.
- `Kenshou.Core.Env.Migration` imports `keiroMigrations`, `kirokuMigrations`, and
  `pgmqMigrations`, and `Kenshou.Core.Env` declares the closed
  `SchemaComponent = SchemaKiroku | SchemaKeiro | SchemaPgmq`.
- `kafka` is a dedicated flag of `EnvRequirements` (`Bool`) and a dedicated field of `WorkerInit`
  (`Kenshou.Core.Role`) and `EnvironmentSpec` (`Kenshou.Core.RunSpec`) (`Maybe Value`), and is
  threaded through `Kenshou.Core.Compat`,
  `Kenshou.Core.Role.Spawn`, and `Kenshou.Check.Process`.
- `Kenshou.Core.Bundle` enforces "Keiro scenarios require PostgreSQL 18" inline, and
  `Kenshou.Core.Selftest` asserts the Kiroku, Keiro, and PGMQ schemas exist and cites a
  Kenshou plan URI for its seeded defect.
- `Kenshou.Core.Cli` hard-codes the header "verify the Keiro runtime", and the
  `kenshou-core.cabal` synopsis names Keiro runtime verification.

Toolkits:

- `Kenshou.Check.Oracle.{Keiro,Kiroku,Pgmq}` belong with their layer packages.
- `Kenshou.Measure.Methodology` holds the recommended Kiroku pool size and range.
- `Kenshou.Diagnose.Postgres` defines Keiro, Kiroku, and PGMQ advisory-lock labels.
- `Kenshou.Evidence.Record.defaultSubject` maps each layer to its Mori URI, and
  `Kenshou.Evidence.History` hard-codes the `mori://shinzui/keiro-runtime-kenshou/okf/verification`
  bundle URI.
- `renderLayer` fixes the committed `runs/<layer>/YYYY/MM` evidence layout
  (`Kenshou.Evidence.Bundle`, `Kenshou.Evidence.Check`) and the frontmatter `layer` field
  (`Kenshou.Evidence.Frontmatter`); an open identifier must render the same strings.
- `Kenshou.Remote.Cell.Docs` defines broker-shaped wire types (`CellImages.broker`,
  `CellBroker` with `bootstrapServers`, and `BrokerReset` in `ResetBlock`) that never say
  "kafka" but encode that one resource;
  `Kenshou.Remote.Cell.{Exec,Prepare}` bind and reset a Kafka broker specifically,
  `Kenshou.Remote.Cell.RouteRules` carries the PGMQ partitioned-queue rule, and
  `Kenshou.Remote.Selftest` requires the Kiroku schema and probes `kiroku.events` and Kafka.
- Test suites in `kenshou-core`, `kenshou-evidence`, and `kenshou-remote` use layer names in
  their fixtures and must move to a synthetic layer.

## Requested Change

1. **Open the kernel.** Replace `Layer` with an open identifier that suites register, replace
   `SchemaComponent` with suite-supplied migration sets composed into one pg-migrate ledger per
   database, and
   replace the dedicated `kafka` fields with a generic map of named extra resources, each with a
   suite-provided provisioner for local runs and cells. Registry-level rules such as the
   PostgreSQL 18 constraint and cell routing rules become data that suites contribute.
   [ADR 4](../adr/0004-scenarios-use-provisioned-databases-and-one-ledger.md) names the Kiroku,
   Keiro, and PGMQ migrations explicitly, so it must be amended or superseded to keep the
   one-ledger rule while making the composed migration sets suite-supplied.
2. **Move layer knowledge into layer packages.** Relocate the three oracles, the advisory-lock
   labels, the Kiroku pool-size methodology, the default evidence subjects, and the PGMQ route
   rule into `kenshou-{keiro,kiroku,pgmq,kafka}`. The evidence bundle URI becomes configuration.
   The CLI assembles the suites through its existing registry.
3. **Prove the boundary.** Add a build that contains only the generic packages and a synthetic
   test layer, so any new coupling fails the build immediately.

After these steps, the generic packages can move to their own repository and this one becomes their
first consumer. That move itself is out of scope here.

## Constraints

- Committed verification records are immutable
  ([ADR 18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md)); a protocol
  change must stay readable by existing records, not rewrite them.
- Evidence profile changes after records are committed may only relax
  ([ADR 19](../adr/0019-relax-the-evidence-profile-after-records-are-committed.md)).
- Cell payloads stay pinned to verified cohort identities
  ([ADR 20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md)).
