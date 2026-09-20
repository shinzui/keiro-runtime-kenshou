---
id: 19
slug: publish-the-verification-evidence-profile-in-okf-profiles
title: "Publish the verification evidence profile in okf-profiles"
kind: exec-plan
created_at: 2026-09-20T17:15:36Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:36Z
---

# Publish the verification evidence profile in okf-profiles

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` is complete, this repository keeps an evidence bundle at `docs/verification/`: small, immutable Markdown records that say which verification run happened, against which exact revisions of the keiro runtime, what the verdict was, where the raw data lives (by URI and SHA-256 digest), and which deterministic verifier re-checked it. The rules those records must satisfy exist only as one local Dhall file beside the bundle. That is enough for one repository and not enough for the platform: no other repository can adopt the same record shape, the house catalog tool Mori cannot say which published contract the bundle follows, and nothing has ever proved that each rule actually rejects the mistake it was written for.

After this plan, the shape is a published, versioned house profile. Any repository can import a hash-pinned release of `okf-profiles`, select `assurance.verificationEvidence`, and get the same three concept types — `Attested Computation`, `Verification Run` and `Attestation` — with generated reference documentation and with one rejection fixture per load-bearing rule. This repository's own bundle stops carrying a hand-written rule set and points at that release instead, without a single recorded run being edited.

THE WORK OF THIS PLAN HAPPENS MOSTLY IN ANOTHER REPOSITORY. Milestones 1 and 2 are implemented in `mori://shinzui/okf-profiles`, checked out at `/Users/shinzui/Keikaku/bokuno/okf-profiles` (Dhall and shell, no Haskell). Only Milestone 3 changes this repository. This plan file lives here and is the only place progress is tracked; every update to it is committed here.

To see it working at the end: in `/Users/shinzui/Keikaku/bokuno/okf-profiles`, `bash scripts/test-verification-evidence-profile.sh` prints `OK: verification-evidence profile acceptance and rejection fixtures` and `okf profile show --registry ./package.dhall assurance.verificationEvidence --no-local` prints the three type rules; in this repository, `docs/verification/profile.dhall` is a short pinned import, `okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce` prints `OK: <n> concepts (okf_version 0.2)`, and `git log --stat` shows that no file under `docs/verification/runs/` or `docs/verification/attestations/` changed.


## Progress

Milestone 1 — The improvement request and the profile with its fixtures (in `/Users/shinzui/Keikaku/bokuno/okf-profiles`)

- [ ] Confirm the hard dependency: `docs/plans/18-…` is complete, the corpus under `docs/verification/` exists and all its gates are green.
- [ ] Confirm the okf-profiles checkout is clean, on `master`, level with `origin/master`, and that `just check` is green before any edit.
- [ ] Read the completed EP-18 plan, `docs/verification/profile.dhall` and the corpus; write the generalisation table (kept closed, opened, demoted) into this plan's Decision Log.
- [ ] Allocate the next improvement-request handle with `okf id next` and file the request (expected IR-7) with index and log entries; validate the request bundle; commit.
- [ ] Author `profiles/assurance/verification-evidence.dhall` with its header rationale; export it from `profiles/assurance/package.dhall`.
- [ ] Prove the profile loads (`dhall type` and `okf profile show --registry ./package.dhall assurance.verificationEvidence`).
- [ ] Build the acceptance bundle `fixtures/verification-evidence/` from the scrubbed real corpus.
- [ ] Build `fixtures/verification-evidence-invalid/<case>/`, one case per load-bearing rule.
- [ ] Write `scripts/test-verification-evidence-profile.sh` with diagnostic assertions.
- [ ] Run the two ADR-9 checks (exactly one advisory per case; every rule swept for load-bearingness) and record the sweep result here.
- [ ] Validate this repository's real corpus, unchanged, against the working-tree profile.
- [ ] `just check` green; commit the profile, fixtures and script.

Milestone 2 — Generated documentation, the amended ADR and the release (in `/Users/shinzui/Keikaku/bokuno/okf-profiles`)

- [ ] Add the export to the `profiles=(…)` array in `scripts/test-profile-docs.sh`; run `just docs`; confirm only `docs/profiles/verification-evidence/` is new.
- [ ] README: layout tree, script table row, catalog row, the paragraph about profiles with no `status`; CHANGELOG `[Unreleased]` entry.
- [ ] Amend ADR-6 in place; allocate and write the new ADR (expected ADR-15); update `docs/adr/index.md` and `docs/adr/log.md`; move the improvement request to `in-progress`.
- [ ] `just check` green; commit the documentation and decisions.
- [ ] Prepare the release chores on the working tree (version everywhere, new package hash, `mori.dhall` profile entry, CHANGELOG section); `just check` green; commit.
- [ ] STOP. Show the owner the two commits, the version and the hash, and obtain explicit confirmation before tagging or pushing.
- [ ] After confirmation: annotated tag, push `master` and the tag, verify the remote tag peels to the release commit and the remote semantic hash equals the local one.
- [ ] Complete the improvement request (`status: completed`, `completedAt`, `resolution`), commit, push (covered by the same confirmation).

Milestone 3 — Repointing the bundle at the published profile (in this repository)

- [ ] Replace `docs/verification/profile.dhall` with the pinned import (plus the narrowing overlay if Milestone 1 opened any vocabulary); run `dhall freeze`.
- [ ] Switch the `verification` bundle in `mori.dhall` to `Schema.ProfileBinding.Published` with the version and pin.
- [ ] Re-run every evidence gate; prove no recorded run or attestation changed; prove a deliberately broken scratch copy is still rejected.
- [ ] Update the ADR that EP-18 created, and its log; validate `docs/adr`.
- [ ] Refresh the local Mori registry for both repositories and check the pin verdict.
- [ ] Update the MasterPlan's Progress and Exec-Plan Registry; commit with this repository's trailers.
- [ ] ADR distillation pass and Outcomes & Retrospective.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep the MasterPlan's three milestones unchanged in count and meaning, and split them by repository: Milestones 1 and 2 in okf-profiles, Milestone 3 here.
  Rationale: The release is the natural boundary. Before it nothing outward-facing has happened and everything can be discarded; after it the only remaining work is local.
  Date: 2026-09-20

- Decision: Lifting the local descriptor into the catalog may only relax it — open a closed vocabulary, or demote a presence class — and may never rename a key, rename a value, or add a demand. The release gate is that this repository's committed corpus validates byte for byte against the working-tree profile.
  Rationale: Run and attestation records are immutable by the ADR that `docs/plans/18-…` owns and by `kenshou evidence check`, so a published profile that rejected one committed record could never be adopted here. The catalog's own rule that a profile codifies an observed shape points the same way.
  Date: 2026-09-20

- Decision: A vocabulary stays closed in the shared profile when its values describe verification evidence in general (`kind`, `outcome`, `subjectKind`, `components[].source`, `placement`, `data[].kind`, comparison and attestation verdicts, attestation `checks`). A vocabulary whose values name parts of the keiro runtime or kenshou's own cost model (`layer`, `tier`) becomes an open scalar in the shared profile, and this repository narrows it again in a local overlay so it loses no checking.
  Rationale: A second adopter will not have a `kiroku` layer. okf intersects a profile-scope vocabulary with a type-scope one and treats an empty vocabulary as "any", so the overlay is three lines of Dhall; this was verified with okf 0.9.0.0 (an overlay adding a profile-scope `optional` rule for `layer` rejected `layer: database` with `frontmatter value at layer must be one of […]`, while the un-overlaid profile accepted it). The implementer may move a vocabulary between the two groups after reading the real corpus and must record it here.
  Date: 2026-09-20

- Decision: Amend okf-profiles' ADR-6 in place (keep handle, filename, date and title; add a dated amendment section and refresh `description` and `generated`) rather than superseding it, and add one new ADR for the event-artifact decision.
  Rationale: The MasterPlan's milestone is "the amended ADR"; ADR-6 itself predicted this path ("If a consumer does ask, the right first move is to look at what they are already writing"), so its reasoning is confirmed rather than reversed; its filename is cited by the MasterPlan; and the corpus has a precedent for an in-place update recorded as an `Update` log entry (ADR-9, 2026-08-23). If the okf-profiles owner prefers supersession, the fallback is a second new ADR carrying `supersedes: ADR-6` and `status: Superseded` plus `supersededBy` on ADR-6.
  Date: 2026-09-20

- Decision: The rejection script asserts each case's expected diagnostic fragment, in the style of `scripts/test-pattern-applications-profile.sh`, not exit status alone as `scripts/test-reviews-profile.sh` does.
  Rationale: okf-profiles ADR-9 exists because an exit-status loop keeps passing when a fixture fails for the wrong reason; v0.18.0 moved new scripts to asserted diagnostics.
  Date: 2026-09-20

