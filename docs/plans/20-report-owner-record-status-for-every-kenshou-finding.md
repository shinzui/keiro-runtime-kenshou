---
id: 20
slug: report-owner-record-status-for-every-kenshou-finding
title: "Report owner-record status for every kenshou finding"
kind: exec-plan
created_at: 2026-10-01T16:22:58Z
intention: "intention_01m3w49yheevg9mzkyfab1mqy4"
master_plan: "docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T16:22:58Z
---

# Report owner-record status for every kenshou finding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kenshou files defects it finds in the repositories that own the affected libraries. To see where
those reports have got to today, a maintainer opens about forty Markdown files across six
repositories, or reads the "Upstream issue register" table in
`docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`, which was
typed by hand and is already out of date.

After this plan, one command answers the question from the files themselves:

```bash
cabal run -v0 kenshou -- owners status
```

It prints one row per owner record that kenshou cites, with this information:

- the owner's current status and versions;
- the canonical record, when the owner marked theirs a duplicate;
- the local findings and scenarios that depend on the record;
- the owner plans that cite it, together with the Rei intention each plan carries.

With `--json` it writes a `kenshou.owner-status/v1` document that later plans and tools consume.
No language model is involved; the command is a deterministic join over files and `mori` lookups.

This is child plan EP-1 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It has no dependencies and is the root that every later child plan builds on.


## Progress

- [ ] Milestone 1: the `kenshou-owners` package reads references from `docs/findings/` and from
  the scenario catalog, and a unit test over fixture files proves the reference index.
- [ ] Milestone 2: owner records resolve through `mori path` and are parsed into `OwnerRecord`,
  following `duplicateOf`, with fixture tests for every version-vocabulary case.
- [ ] Milestone 3: owner plans that cite each record are discovered, with their `intention`
  frontmatter.
- [ ] Milestone 4: `kenshou owners status` (text and `--json`) is registered. Its JSON schema is
  checked by `just schemas-check`, and its output on the real repository matches a hand-check of
  five records.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Resolve every owner URI through the `mori path` executable rather than a path
  table or a mori library.
  Rationale: `mori path <uri>` prints the resolved file on standard output and exits 1 with
  `Error: artifact '<uri>' not found` otherwise (checked 2026-10-01). It is the registry's own
  answer, and it is how every other cross-repository lookup in this portfolio works. A
  hard-coded path table would silently rot when a checkout moves.
  Date: 2026-10-01

- Decision: Never infer status from a finding's prose.
  Rationale: `docs/findings/*.md` files have no frontmatter. Their first `Status:` line is free
  prose such as "reproduced on released Shibuya metrics 0.9.0.3 and fixed on Hackage 0.10.0.0".
  The owner record's frontmatter is the only machine-readable status, and this command reports
  it. The finding's status line is shown verbatim as context.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kenshou (this repository, `mori://shinzui/keiro-runtime-kenshou`) is a verification harness for
the keiro runtime: the Haskell libraries `pgmq-hs`, `kiroku`, `shibuya`, its PGMQ, kiroku and
Kafka adapters, and `keiro`. It is one cabal project. `cabal.project` imports the active cohort
and lists packages with the glob `kenshou-*/*.cabal`, so a new package is added by creating its
directory. Never edit that list.

The terms this plan relies on:

- **Owner record:** an OKF concept file filed in the repository that owns a runtime library. It
  is a Markdown file whose YAML frontmatter is validated against a profile.
  - A **bug report** has `type: Bug Report` and a `BUG-N` handle, and lives in that repository's
    `docs/bug-reports/`. Its profile is `coordination.bugReports` from okf-profiles v0.18.0.
  - An **improvement request** has `type: Improvement Request` and an `IR-N` handle, and lives
    in `docs/improvement-requests/`.
  - Each is addressed by a canonical `mori://` URI of the form
    `mori://<namespace>/<project>/okf/<bundle>/concepts/<HANDLE>`, for example
    `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`.
- **Mori:** the house project registry. Its CLI is `mori` and is on the development shell's
  path. `mori path <uri>` prints the absolute path of a registered artifact. A registry that has
  not re-read a repository since a record was filed cannot resolve it. Running
  `mori register --path <repo>` refreshes it.
- **Finding:** a local record in `docs/findings/<n>-<slug>.md`, numbered 1 to 49 on 2026-10-01.
  Findings have no frontmatter. The line beginning `Status:` near the top is prose, and canonical
  owner URIs appear in backticks anywhere in the body. On 2026-10-01, 41 of 49 findings cited at
  least one owner record (39 distinct: 32 bug reports and 7 improvement requests across keiro,
  kiroku, pgmq-hs, shibuya, shibuya-kafka-adapter and shibuya-pgmq-adapter). Eight cited none,
  because they are local harness defects or unattributed observations.