- Decision: No Seihou adoption blueprint, no change to the "Policy one" list in `Profile/V02.dhall`, and no request to grow okf's descriptor language are part of this plan.
  Rationale: The catalog's stated norm is that an adoption blueprint waits for a second adopter; the profile declares no house `status`, so the Policy-one list does not apply; digest, commit-hash and decimal formats are recorded by `docs/plans/18-…` as improvement requests to file against `mori://shinzui/okf`, and until they exist the profile states in each field description what it cannot check and leaves it to the consumer's local check.
  Date: 2026-09-20

- Decision: Follow the v0.18.0 commit shape (a feature commit, then a separate `chore(release)` commit, then an annotated tag) preceded by a `docs(improvement-requests)` commit, and treat tagging and pushing as owner-gated.
  Rationale: That is the most recent release precedent in the repository (`85caad5`, `736241f`, tag `v0.18.0`); a tag on a public repository that consumers pin by hash cannot be withdrawn quietly.
  Date: 2026-09-20

- Decision: The mechanisms this plan relies on were verified on 2026-09-20 with a throwaway profile and bundle outside any repository, using okf 0.9.0.0 and dhall 1.42.3. The diagnostic fragments quoted in this plan are real output from that prototype.
  Rationale: The plan would otherwise rest on a research summary; three facts it depends on (mixed handle and path addressing in one profile, Markdown files under `references/` needing a declared type, and the narrowing overlay) are easy to get wrong.
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The pieces and the words

OKF, the Open Knowledge Format, is a convention for a directory of Markdown files. Such a directory is a bundle. Every Markdown file in it, except the reserved files `index.md` (a generated table of contents per directory) and `log.md` (a dated change log), is a concept: a document whose YAML frontmatter (the block between two `---` lines at the top of the file) carries at least a `type`. A concept's identity is its path inside the bundle without `.md`. The house implements OKF version 0.2 in the `okf` command-line tool (`mori://shinzui/okf`, at `/Users/shinzui/Keikaku/bokuno/okf`; the installed binary reports `okf v0.9.0.0`). Version 0.2 adds optional frontmatter families, of which two matter here: `generated: {by, at}` says who or what produced the content, and `verified: [{by, at}]` is an append-only list of independent confirmations. The `by` value is an actor in one of three shapes — `<producer>/<version>`, `process:<id>`, or `human:<id>` — and only a person may write `human:`.

A profile is a Dhall file that declares a team's house rules for a bundle: which `type` strings are allowed, which frontmatter keys each type must carry, which values a key may take, where files of a type must live (`pathPattern`), and which keys hold stable handles. Dhall is a typed, total configuration language; `dhall type --file F` type-checks a file, `dhall hash --file F` prints the semantic hash (a SHA-256 of the normalised expression, unaffected by comments), and `dhall freeze F` rewrites every remote import in `F` to carry that hash so the import is reproducible. Hashes are never written by hand. `okf validate BUNDLE --profile P` reports deviations as advisory `profile:` lines and exits 0; `--profile-enforce` makes them fail; `--strict` additionally demands `title`, `description`, `generated` and the profile's `recommended` fields; `--log-enforce` fails when a concept's `generated.at` is newer than the newest entry of the nearest enclosing `log.md`. A profile has three presence classes: `required` (absence is always reported), `recommended` (reported only under `--strict`) and `optional` (absence never reported, constraints still checked when present). A handle is a short stable identifier of the form `PREFIX-N` (for example `VC-3`) stored in the frontmatter key the profile names as `idField`; only types that declare an `idPrefix` carry one, and `okf id next BUNDLE PREFIX --profile P` prints the next free number without writing anything.

`okf-profiles` (`mori://shinzui/okf-profiles`, at `/Users/shinzui/Keikaku/bokuno/okf-profiles`, GitHub `shinzui/okf-profiles`, HEAD `736241f`, newest tag `v0.18.0` on 2026-09-20) is the house catalog of such profiles. Consumers never copy a profile; they import `https://raw.githubusercontent.com/shinzui/okf-profiles/<tag>/package.dhall` with a `sha256:` pin and select an export such as `assurance.reviews`. Mori (`mori://shinzui/mori`) is the house catalog and addressing tool: a repository's `mori.dhall` manifest lists its OKF bundles under `okfBundles`, and each bundle either binds a local profile (`Schema.ProfileBinding.Local "<path>"`) or a published one (`Schema.ProfileBinding.Published` with publisher, export, version and pin). Mori gives every artifact a `mori://<namespace>/<project>/<kind>/<key>` URI. Seihou is the house scaffolding tool; okf-profiles ships Seihou "blueprints" (agent prompts that migrate a consumer's bundles), and by its ADR-7 every blueprint's version equals the catalog tag, which is why a release touches every blueprint even when none changed.

### What this plan expects from its hard dependency

`docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` must be complete. Read that plan and the corpus it produced before anything else; where this plan's expectations and that plan's final state differ, the corpus wins, and the difference is recorded in this plan's Decision Log. It delivers, per Integration Point 10 of `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`, a bundle at `docs/verification/` registered in `mori.dhall` as the OKF bundle `verification` with `profileBinding` `Local`, so a record is addressable as `mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/<path>`. The bundle holds three concept types. An `Attested Computation` (the one concept type OKF v0.2 itself defines, in its section 10) states how one verdict or headline figure is computed from raw data, which command runs it (`executor`), and which deterministic, model-free verifier checks it (`attester`); these live in `computations/<name>.md` with `VC-N` handles and point at files under `references/`. A `Verification Run` is an immutable event record in `runs/<layer>/<YYYY>/<MM>/<run-id>.md`, addressed by path because sequential handles would collide when two writers record at once; it carries identity, cohort components with their `mori://` URIs and exact revisions, environment, knobs, dimensions, outcome, and a list of data links, each `{kind, uri, digest, mediaType, bytes}`. It never contains measurements. An `Attestation` in `attestations/<YYYY>/<MM>/<attestation-id>.md` states that a named verifier at a named revision fetched the data, confirmed digests, recomputed the verdict, and what it concluded; at the same moment the run's `verified` list gains a machine entry, which is the one sanctioned mutation of a run file. Baselines and trends are derived by readers and never stored. EP-18 also delivers the local descriptor `docs/verification/profile.dhall` (built from the pinned okf-profiles package's re-exported schema and `v02` families), a seeded corpus with at least one run per kind and one comparison, the repository-local check `kenshou evidence check` for what a profile cannot express (64-hex digests, 40-hex revisions, UUIDv7 identifiers, reachable URIs, immutability against git history), and the gates wired into `just verify`. Outcomes use the vocabulary `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`; comparisons use `pass`, `regression`, `inconclusive`, `infrastructure-failure`; kinds are `correctness`, `concurrency`, `soak`, `benchmark`.

The shape this plan expects to lift is below. It is derived from the MasterPlan and the drafting brief for EP-18, not from the finished descriptor, so treat it as a checklist to compare against, not as the source.

```text
Profile scope (every type)
  required     type, title, description, generated {by: actor, at: RFC 3339 UTC}     (spliced v02.generated)
  optional     verified [{by, at}]                                                    (spliced v02.verified)
  settings     okfVersion "0.2", requireBundleVersion "0.2", allowUnknownTypes False,
               idField "computationId" (or the name EP-18 chose), guidance None

Attested Computation          pathPattern computations/*        idPrefix VC
  required     computationId (document handle VC), runtime,
               parameters[] {name, type; required?: boolean} unique by name,
               executor {resource: bundle path, receipt: list}, attester {resource: bundle path}
  optional     computation (bundle path), status (draft|stable|deprecated), stale_after (date)

Verification Run              pathPattern runs/**               no handle; addressed by path
  required     runId, scenario, layer, component, kind, tier, placement, outcome, startedAt, finishedAt,
               subject (mori URI), subjectKind,
               components[] {project: mori URI, package, revision, source; version?} unique by package,
               cohort, solverPlanHash, environment {flat mapping}, knobs[] {name, value} unique by name,
               dimensions[] {name, value} unique by name, seed, compatibilityKey,
               harnessRevision, harnessDirty (boolean),
               data[] {kind, uri: absolute URI, digest, mediaType, bytes: non-negative integer}
  as EP-18 gated them   computations[] (local VC-N handles), comparison {baseline, candidate, verdict}
  optional     knownDefects[] (mori URIs), produced[] (mori URIs), previousRun (bundle path)

Attestation                   pathPattern attestations/**       no handle; addressed by path
  required     attestationId, run (bundle path), attester (actor), attesterRevision,
               checks[] (closed list), dataDigests[], attestedAt, verdict (confirmed|refuted|incomplete)
  optional     exception {authority: human actor, reason}
```

Check the state before starting: `okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce` exits 0, `kenshou evidence check` exits 0, `git status --short docs/verification` is empty, and `okf concepts docs/verification --type "Verification Run" --profile docs/verification/profile.dhall --json` lists at least one run per kind. If any of these fails, stop: this plan cannot begin.

### How okf-profiles is organised, and every file a new profile touches

The root `package.dhall` re-exports okf's schema records and one record per profile family; `assurance = ./profiles/assurance/package.dhall` is the family for "evidence about work, rather than descriptions of it", and today exports `reviews` and `failureModes`. `Profile/Type.dhall`, `Profile/TypeRule.dhall` and `Profile/FrontmatterRules.dhall` re-export okf's record-completion modules (written `Profile::{ … }`, which fills every field that has a default); `Profile/okf.dhall` is the single pinned import of okf's schema; `Profile/V02.dhall` defines the OKF v0.2 field families once (`v02.generated`, `v02.verified`, `v02.status`, `v02.staleAfter`, …) and a profile splices them rather than re-authoring them. Naming is mechanical: export `assurance.verificationEvidence`, file `profiles/assurance/verification-evidence.dhall`, profile `name = "verification-evidence"`, fixtures `fixtures/verification-evidence/` and `fixtures/verification-evidence-invalid/<case>/`, script `scripts/test-verification-evidence-profile.sh`, generated documentation `docs/profiles/verification-evidence/`, Mori profile name `verification-evidence` (addressable as `mori://shinzui/okf-profiles/profiles/verification-evidence`). Type strings are Title Case English, house keys are camelCase, OKF's own keys are snake_case. `just check` is `just types` (a `dhall type` sweep over `package.dhall`, `mori.dhall`, `seihou-registry.dhall`, `docs/adr/profile.dhall`, `Profile/*.dhall`, `profiles/*.dhall`, `profiles/*/*.dhall`, `blueprints/*/blueprint.dhall`) plus `just test` (every `scripts/*.sh`); there is no CI directory, so these local gates are the only gates. A clean `dhall type` is not sufficient, because okf checks a profile's `okfVersion` against its rules only when it loads the profile. The repository's own `docs/adr/` and `docs/improvement-requests/` are OKF bundles whose descriptors import the working tree by relative path; no script validates `docs/improvement-requests/`, so this plan runs that validation by hand.

```text
Milestone 1
  docs/improvement-requests/add-a-shared-verification-evidence-profile.md   new (IR-7 expected)
  docs/improvement-requests/index.md, log.md                                regenerated / one entry
  profiles/assurance/verification-evidence.dhall                            new
  profiles/assurance/package.dhall                                          one field, header sentence
  fixtures/verification-evidence/**                                         new acceptance bundle
  fixtures/verification-evidence-invalid/<case>/**                          new, one directory per rule
  scripts/test-verification-evidence-profile.sh                             new
Milestone 2
  scripts/test-profile-docs.sh                                              one array element
  docs/profiles/verification-evidence/{index.md,profile.md,types/index.md,
    types/attested-computation.md,types/verification-run.md,types/attestation.md}   generated, never hand-edited
  README.md, CHANGELOG.md                                                   layout, script row, catalog row, [Unreleased]
  docs/adr/0006-attested-computation-is-excluded.md                         amended
  docs/adr/0015-<slug>.md, docs/adr/index.md, docs/adr/log.md               new ADR (handle from okf id next)
  release commit: mori.dhall, package.dhall (header), profiles/okf-v0-2.dhall (header), seihou-registry.dhall,
    README.md, CHANGELOG.md, and every blueprints/*/{blueprint.dhall,README.md,prompt.md,files/*} that names the old tag
```

The catalog's standing policies, each an ADR there, bind the new profile. ADR-1: a profile with its own lifecycle vocabulary on `status` does not also take OKF's `status` and `stale_after`; one without takes both. ADR-10 made `assurance.reviews` the deliberate exception — an event is never redrafted and does not decay, so it takes neither — and the two event types here follow it, while the definition type, which does have a lifecycle, takes OKF's pair at type scope. ADR-5: v0.2 families are spliced from `Profile/V02.dhall`, reworded with `//` if needed, never redefined. ADR-8: `recommended` is reserved for a field whose absence is a genuine deficiency in a well-run corpus; a field a complete document ordinarily lacks is `optional`. ADR-9: every rejection fixture fails for exactly one reason, and every rule is load-bearing (deleting it turns some fixture green). ADR-12: `guidance = None Text`; what a field is goes in its `description`, what a document must satisfy goes in a rule. ADR-6: no profile declares `Attested Computation` until a consumer writes one — this repository is that consumer.

### What the profile language cannot say, and four facts verified by prototype

A profile reaches one level of nesting only (a list of flat records or one flat mapping), has no regular expression for plain text, no digest, commit-hash or decimal format, conditions a field's presence only on a same-scope scalar with a closed vocabulary (`when`), and checks relations only as local handles inside the same bundle, as `mori://`-scheme URIs by syntax, or as bundle paths by existence. These were confirmed on 2026-09-20 with okf 0.9.0.0. First, one profile can mix handle-addressed and path-addressed types: with `idField = Some "computationId"`, only the type declaring `idPrefix = Some "VC"` must carry a handle, and a run's `computations` list resolves `VC-N` against the same bundle (`computations[0] references VC-99, which does not exist in this bundle`). `documentation.patternCatalog` is the in-catalog precedent. Second, a bundle-path rule pointing at another concept is written with a leading slash and the `.md` suffix (`run: /runs/kiroku/2026/09/<id>.md`) and its existence is checked. Third, a Markdown file under `references/` is an ordinary concept: with `allowUnknownTypes = False` a file such as `references/executors/run.md` is rejected with `type not in profile vocabulary`, whereas a non-Markdown file (`run.sh`, `attest.sh`) is a plain file, is listed under `# Files` in the generated index, and satisfies a bundle-path rule. If EP-18's corpus keeps Markdown under `references/`, the shared profile must declare a fourth type for it; record that in the Decision Log. Fourth, under `--strict` okf's core also resolves `executor.resource`, `attester.resource` and `computation`, so a dangling one is reported twice there, but only once in the rejection loop, which does not pass `--strict`.

### Decisions this plan rests on

There is no local ADR corpus in this repository at the time of writing: `docs/adr/` does not exist, and `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` creates it as a profile-governed OKF bundle. When implementing, scan `docs/adr/` filenames and headings and read the record EP-18 created (evidence records are immutable events that link to data and never contain it; baselines are derived, not stored), which Milestone 3 updates. This plan owes this repository no new ADR of its own — the MasterPlan assigns it none, and "the contract is published upstream and narrowed locally" is a continuation of EP-18's decision — and it owes okf-profiles one amended and one new ADR (Milestone 2). If EP-18's record turns out not to exist, or the owner wants the publication recorded separately, allocate a handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, write the record, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.

The cross-repository decisions that shape it are these. `mori://shinzui/okf/okf/adrs/concepts/ADR-14` (okf records computations and never runs them) establishes that receipts and verdicts are runtime artifacts okf never sees, which is why run and attestation records are new house concept types rather than a reading of OKF section 10. `mori://shinzui/okf/okf/adrs/concepts/ADR-13` (the `references/` convention and non-Markdown files) is the source of the third prototype fact above. `mori://shinzui/okf/okf/adrs/concepts/ADR-11` (growing the profile descriptor language) governs any future digest or decimal format and is why none is requested here. `mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence, derives freshness at query time, and warns that repeated runs need an explicit run identity rather than a timestamp; `runId` and "baselines are derived" follow it. In okf-profiles the governing records are ADR-1, ADR-5, ADR-6, ADR-7, ADR-8, ADR-9, ADR-10 and ADR-12, summarised above; their canonical handles are `mori://shinzui/okf-profiles/okf/adrs/concepts/ADR-<N>`. The local Mori registry lags that repository (it reports okf-profiles at v0.15.0 and resolves these records only by concept path, for example `mori://shinzui/okf-profiles/okf/adrs/concepts/0006-attested-computation-is-excluded`), so the handle form is the intended reference and does not resolve yet; the files are `docs/adr/0006-attested-computation-is-excluded.md`, `0008-recommended-means-a-well-run-corpus-carries-it.md`, `0009-a-rejection-fixture-must-fail-for-exactly-one-reason.md`, `0010-a-review-is-an-artifact-not-only-an-annotation.md` and `0012-guidance-is-an-evidence-backed-exception.md` there.


## Plan of Work

### Milestone 1 — The improvement request and the profile with its fixtures

Scope: everything needed for `assurance.verificationEvidence` to exist in the okf-profiles working tree and be proven by fixtures, with nothing released. At the end there is a filed improvement request, a profile file, a family export, an acceptance bundle, a tree of rejection fixtures, and a test script; `bash scripts/test-verification-evidence-profile.sh` and `just check` are green in `/Users/shinzui/Keikaku/bokuno/okf-profiles`, and this repository's real corpus validates unchanged against the new profile.

Begin with the generalisation pass, on paper. Open this repository's `docs/verification/profile.dhall` and list every rule. For each, decide one of three things and write the table into the Decision Log: lifted unchanged; vocabulary opened (expected: `layer`, `tier`); or presence demoted under ADR-8 (a field a complete record ordinarily lacks must be `optional` — `knownDefects`, `produced`, `previousRun`, `exception` and `computation` are expected there already). Nothing may be renamed or tightened. Where EP-18 gated a field with `when` (a comparison block, or `computations` demanded only for outcomes that have a verdict), lift the discriminator and the gate together, because a `when` must name a same-scope scalar with a closed vocabulary. If EP-18 modelled comparisons as a fourth concept type, lift four type rules and say so in the improvement request, the ADR and the final report; the MasterPlan's "three" is a count, not a constraint.

File the improvement request next, because the catalog admits new profiles through its own request bundle. Run `okf id next docs/improvement-requests --profile docs/improvement-requests/profile.dhall IR` (it printed `IR-7` on 2026-09-20; use what it prints) and create `docs/improvement-requests/add-a-shared-verification-evidence-profile.md`, modelled on `docs/improvement-requests/add-a-shared-terminology-profile.md` (IR-6). Its frontmatter is below. The `reviews` key is `recommended` by the request profile and therefore demanded under `--strict`; an author self-check entry, honestly labelled as such in `context`, is the precedent IR-6 set. An agent never writes a `human:` actor. The body has the sections `## Status`, `## Problem` (the local descriptor, no second adopter possible, ADR-6's condition now met — cite `mori://shinzui/keiro-runtime-kenshou/okf/verification` and the number of recorded runs), `## Requested Change` (the contract per type, the generalisation table, what is deliberately absent: no house `status`, no `stale_after` on event types, no `guidance`, no measurements, no blueprint), `## Fixtures`, `## What the profile is not` (not a results store, not a benchmark database, not a replacement for the consumer's digest check), and `## Consumer contract` (bundle `verification`, descriptor `docs/verification/profile.dhall`, `Published` binding, the validate command). Regenerate the index with `okf index docs/improvement-requests --write`, add the log entry with `okf log add`, validate the bundle, and commit.

```yaml
type: Improvement Request
title: Add a shared verification evidence profile
description: >-
  Publish assurance.verificationEvidence, a profile for immutable verification-run and attestation
  records that link to digest-pinned data, together with the Attested Computation definitions
  that say how each verdict is computed and checked.
generated:
  by: <your actor, e.g. anthropic-claude-code/<model>>
  at: "<now, RFC 3339 UTC>"
requestId: IR-7
status: proposed
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
targetPlan: mori://shinzui/keiro-runtime-kenshou/plans/19-publish-the-verification-evidence-profile-in-okf-profiles
acceptanceCriteria:
  - id: AC-1
    statement: The package exports assurance.verificationEvidence declaring the Attested Computation, Verification Run and Attestation types, with VC-N handles on the first only.
    verification: Run okf profile show on the export and inspect each type rule, idField, idPrefix and pathPattern.
  - id: AC-2
    statement: A valid fixture bundle exercises every required, conditional and optional field of every type.
    verification: Run the focused fixture script with --strict, --profile-enforce and --log-enforce.
  - id: AC-3
    statement: One rejection fixture per load-bearing rule fails for exactly one reason, and the script asserts its diagnostic.
    verification: Run each fixtures/verification-evidence-invalid case without --profile-enforce and confirm a single advisory; sweep every rule.
  - id: AC-4
    statement: Generated profile documentation describes every field and its purpose.
    verification: Run just docs and read docs/profiles/verification-evidence.
  - id: AC-5
    statement: ADR-6 is amended to admit the type for this profile and a new ADR records why a verification run is an immutable event that links to its data.
    verification: Run scripts/test-adr-bundle.sh and read both records.
  - id: AC-6
    statement: The requesting corpus validates unchanged against the export under strict enforcement.
    verification: Validate mori://shinzui/keiro-runtime-kenshou/okf/verification at its committed state against the working-tree package and confirm no record was edited.
  - id: AC-7
    statement: The profile ships in a tagged release with a CHANGELOG entry, a mori.dhall profile entry and a pinnable hash.
    verification: Run just check and compare the released remote import hash with the local hash.
reviews:
  - kind: model
    reviewer: process:<your harness>
    reviewed_at: "<now>"
    document_timestamp: "<the generated.at above>"
    scope: content-and-metadata
    outcome: commented
    provider: <provider>
    model: <model>
    effort: unspecified
    context: >-
      Author self-check, not an independent review: profile conformance under strict enforcement and
      consistency with the requesting plan and the corpus it cites.
```

Then author `profiles/assurance/verification-evidence.dhall`. Use the same import preamble as `profiles/assurance/reviews.dhall` (relative imports of `../../Profile/Type.dhall`, `FrontmatterRules.dhall`, `TypeRule.dhall`, `okf.dhall`, `V02.dhall`), never a URL. The header comment (`--|` first line, then `--` lines, with `## ` sub-headings as `reviews.dhall` does) carries the design rationale, because descriptions are echoed inside diagnostics and must stay short: what a verification run is and is not (an event, not its data; one record is one execution of one scenario against one exact set of revisions); why the three types share one profile and one bundle (a local handle resolves only inside its own bundle, so runs could not cite `VC-N` across bundles); why runs and attestations are addressed by path and only definitions carry handles (`okf id next` reads the working tree, so two concurrent recorders would allocate the same number); why `runId` exists although the path already contains it (`okf concepts --json` rows carry no path, so a record must identify itself, and a timestamp is not an identity); data links and what okf cannot check about them; why an attestation is a separate concept and how it relates to `verified` (the run stays immutable; appending a `verified` entry is the one sanctioned change; a person's sign-off is a `human:` entry a tool never writes); no `status` or `stale_after` on the event types and OKF's pair on the definition type; which vocabularies are open and how a consumer narrows them; `legacyTimestamp` deliberately absent (introduced at v0.2); and the `references/` fact. The skeleton below shows the structure and the rules that are easy to get wrong; fill the rest from the local descriptor.

```dhall
let Profile = ../../Profile/Type.dhall
let FrontmatterRules = ../../Profile/FrontmatterRules.dhall
let TypeRule = ../../Profile/TypeRule.dhall
let okf = ../../Profile/okf.dhall
let FieldRule = okf.defaults.FieldRule
let NestedRules = okf.defaults.NestedRules
let NestedFieldRule = okf.defaults.NestedFieldRule
let HandleReferenceRule = okf.defaults.HandleReferenceRule
let PathReferenceRule = okf.defaults.PathReferenceRule
let Cardinality = okf.Cardinality
let FieldFormat = okf.FieldFormat
let v02 = ../../Profile/V02.dhall

let scalar = \(name : Text) -> \(description : Text) ->
      FieldRule::{ field = name, description = Some description, cardinality = Cardinality.Scalar }
let nScalar = \(name : Text) -> \(description : Text) ->
      NestedFieldRule::{ field = name, description = Some description, cardinality = Cardinality.Scalar }
-- An empty scheme list means "a path in this bundle, never a URL".
let bundlePath = Some PathReferenceRule::{=}

let computation =
      TypeRule::{
      , type = "Attested Computation"
      , pathPattern = Some "computations/*"
      , idPrefix = Some "VC"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "computationId" "Bundle-scoped stable VC-N handle."
              // { format = Some (FieldFormat.DocumentHandle "VC") }
          , scalar "runtime" "§10.2. What executes the computation."
          , FieldRule::{ field = "executor", description = Some "§10.2. How a run is performed and what it returns."
            , objectFields = Some NestedRules::{ required =
                [ nScalar "resource" "Run instructions, as a path to a file in this bundle." // { path = bundlePath }
                , NestedFieldRule::{ field = "receipt", cardinality = Cardinality.List } ] } }
          -- parameters (elementFields, uniqueBy "name") and attester (objectFields) follow the same two shapes
          ]
        , optional = [ scalar "computation" "§10.3. The computation as a file in this bundle." // { path = bundlePath }
                     , v02.status, v02.staleAfter ]
        }
      }

let run =
      TypeRule::{
      , type = "Verification Run"
      , pathPattern = Some "runs/**"
      , frontmatter = FrontmatterRules::{
        , required =
          [ scalar "runId" "Identifier of the run, unique for all time; never derived from a timestamp."
          , scalar "layer" "Layer of the system the scenario isolates, as the suite names it."      -- open on purpose
          , scalar "kind" "What kind of evidence the run produced."
              // { allowedValues = [ "correctness", "concurrency", "soak", "benchmark" ] }
          , FieldRule::{ field = "computations", cardinality = Cardinality.List
            , description = Some "Local VC-N handles of the definitions that produced the verdicts."
            , reference = Some HandleReferenceRule::{ localPrefix = "VC" } }
          , FieldRule::{ field = "data", cardinality = Cardinality.List, uniqueBy = Some "uri"
            , description = Some "Links to the run's data in durable storage. The record never contains the data."
            , elementFields = Some NestedRules::{ required =
                [ nScalar "uri" "Absolute URI of the object." // { format = Some FieldFormat.Uri }
                , nScalar "digest" "SHA-256 of the object's bytes, 64 lowercase hex. okf cannot check the shape."
                , nScalar "bytes" "Size in bytes." // { format = Some FieldFormat.NonNegativeInteger } ] } }
          ]
        , optional = [ scalar "previousRun" "Previous recorded run of the same scenario, as a bundle path." // { path = bundlePath } ]
        }
      }

let attestation =
      TypeRule::{ type = "Attestation", pathPattern = Some "attestations/**"
      , frontmatter = FrontmatterRules::{
        , required = [ scalar "run" "The run record attested, as a bundle path." // { path = bundlePath }
                     , scalar "attester" "§7 actor of the verifier." // { format = Some FieldFormat.Actor } ]
        , optional = [ FieldRule::{ field = "exception", objectFields = Some NestedRules::{ required =
                         [ nScalar "authority" "The person who accepted the anomaly." // { format = Some FieldFormat.HumanActor }
                         , nScalar "reason" "Why it was accepted." ] } } ]
        } }

in  Profile::{
    , name = "verification-evidence"
    , description = Some "…one paragraph, as reviews.dhall does…"
    , okfVersion = "0.2"
    , requireBundleVersion = Some "0.2"
    , allowUnknownTypes = False
    , idField = Some "computationId"
    , frontmatter = FrontmatterRules::{
      , required = [ scalar "type" "…", scalar "title" "…", scalar "description" "…", v02.generated ]
      , optional = [ v02.verified ]
      }
    , types = [ computation, run, attestation ]
    }
```

Export it by adding `verificationEvidence = ./verification-evidence.dhall` to the record in `profiles/assurance/package.dhall` and one sentence to that file's header saying why it sits in this family (it records that a claim about a system was put to the test and what came of it). The root `package.dhall` needs no edit in this milestone because it already exports the family. Prove it loads with `dhall type --file profiles/assurance/verification-evidence.dhall` and `okf profile show --registry ./package.dhall assurance.verificationEvidence --no-local`; a line beginning `Failed to load profile` means a rule contradicts `okfVersion`, a `when` names a field outside its scope, or a reference names an undeclared prefix.

Build the acceptance bundle `fixtures/verification-evidence/` by mirroring the real corpus's directory shape and scrubbing it: projects become `mori://example/<name>`, data URIs become `gs://example-evidence/runs/<run-id>/<file>`, digests and revisions become plausible fake hex of the right length, actors become `process:example-recorder/1.0.0`, `process:example-attester/1.0.0` and `human:nadeem` (the catalog's existing fixture person). It must exercise every field of every type at least once: two computations (`VC-1` with an inline `# Computation` block, `VC-2` with a `computation:` path); executor and attester resources as non-Markdown files under `references/`; one run per kind; a failed run carrying `knownDefects` and `produced`; an `infrastructure-failure` run; a `previousRun` chain of two; a comparison in whatever form EP-18 chose; one confirmed attestation whose run carries the matching `process:` `verified` entry; one attestation with an `exception` whose run also carries a `human:` entry; per-month `log.md` shards exactly where the real corpus has them, plus the root `log.md`; a root `index.md` declaring `okf_version: "0.2"`. Generate indexes with `okf index fixtures/verification-evidence --write --okf-version 0.2`. Each concept's body is two or three sentences saying what the fixture demonstrates, as the `fixtures/reviews` concepts do.

Build the rejection tree `fixtures/verification-evidence-invalid/<case>/`. Each case is the smallest bundle that isolates one defect: a root `index.md` declaring the version (except the one case that tests its absence), the one offending concept, and only the files that concept needs to be otherwise valid (a computation needs its two `references/` files; an attestation needs the run it points at; a run needs a computation only if `computations` is demanded for its outcome). Author one minimal valid seed per type, then derive each case by copying the seed and making one edit; run `okf index <case> --write --okf-version 0.2` on each so no stray index defect appears. The cases expected for the shape above, with the diagnostic fragment each must produce, are the body of the script below; add or drop cases so that every rule in the final profile has exactly one. Two handle cases are the sanctioned exception to "one advisory": a missing handle and a wrong-prefix handle each trip both the field rule and the ID rule, as they do in every catalog profile, and the asserted fragment is the ID rule's (a duplicate handle reports once). The `bad-verified-actor` case writes `verified` in its list spelling so the diagnostic path is `verified[0].by`.

Write `scripts/test-verification-evidence-profile.sh` in the shape of `scripts/test-pattern-applications-profile.sh`. Fragments stop before the parenthesised description so rewording a description does not break the script.

```bash
#!/usr/bin/env bash

set -euo pipefail

okf_bin="${OKF_BIN:-okf}"
profile="profiles/assurance/verification-evidence.dhall"

"${okf_bin}" validate fixtures/verification-evidence \
  --strict \
  --profile "${profile}" \
  --profile-enforce \
  --log-enforce

# Each fixture must fail, and for its own reason. The expected diagnostic
# fragment guards against a fixture that fails for an unrelated defect (ADR-9).
while IFS='|' read -r fixture expected; do
  if output="$("${okf_bin}" validate "fixtures/verification-evidence-invalid/${fixture}" \
    --profile "${profile}" \
    --profile-enforce 2>&1)"; then
    echo "expected profile enforcement to reject ${fixture}" >&2
    exit 1
  fi
  if ! grep -qF -- "${expected}" <<<"${output}"; then
    echo "${fixture} failed without the expected diagnostic: ${expected}" >&2
    echo "${output}" >&2
    exit 1
  fi
done <<'FIXTURES'
missing-bundle-version|bundle does not declare okf_version
unknown-type|type not in profile vocabulary
missing-title|missing profile-required field: title
missing-description|missing profile-required field: description
missing-generated|missing profile-required field: generated
bad-actor|frontmatter value at generated.by must match format actor
bad-verified-actor|frontmatter value at verified[0].by must match format actor
computation-missing-id|Attested Computation requires a document ID with prefix VC
computation-wrong-prefix|document ID must look like VC-<number>
computation-duplicate-id|duplicate document ID VC-1
computation-outside-computations-tree|Attested Computation must match path pattern: computations/*
computation-missing-runtime|missing profile-required field: runtime
computation-untyped-parameter|missing profile-required field: parameters[0].type
computation-missing-executor|missing profile-required field: executor
computation-dangling-executor|executor.resource references
computation-missing-attester|missing profile-required field: attester
computation-dangling-attester|attester.resource references
computation-invalid-status|frontmatter value at status must be one of
computation-bad-stale-after|frontmatter value at stale_after must match format date
run-outside-runs-tree|Verification Run must match path pattern: runs/**
run-missing-run-id|missing profile-required field: runId
run-invalid-kind|frontmatter value at kind must be one of
run-invalid-outcome|frontmatter value at outcome must be one of
run-bad-started-at|frontmatter value at startedAt must match format rfc3339-utc
run-non-mori-subject|frontmatter value at subject must match format uri-with-scheme(mori)
run-invalid-subject-kind|frontmatter value at subjectKind must be one of
run-missing-component-revision|missing profile-required field: components[0].revision
run-non-mori-component-project|frontmatter value at components[0].project must match format uri-with-scheme(mori)
run-invalid-component-source|frontmatter value at components[0].source must be one of
run-duplicate-component-package|for components.package at element indices
run-duplicate-knob|for knobs.name at element indices
run-duplicate-dimension|for dimensions.name at element indices
run-non-boolean-harness-dirty|frontmatter value at harnessDirty must match format boolean
run-unresolved-computation|references VC-99, which does not exist in this bundle
run-data-missing-digest|missing profile-required field: data[0].digest
run-data-invalid-kind|frontmatter value at data[0].kind must be one of
run-data-relative-uri|frontmatter value at data[0].uri must match format uri
run-data-non-integer-bytes|frontmatter value at data[0].bytes must match format non-negative-integer
run-dangling-previous-run|previousRun references
run-non-mori-produced|frontmatter value at produced must match format uri-with-scheme(mori)
attestation-outside-attestations-tree|Attestation must match path pattern: attestations/**
attestation-dangling-run|run references
attestation-bad-attester-actor|frontmatter value at attester must match format actor
attestation-invalid-check|frontmatter value at checks must be one of
attestation-scalar-checks|frontmatter cardinality at checks must be list
attestation-invalid-verdict|frontmatter value at verdict must be one of
attestation-exception-authority-not-human|exception.authority must match format human-actor
FIXTURES

echo "OK: verification-evidence profile acceptance and rejection fixtures"
```

Finish the milestone with the two ADR-9 checks and the corpus gate (commands in Concrete Steps). The sweep is manual: for each rule, copy the profile aside, delete that one rule, run the script, confirm it fails naming the matching case, restore. A rule whose deletion leaves the script green either has no fixture (write one) or duplicates another rule (remove one of the two). Record the count of rules swept in Progress. The corpus gate validates this repository's committed `docs/verification/` against the working-tree export through a throwaway descriptor; any `profile:` line there is a defect in the lifted profile, never in the corpus.

### Milestone 2 — Generated documentation, the amended ADR and the release

Scope: the catalog's documentation, decisions and release chores, ending with a published tag. At the end `docs/profiles/verification-evidence/` exists and is current, README and CHANGELOG describe the export, ADR-6 is amended and a new ADR exists, a release commit and annotated tag are on `origin`, and the published package's semantic hash equals the local one. Tagging and pushing are outward-facing and irreversible in practice: the implementer prepares everything, then stops and obtains the owner's explicit confirmation.

Add `"assurance.verificationEvidence:verification-evidence"` to the `profiles=(…)` array in `scripts/test-profile-docs.sh`, after `"assurance.reviews:reviews"`, and run `just docs`. Only `docs/profiles/verification-evidence/` may appear in `git status`; a diff in any other generated directory means an unrelated profile changed and must be understood before continuing. Never hand-edit generated pages; to reword one, reword the rule's `description` and regenerate.

In `README.md` add `verification-evidence.dhall` with a two-line comment to the Layout tree under `assurance/`; add the row for `test-verification-evidence-profile.sh` to the script table (the rows for the specifications, terminology and user-documentation scripts are visibly mangled into one malformed row there today; repairing those three rows in the same edit is welcome and should be named in the commit body); add a Profile catalog row in the house style (purpose sentence naming the three types, `VC-N` handles, path-addressed runs and attestations, digest-pinned data links; `generated` required; "Also demands": nothing recommended, plus whatever is conditionally demanded); and extend the paragraph that begins "`assurance.reviews` is the one profile declaring neither a house `status` nor OKF's" so it says the two event types of `assurance.verificationEvidence` follow the same reasoning while its definition type takes OKF's `status` and `stale_after`. In `CHANGELOG.md` write the `[Unreleased]` entry: what the export is, that no existing profile, rule or export name changes and no governed corpus needs editing, that the package's semantic hash changes because the package gained an export, the fixture count, "Requested by" the MasterPlan URI, and a "Not included" note that an adoption blueprint waits for a second adopter.

Amend `docs/adr/0006-attested-computation-is-excluded.md`: keep `docId`, `status: Accepted`, `date` and the title; rewrite `description` to say the exclusion held until a consumer wrote the type and that `assurance.verificationEvidence` is the first admission; set `generated` to the implementer's actor and the current time; add `## Amendment — <date>` stating that the condition the record named has occurred (cite `mori://shinzui/keiro-runtime-kenshou/okf/verification` and the number of `Attested Computation` concepts in it), that the type is declared by that one profile and scoped by a `TypeRule` so no other profile gains a demand, that the rules were lifted from what the consumer was already writing rather than from section 10, and that the exclusion stands for every other profile. Then allocate the next handle (`okf id next docs/adr --profile docs/adr/profile.dhall ADR`, `ADR-15` on 2026-09-20) and write `docs/adr/00NN-a-verification-run-is-an-immutable-event-that-links-to-its-data.md` (the filename number is the handle number, zero-padded to four digits) with the frontmatter `type`, `title`, `description`, `docId`, `status: Accepted`, `date`, `generated`, and `originatingPlan: mori://shinzui/keiro-runtime-kenshou/plans/19-publish-the-verification-evidence-profile-in-okf-profiles`. Its sections are Context (ADR-10 made a review an event artifact; `mori://shinzui/okf/okf/adrs/concepts/ADR-14` says receipts and verdicts are runtime artifacts okf never stores, so recording runs is a house convention with new types, not a reading of section 10; the platform owner ruled that records never contain measurements), Decision (one profile, three types, one bundle; runs and attestations immutable and path-addressed, definitions handle-addressed; data as `{kind, uri, digest, mediaType, bytes}` links; attestation a separate concept, `verified` the one sanctioned append; no `status` or `stale_after` on events; baselines derived, never stored; runtime-specific vocabularies left open for a consumer overlay), Rationale, and Consequences (what okf cannot check and the consumer's local check must; Markdown under `references/` needs a declared type; relaxations are additive, renames are impossible once a corpus exists). Regenerate `docs/adr/index.md`, add an `Update` log entry for ADR-6 and an `Addition` entry for the new record, move the improvement request to `status: in-progress` with a refreshed `generated.at` and a log entry, run `just check`, and commit.