- **Scenario catalog and `KnownDefect`:** every scenario is a value of type `Scenario` in
  `kenshou-core/src/Kenshou/Core/Scenario.hs`, gathered into layer bundles listed in
  `kenshou-cli/src/Kenshou/Cli/Registry.hs`. A scenario may carry
  `knownDefect :: Maybe KnownDefect`. Each `KnownDefect` has these fields:
  - `reference`: a canonical URI;
  - `summary`;
  - `expectedFailures`: the failure labels the defect explains;
  - `appliesTo`: a `CohortScope`, which is either `AllCohorts` or `OnlyWhen` a list of package
    conditions.

  There is also a `KnownDefectGroup` of several defects, flattened by `individualKnownDefects`.
  `kenshou list --json` writes the catalog as `kenshou.scenario-list/v1`, including each
  scenario's known-defect reference strings (`kenshou-core/src/Kenshou/Core/Bundle.hs`).
  - Not every reference is an owner record. Some point at Keiro MasterPlans, Keiro user
    documentation, a Shibuya review concept (`mori://shinzui/shibuya/okf/reviews/concepts/REV-15`),
    or, in the selftest, a kenshou plan.
- **Commands:** a command is a `CliCommand` value (`kenshou-core/src/Kenshou/Core/Cli.hs`) with
  these fields:
  - `name`;
  - `description`;
  - `group`: one of `Discovery`, `Execution`, `Analysis`, `Evidence`, `Maintenance`, `Internal`;
  - `hidden`;
  - an optparse-applicative `parser` producing `CliEnv -> IO ExitCode`.

  `CliEnv` carries the scenario `registry`. A plan adds a command by importing it into
  `kenshou-cli/src/Kenshou/Cli/Registry.hs` and appending it to `commands`. The comment there
  states this extension contract.
- **Machine-readable output:** `--json` modes write only the requested document to standard
  output and diagnostics to standard error. Versioned JSON schemas live in `schemas/` and are
  checked by the `schemas-check` recipe in `justfile`.
- **Owner-record fields as they really are** (read on 2026-10-01):
  - `affects` is sometimes a package URI such as `mori://shinzui/shibuya/packages/shibuya-core`,
    and sometimes a project URI such as `mori://shinzui/keiro`.
  - `fixedVersion` is required by the profile when `status` is `fixed`. It is a bare version
    such as `"0.10.0.0"` or `"0.9.1.0"`, or `unreleased`.
  - `duplicateOf` is required when `status` is `duplicate`. For example, keiro BUG-1 and BUG-2
    point at `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`.
  - One kiroku record has `affectedVersion: "0.8.0.1 through 0.9.0.0"`. The profile intends a
    bare version but cannot enforce it, so the parser must keep such a value as `Unparseable`
    instead of guessing.
  - Bug-report statuses are `reported`, `confirmed`, `in-progress`, `fixed`, `wont-fix`,
    `duplicate`, `not-a-bug`, `cannot-reproduce`. Improvement-request statuses are freer,
    including `proposed`, `accepted` and `completed`. Keep the raw string.
- **Owner plans:** ExecPlans and MasterPlans in the owner repository's `docs/plans/` and
  `docs/masterplans/`, with YAML frontmatter that may include `intention: "intention_..."`, a
  Rei intention ID.
  - Plans from another repository cite a record by canonical URI. For example, keiro plan 119
    cites shibuya-kafka-adapter bugs.
  - Plans in the owning repository often cite the record by local handle or path. For example,
    keiro's `docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md`
    names keiro BUG-4 and BUG-6 locally.

Relevant ADRs:

- [ADR-1](../adr/0001-layer-packages-never-import-one-another.md): the new package must not
  import a layer package (`kenshou-pgmq`, `kenshou-kiroku`, `kenshou-shibuya`, `kenshou-kafka`,
  `kenshou-keiro`). It reads scenarios through `CliEnv`'s registry instead.
- [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md): known-defect
  references are canonical `mori://` URIs; an owner bug report is filed only for promised
  behavior; and the finding plus the MasterPlan register record its URI. This plan computes what
  that register records by hand.

No cross-repository ADR governs this plan.


## Plan of Work

Create a library package `kenshou-owners/` (`kenshou-owners/kenshou-owners.cabal`).
- Copy the `common warnings` stanza and default extensions from
  `kenshou-evidence/kenshou-evidence.cabal`.