Prepare the release on the working tree without tagging. The version is the next minor after the newest tag at that moment (`v0.19.0` if `v0.18.0` is still newest; adding an export has been a minor bump every time). Compute the new package hash with `dhall hash --file package.dhall`. Replace the old tag and the old package hash in every file that names them — on 2026-09-20 that is exactly the thirty-two files `grep -rlE 'v?0\.18\.0' --exclude-dir=.git .` lists: `mori.dhall` (every `Schema.OkfProfile` `version`, every `Schema.SeihouTemplate` `version`, plus the new entry below placed after `reviews`), `package.dhall` and `profiles/okf-v0-2.dhall` (header comments: tag and hash), `seihou-registry.dhall` (every blueprint `version`), `README.md` (every import URL, the "To move a consumer repository onto" steps, whose third step names what the release adds), `CHANGELOG.md` (rename `[Unreleased]` to `[0.19.0] — <date>`, add the "Changed" bullets about blueprints and the hash, leave a fresh empty `[Unreleased]`), and every blueprint's `blueprint.dhall`, `README.md`, `prompt.md` and `files/*`. `blueprints/adopt-capabilities/files/capabilities-profile.dhall` pins a single profile file rather than the package; confirm `dhall hash --file profiles/coordination/capabilities.dhall` still equals the hash recorded there and change only the tag in its URL. Historical statements in CHANGELOG sections for earlier releases keep their old versions. Run `just check`, commit as `chore(release): release okf-profiles v0.19.0`, and stop for confirmation.

```dhall
, Schema.OkfProfile::{
  , name = "verification-evidence"
  , export = "assurance.verificationEvidence"
  , path = Some "profiles/assurance/verification-evidence.dhall"
  , version = Some "v0.19.0"
  }
```

After the owner confirms, create the annotated tag with the message form the repository uses (`okf-profiles v0.19.0: assurance.verificationEvidence`), push `master` and the tag, and verify publication: the remote tag peels to the release commit, and `dhall hash` of the remote `package.dhall` URL equals the local hash. Then complete the improvement request — `status: completed`, `completedAt`, a `resolution` naming the tag and hash (the request profile recommends `resolution` for a terminal status, so `--strict` demands it), each criterion's evidence in the body, a `Completion` log entry — validate, commit and push. okf's built-in default registry pins okf-profiles v0.14.0, so `okf profile list` without `--registry` will not show the new export until okf re-pins with its `scripts/refresh-default-registry.sh`; that is a follow-up for `mori://shinzui/okf`, not part of this plan, and it does not affect a consumer that imports by URL.

### Milestone 3 — Repointing the bundle at the published profile

Scope: this repository only. At the end `docs/verification/profile.dhall` is a pinned import of the release, `mori.dhall` binds the bundle to the published profile, every evidence gate passes, no recorded run or attestation has changed, and the ADR from EP-18 says where the contract now lives.