- It depends on `kenshou-core`, `aeson`, `containers`, `directory`, `filepath`, `process`,
  `text`, `time`, and `okf-core ^>=0.9.0.0`, which `kenshou-evidence` already uses to parse OKF
  frontmatter through `Okf.Document`.
- Add an hspec test suite `kenshou-owners-test`, and add
  `cabal test kenshou-owners:test:kenshou-owners-test` to the `haskell-test` recipe in `justfile`.

Module `Kenshou.Owners.Reference` extracts references.
- Scan `docs/findings/*.md` with a regular expression for canonical owner URIs, matching
  `mori://[a-z0-9-]+/[a-z0-9-]+/okf/[a-z0-9-]+/concepts/[A-Z]+-[0-9]+`. Also capture the
  finding's number, title (first `# ` heading) and `Status:` line.
- Walk the catalog: for every scenario in the registry, apply `individualKnownDefects` and keep
  each defect's `reference`, `expectedFailures` and `appliesTo` together with the scenario's
  identifier.
- Classify a reference string by its path segment:
  - `okf/bug-reports/concepts/BUG-` is a bug report;
  - `okf/improvement-requests/concepts/IR-` is an improvement request;
  - everything else is `OtherReference`, so plans, user docs and reviews stay visible.

Module `Kenshou.Owners.Record` resolves and parses records.
- For each distinct URI, run `mori path <uri>` through `System.Process.readProcessWithExitCode`.
  Exit 0 means the trimmed standard output is the path. Any other exit is
  `Unresolved <stderr text>`.
- Parse the file with `Okf.Document`, then read `type`, `status`, `affects`, `affectedVersion`,
  `fixedVersion`, `duplicateOf`, `lastWorkingVersion`, `resolution` and the bundle-local handle.
  The profiles name the handle field `bugId` for bug reports (`coordination.bugReports`
  declares `idField = "bugId"`) and `requestId` for improvement requests. Accept `docId` as a
  fallback for other concept types.
- File names are not handles. Shibuya, kiroku and shibuya-pgmq-adapter name their report files
  by slug (for example
  `docs/bug-reports/long-polls-starve-acknowledgements-on-a-shared-pool.md` is
  shibuya-pgmq-adapter `BUG-1`). Never derive a handle from a file name.
- Version values become `VersionValue`, which is one of:
  - `Released Version`, parsed with `Data.Version.parseVersion`, the same parser
    `cohortScopeApplies` uses;
  - `Unreleased`;
  - `Unknown`;
  - `Unparseable Text`.

  Strip surrounding quotes before parsing.
- When `status` is `duplicate` and `duplicateOf` is a `mori://` URI, resolve that target too.
  Attach it as `canonical`. Cap the chain at five hops and report a cycle as `Unresolved`.
- Use the `OwnerRecord` type exactly as the MasterPlan's Integration Point 1 specifies.

Module `Kenshou.Owners.Plans` finds owner plans.
- Derive the owner project URI from the record URI (`mori://<ns>/<project>`), resolve its root
  with `mori path <project-uri>`, and read every `docs/plans/*.md` and `docs/masterplans/*.md`.
- A plan cites a record when any of these holds:
  - it contains the canonical URI;
  - it is in the record's own repository and contains the record's repository-relative path
    (for example `docs/bug-reports/4-...md`, or a slug-named file such as
    `docs/bug-reports/long-polls-starve-acknowledgements-on-a-shared-pool.md`);
  - it is in the record's own repository and contains the bare handle as a whole word
    (`BUG-4`), but only when that repository has exactly one bundle using that handle prefix.
- Also scan the root directories of the other projects that already appear in the reference set,
  for canonical-URI citations only. This finds cross-repository fixers such as keiro plan 119,
  without crawling the whole registry.
- Read each citing plan's `title`, `kind` and `intention` frontmatter and its Progress checkbox
  counts. Cache resolved roots per run.

Module `Kenshou.Owners.Index` joins everything into an `OwnerIndex`: one entry per canonical
URI, with its record, citing findings, citing scenario defects, and citing plans.

Module `Kenshou.Owners.Cli` defines `ownersCommand :: CliCommand`.
- It has `name = "owners"`, `group = Analysis`, and subcommand `status` with these options:
  - `--findings DIR`, default `docs/findings`;
  - `--json`;
  - `--only-unresolved`.