Replace the whole content of `docs/verification/profile.dhall`. If Milestone 1 lifted every vocabulary unchanged, the file is the import and one selection. If it opened any, the file also re-closes them with a profile-scope `optional` rule per opened key: okf merges profile-scope and type-scope rules by key, keeps the type's `required` presence, and uses the non-empty vocabulary, so the shared rule stays in force and the local one only narrows it (a vocabulary disjoint from a shared closed one is a profile-definition error, which is the safety net against drift). Write the import without a hash, put every explanatory comment in the file's `--|` header (formatting drops interior comments), and run `dhall freeze docs/verification/profile.dhall` to add the `sha256:`.

```dhall
--| Descriptor for the verification evidence bundle: the shared profile, published by
-- mori://shinzui/okf-profiles/profiles/verification-evidence, with the two vocabularies
-- that name parts of the keiro runtime narrowed again for this repository.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.19.0/package.dhall

let shared = Profiles.assurance.verificationEvidence

let closed =
      \(name : Text) ->
      \(values : List Text) ->
        Profiles.FieldRule::{
        , field = name
        , allowedValues = values
        , cardinality = Profiles.Cardinality.Scalar
        }

in    shared
    //  { frontmatter =
                shared.frontmatter
            //  { optional =
                      shared.frontmatter.optional
                    # [ closed "layer" [ "selftest", "pgmq", "kiroku", "shibuya", "kafka", "keiro", "runtime" ]
                      , closed "tier" [ "smoke", "standard", "extended", "soak" ]
                      ]
                }
        }
```

In `mori.dhall`, change the `verification` entry of `okfBundles` from the `Local` arm to the `Published` arm. `pin` is the same `sha256:` that `dhall freeze` wrote; `derived` is `True` exactly when the descriptor carries an overlay (the schema defines it as "the consumer transforms the imported value"); remove any legacy `profile = Some "…"` string on that entry only if EP-18 did not rely on it, since `profileBinding` wins when both are present. The schema revision this repository pins was checked to accept this value.

```dhall
, profileBinding = Some
    ( Schema.ProfileBinding.Published
        Schema.PinnedImport::{
        , publisher = "shinzui/okf-profiles"
        , publisherRef = Some Schema.MoriRef::{ namespace = "shinzui", name = "okf-profiles" }
        , export = Some "assurance.verificationEvidence"
        , version = Some "v0.19.0"
        , pin = Some "sha256:<the hash dhall freeze wrote>"
        , derived = True
        }
    )
```

Re-run every gate EP-18 defined, then prove two things beyond green. Immutability: `git status --short docs/verification` shows `profile.dhall` and nothing else (the root `index.md` lists `profile.dhall` under `# Files` by name, so it does not change). No loss of checking: copy the bundle to a scratch directory outside the repository, break one run there in a way only the overlay catches (`layer: database`) and another in a way only the shared profile catches (`outcome: green`), and confirm both are rejected. Finally update the ADR that EP-18 created (find it by title in `docs/adr/index.md`): add that the contract is published as `mori://shinzui/okf-profiles/profiles/verification-evidence` at the tag, that the local descriptor is a pinned import plus the narrowing overlay and why the overlay exists, and that a future change to the record shape must be a relaxation upstream first; refresh its `generated`, add an `Update` entry with `okf log add docs/adr`, and validate `docs/adr`. Refresh the local Mori registry for both repositories so the new profile URI resolves and the pin verdict is `current`, update the MasterPlan's three EP-19 Progress lines and the registry row's Status, and commit.


## Concrete Steps

Commits made in `/Users/shinzui/Keikaku/bokuno/okf-profiles` follow Conventional Commits, go directly onto `master` (no feature branch), and carry these trailers, plus a `Refs:` line once the request exists:

```text
Refs: mori://shinzui/okf-profiles/okf/improvement-requests/concepts/IR-7
MasterPlan: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
ExecPlan: mori://shinzui/keiro-runtime-kenshou/plans/19-publish-the-verification-evidence-profile-in-okf-profiles
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Commits made in this repository (every update to this plan file, and all of Milestone 3) carry:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/19-publish-the-verification-evidence-profile-in-okf-profiles.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Preconditions. Working directory `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, then `/Users/shinzui/Keikaku/bokuno/okf-profiles`.

```bash
okf --version && dhall --version            # okf v0.9.0.0 or later; dhall 1.42 or later
okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce
kenshou evidence check && git status --short docs/verification
cd /Users/shinzui/Keikaku/bokuno/okf-profiles
git status --short && git fetch origin && git status -sb | head -1     # expect: ## master...origin/master
git tag --sort=-v:refname | head -1                                    # newest tag; the release is the next minor
just check
```

File the request (Milestone 1), in `/Users/shinzui/Keikaku/bokuno/okf-profiles`.

```bash
okf id next docs/improvement-requests --profile docs/improvement-requests/profile.dhall IR     # IR-7
$EDITOR docs/improvement-requests/add-a-shared-verification-evidence-profile.md
okf index docs/improvement-requests --write
okf log add docs/improvement-requests --kind Addition \
  -m "IR-7: add a shared verification evidence profile (requested by the keiro-runtime-kenshou verification-suite master plan)."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git add docs/improvement-requests && git commit      # docs(improvement-requests): request a shared verification evidence profile
```

```text
OK: 7 concepts (okf_version 0.2)
```

Profile, fixtures, script (Milestone 1).

```bash
dhall type --file profiles/assurance/verification-evidence.dhall > /dev/null
okf profile show --registry ./package.dhall assurance.verificationEvidence --no-local | head -12
okf index fixtures/verification-evidence --write --okf-version 0.2
bash scripts/test-verification-evidence-profile.sh
```

```text
export: assurance.verificationEvidence
name: verification-evidence
…
guidance: (none)
okfVersion: 0.2
requireBundleVersion: 0.2
allowUnknownTypes: false
…
OK: 14 concepts (okf_version 0.2)                                      (count is illustrative)
OK: verification-evidence profile acceptance and rejection fixtures
```

ADR-9 check one — every case reports exactly one advisory (the missing-handle and wrong-prefix cases report the field rule and the ID rule, by design):

```bash
for d in fixtures/verification-evidence-invalid/*/; do
  echo "--- $(basename "$d")"
  okf validate "$d" --profile profiles/assurance/verification-evidence.dhall 2>&1 \
    | grep '^profile: ' | grep -v 'advisory deviation'
done
```

```text
--- run-data-invalid-kind
profile: runs/example/2026/09/<id>: frontmatter value at data[0].kind must be one of [run-spec, run-result, …], found: "screenshot"
--- run-duplicate-knob
profile: runs/example/2026/09/<id>: duplicate value "example.pool-size" for knobs.name at element indices [0, 1]
```

ADR-9 check two — sweep one rule at a time, then the corpus gate and the milestone commit:

```bash
bak="$(mktemp -d)/verification-evidence.dhall"                     # outside the repository
cp profiles/assurance/verification-evidence.dhall "$bak"
# delete ONE rule in the profile, then:
bash scripts/test-verification-evidence-profile.sh; echo "exit=$?"  # must be non-zero and name that rule's case
cp "$bak" profiles/assurance/verification-evidence.dhall            # restore; repeat for the next rule
git diff --stat profiles/                                           # after the last rule: only intended changes

probe="$(mktemp -d)/probe.dhall"
echo 'let P = /Users/shinzui/Keikaku/bokuno/okf-profiles/package.dhall in P.assurance.verificationEvidence' > "$probe"
okf validate /Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou/docs/verification \
  --strict --profile "$probe" --profile-enforce --log-enforce        # OK, with no profile: line
just check
git add profiles fixtures scripts && git commit                      # feat(assurance): add the verification-evidence profile
```

Documentation and decisions (Milestone 2).

```bash
$EDITOR scripts/test-profile-docs.sh          # add "assurance.verificationEvidence:verification-evidence"
just docs && git status --short docs/profiles # only docs/profiles/verification-evidence/ is new
okf id next docs/adr --profile docs/adr/profile.dhall ADR             # ADR-15
$EDITOR docs/adr/0006-attested-computation-is-excluded.md docs/adr/0015-a-verification-run-is-an-immutable-event-that-links-to-its-data.md
okf index docs/adr --write
okf log add docs/adr --kind Update   -m "ADR-6 is amended: assurance.verificationEvidence admits the Attested Computation type on an observed consumer corpus."
okf log add docs/adr --kind Addition -m "ADR-15 records why a verification run is an immutable event that links to its data and never contains it."
bash scripts/test-adr-bundle.sh && just check
git add -A && git commit                       # docs(assurance): document verification evidence and amend ADR-6
```

```text
OK: regenerated 17 profile documentation bundles in docs/profiles
OK: 15 concepts (okf_version 0.2)
OK: architecture decision bundle
```

Release preparation, then the gate (Milestone 2).

```bash
old=v0.18.0; new=v0.19.0                                   # new = next minor after the newest tag
dhall hash --file package.dhall                            # the hash every frozen descriptor must carry
grep -rlE "v?${old#v}" --exclude-dir=.git . | sort         # the files to edit; 32 on 2026-09-20
grep -rn '7d3a4a22be12fd0e697d6012ed1eb2efe4cb5dc4700d08fd49aa5e4c0e523df8' --exclude-dir=.git . | wc -l   # old hash sites
dhall hash --file profiles/coordination/capabilities.dhall # must still equal the hash in blueprints/adopt-capabilities/files/
just check && git add -A && git commit                     # chore(release): release okf-profiles v0.19.0
git status --short                                         # empty
```

STOP HERE. Report to the owner: the three commit hashes, `new`, the package hash, and the `just check` transcript. Proceed only on explicit confirmation.

```bash
git tag -a "$new" -m "okf-profiles $new: assurance.verificationEvidence"
git push origin master && git push origin "$new"
git ls-remote origin "refs/tags/$new^{}"                   # prints the release commit's hash
dhall hash <<< "https://raw.githubusercontent.com/shinzui/okf-profiles/$new/package.dhall"   # equals the local hash
# complete IR-7 (status, completedAt, resolution, body evidence), then:
okf log add docs/improvement-requests --kind Completion -m "IR-7 completed after $new publication and remote semantic-hash verification."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git add docs/improvement-requests && git commit && git push origin master    # docs(ir): complete IR-7
```

Repoint (Milestone 3), in `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`.