- Text output has one block per record. It shows the URI, kind, the owner status in brackets,
  the affected and fixed versions, a `→ duplicate of <uri>` line when applicable, citing
  findings by number, citing scenarios by identifier, and citing plans by owner-repository path
  with intention ID. It ends with a summary: counts by kind and status, the number of
  unresolved URIs, and findings with no owner reference.
- JSON follows the schema written to `schemas/owner-status-v1.schema.json`. Add the command to
  `commands` in `kenshou-cli/src/Kenshou/Cli/Registry.hs` and `kenshou-owners` to
  `kenshou-cli`'s `build-depends`.

Exit codes:
- 0: success, even when some records are unresolved. Unresolved is information, not failure.
- 64: bad usage.
- 70: `mori` is not on the path at all.


## Concrete Steps

From the repository root, inside `nix develop`:

```bash
cabal build kenshou-owners
cabal test kenshou-owners:test:kenshou-owners-test
cabal run -v0 kenshou -- owners status | tail -12
cabal run -v0 kenshou -- owners status --json > /tmp/owner-status.json
check-jsonschema --schemafile schemas/owner-status-v1.schema.json /tmp/owner-status.json
```

The summary at the end of the text output should look like this. The numbers are the 2026-10-01
state; they will move as owners work.

```text
owner records cited: 39 (32 bug reports, 7 improvement requests) + N other references
  bug reports by status: fixed 16, reported 12, confirmed 2, duplicate 2
unresolved: 0
findings citing no owner record: 8 (3, 39, 41, 42, 45, 47, 48, 49)
```


## Validation and Acceptance

Unit tests, using fixture files under `kenshou-owners/test/fixtures/`, cover the following:
- URI extraction from a finding body containing two URIs and a prose status line;
- classification of bug, improvement-request and other references;
- parsing each version-vocabulary case: `"0.10.0.0"`, `unreleased`, `unknown`, and
  `"0.8.0.1 through 0.9.0.0"`, which must become `Unparseable`;
- a duplicate chain of length two, and a cycle;
- plan discovery by canonical URI, by local path, and by local handle, plus the refusal to match
  a bare handle in a different repository.

`mori` is replaced in tests by a function argument (`Resolver = Text -> IO (Either Text FilePath)`),
so tests never call the real registry.

On the real repository, acceptance is a hand-check of five records against their files:
- `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1` must show `duplicate`, followed to
  `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3` with status `fixed`.
- `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5` must show `fixed 0.9.1.0`
  and list keiro's plan 119 among citing plans.
- `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1` must list both
  keiro plan 300 and shibuya-pgmq-adapter plan 8.
- `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1` must show `fixedVersion unreleased`.
- `mori://shinzui/shibuya/okf/reviews/concepts/REV-15` must appear as an other reference cited by
  `shibuya/core/soak/...`.

Running `just schemas-check` must pass after adding the new schema to that recipe.


## Idempotence and Recovery

The command only reads files and runs `mori path`. Rerunning it is always safe. If a URI is
unresolved, run `mori register --path <owner checkout>` for that owner and rerun. The command
never writes into any repository.


## Interfaces and Dependencies

Exported for EP-2, EP-3 and EP-4 (see the MasterPlan's Integration Point 1):

```haskell
-- Kenshou.Owners.Record
data RecordKind = BugReport | ImprovementRequest | OtherReference
data VersionValue = Released Version | Unreleased | Unknown | Unparseable Text
data Resolution = Resolved FilePath | Unresolved Text | NotARecord
data OwnerRecord = OwnerRecord
  { uri :: Text, kind :: RecordKind, resolution :: Resolution, status :: Maybe Text
  , affects :: Maybe Text, affectedVersion :: Maybe VersionValue
  , fixedVersion :: Maybe VersionValue, lastWorkingVersion :: Maybe VersionValue
  , duplicateOf :: Maybe Text, canonical :: Maybe OwnerRecord }
type Resolver = Text -> IO (Either Text FilePath)
moriResolver :: Resolver

-- Kenshou.Owners.Index
data CitingDefect = CitingDefect { scenario :: ScenarioId, defect :: KnownDefect }
data CitingPlan = CitingPlan { project :: Text, path :: FilePath, title :: Text, intention :: Maybe Text }
data OwnerEntry = OwnerEntry { record :: OwnerRecord, findings :: [FindingRef], defects :: [CitingDefect], plans :: [CitingPlan] }
buildOwnerIndex :: Resolver -> Registry -> FilePath -> IO (Map Text OwnerEntry)
```

Exported command: `Kenshou.Owners.Cli.ownersCommand`. Later plans add subcommands to its
parser rather than registering new top-level commands.