```bash
$EDITOR docs/verification/profile.dhall && dhall freeze docs/verification/profile.dhall
grep -A1 'okf-profiles/v' docs/verification/profile.dhall      # the tag line and the sha256: line dhall wrote
$EDITOR mori.dhall && dhall type --file mori.dhall > /dev/null && mori validate
okf validate docs/verification --strict --profile docs/verification/profile.dhall --profile-enforce --log-enforce
okf index docs/verification --write && git diff --exit-code docs/verification/index.md
kenshou evidence check && just verify
git status --short docs/verification                           # exactly: M docs/verification/profile.dhall

scratch="$(mktemp -d)" && cp -R docs/verification "$scratch/v"
run="$(find "$scratch/v/runs" -name '*.md' ! -name index.md ! -name log.md | head -1)"
sed -i.bak 's/^layer: .*/layer: database/' "$run"
okf validate "$scratch/v" --profile docs/verification/profile.dhall --profile-enforce; echo "exit=$?"   # exit=1, "at layer must be one of"
mv "$run.bak" "$run" && sed -i.bak 's/^outcome: .*/outcome: green/' "$run"
okf validate "$scratch/v" --profile docs/verification/profile.dhall --profile-enforce; echo "exit=$?"   # exit=1, "at outcome must be one of"
rm -rf "$scratch"

okf log add docs/adr --kind Update -m "<ADR handle>: the verification evidence contract is now published by okf-profiles and pinned here."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
( cd /Users/shinzui/Keikaku/bokuno/okf-profiles && mori register ) ; mori register
mori path mori://shinzui/okf-profiles/profiles/verification-evidence
mori registry pins --publisher shinzui/okf-profiles | grep keiro-runtime-kenshou     # verdict: current
git add docs/verification/profile.dhall mori.dhall docs/adr docs/masterplans docs/plans && git commit
# chore(verification): pin the published verification-evidence profile
```


## Validation and Acceptance

Milestone 1 is accepted when, in `/Users/shinzui/Keikaku/bokuno/okf-profiles`: `okf profile show --registry ./package.dhall assurance.verificationEvidence --no-local` prints the profile with `guidance: (none)`, `okfVersion: 0.2`, `requireBundleVersion: 0.2`, `allowUnknownTypes: false` and three (or four, if justified) type rules; `bash scripts/test-verification-evidence-profile.sh` prints the acceptance `OK:` line with `(okf_version 0.2)` and the final `OK:` line; the one-advisory loop shows one `profile:` line per case (two for the missing-handle and wrong-prefix cases, by design); deleting any single rule from the profile makes the script exit non-zero naming a case, and restoring it makes the script pass again — a before-and-after that proves each fixture tests its own rule; this repository's committed corpus validates against the working-tree export with no `profile:` line; `okf validate docs/improvement-requests --strict …` prints `OK: 7 concepts (okf_version 0.2)`; `just check` exits 0.

Milestone 2 is accepted when `bash scripts/test-profile-docs.sh` prints `OK: profile documentation is current and validates` with the new directory present; `docs/profiles/verification-evidence/types/` holds `attested-computation.md`, `verification-run.md` and `attestation.md`; `bash scripts/test-adr-bundle.sh` prints `OK: 15 concepts (okf_version 0.2)` and the amended ADR-6 and the new ADR are both listed in `docs/adr/index.md`; after the owner's confirmation, `git ls-remote origin 'refs/tags/<tag>^{}'` prints the release commit and `dhall hash` of the remote package URL prints exactly the hash in `package.dhall`'s header; the improvement request validates with `status: completed`.

Milestone 3 is accepted when, in this repository, the strict validate command prints `OK: <n> concepts (okf_version 0.2)` with the same `n` as before the change; `git status --short docs/verification` names only `profile.dhall`; `kenshou evidence check` and `just verify` exit 0; the two scratch mutations are each rejected with exit 1 and the quoted diagnostic; `grep -c 'raw.githubusercontent.com/shinzui/okf-profiles' docs/verification/profile.dhall` is 1 and the file contains no type rule of its own; and the `pin` in `mori.dhall`, the `sha256:` in `docs/verification/profile.dhall` and the hash in okf-profiles' `package.dhall` header at the tag are the same string.

The plan as a whole is accepted when a person who has never seen this repository can write a new bundle elsewhere, import the tag, select `assurance.verificationEvidence`, copy one run from `fixtures/verification-evidence/`, and get `OK:` from `okf validate --strict --profile-enforce`, then delete its `runId` and get `missing profile-required field: runId`.


## Idempotence and Recovery

Everything before the push is local and repeatable. `okf index … --write` and `just docs` are deterministic and clock-free, so re-running them produces no diff. `okf log add` is the exception: it appends a bullet every time and never deduplicates, so after a re-run open the `log.md` and delete the duplicate bullet. `okf id next` writes nothing; if another request or ADR landed in okf-profiles between drafting and implementing, use the number it prints and substitute it everywhere this plan says IR-7 or ADR-15. The rule sweep edits the profile in place: always restore from the backup copy and finish with `git diff --stat profiles/` showing no unintended change. Temporary descriptors and scratch bundles live outside both repositories and are removed at the end of the step that made them.

A half-finished Milestone 1 or 2 is recovered with ordinary git: uncommitted work with `git restore`/`git clean` on the named paths, committed but unpushed work by amending or by `git reset --soft` to the last good commit. If `just check` turns red in an unrelated script before any edit, stop and report rather than repairing the catalog under this plan's name. If the corpus gate reports a deviation, fix the profile (relax it), never the corpus.

The release is the one step that cannot be repeated or withdrawn cleanly, which is why it is owner-gated. Before tagging, confirm the tag does not exist locally or on `origin` (`git ls-remote origin refs/tags/<tag>`). If the push of `master` succeeds and the push of the tag fails, push the tag again; do not re-create it. If the remote hash differs from the local one after publication, do not move or delete the tag — consumers may already have frozen it; cut the next patch version with the correction and say so in the CHANGELOG. If the owner declines the release, Milestones 1 and 2 remain committed locally and Milestone 3 does not start; record the reason in the Decision Log.

Milestone 3 is a two-file change and is reverted with `git revert`, which restores the local descriptor and the `Local` binding. If `dhall freeze` cannot reach GitHub, the milestone waits; do not hand-write the hash and do not vendor a copy of the package into this repository. If the published profile unexpectedly rejects a committed record, revert, keep the local descriptor, and open the relaxation upstream as a patch release; never edit a run or attestation to fit.


## Interfaces and Dependencies

Tools, all already on the development machine: `okf` 0.9.0.0 or later (`mori://shinzui/okf`; the catalog's schema pin requires that decoder), `dhall` 1.42 or later (`type`, `hash`, `freeze`), `just`, `seihou` (needed only because `just check` runs `scripts/test-blueprints.sh`), `mori`, `git` with push rights to `github.com/shinzui/okf-profiles`, and from this repository the `kenshou` executable with the `evidence check` subcommand that `docs/plans/18-…` delivers. No Haskell code and no cabal dependency is added by this plan.

At the end of Milestone 1 the okf-profiles working tree provides the Dhall value `(./package.dhall).assurance.verificationEvidence`, of the record type `(./Profile/Type.dhall).Type`, with `name = "verification-evidence"`, `okfVersion = "0.2"`, `requireBundleVersion = Some "0.2"`, `allowUnknownTypes = False`, `guidance = None Text`, an `idField`, profile-scope `required = [type, title, description, generated]` and `optional = [verified]`, and type rules for `Attested Computation` (`pathPattern = Some "computations/*"`, `idPrefix = Some "VC"`), `Verification Run` (`pathPattern = Some "runs/**"`, no `idPrefix`) and `Attestation` (`pathPattern = Some "attestations/**"`, no `idPrefix`); the executable contract `bash scripts/test-verification-evidence-profile.sh` (exit 0, honours `OKF_BIN`); and the fixture trees named above. At the end of Milestone 2 the published interface is the import URL `https://raw.githubusercontent.com/shinzui/okf-profiles/<tag>/package.dhall` with its `sha256:`, the export path `assurance.verificationEvidence`, the Mori profile `mori://shinzui/okf-profiles/profiles/verification-evidence`, the generated reference at `docs/profiles/verification-evidence/`, and the compatibility promise stated in the CHANGELOG: later releases may open a vocabulary, widen one, or demote a presence class, and will not rename a key or a value. At the end of Milestone 3 this repository provides `docs/verification/profile.dhall` as a pinned import (with `derived = True` recorded in `mori.dhall` when it carries the narrowing overlay), and Integration Point 10's address form `mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/<path>` is unchanged.

Consumers of this plan's output: the gates from `docs/plans/18-…` (`okf validate docs/verification …` in `just verify` and CI) now load the published profile through the descriptor, so CI needs network access to GitHub or a warm Dhall cache; `kenshou record`, `kenshou attest` and `kenshou history` are unaffected because they write and read frontmatter, not the descriptor; the future stakeholder-reporting plan can rely on a published, documented field contract; Mori indexes `subject`, `components[].project`, `knownDefects` and `produced` as typed edges because the published profile declares them as `mori`-scheme URIs; and a second adopter, when one appears, is the trigger for the deferred adoption blueprint and for reconsidering which vocabularies stay open.
