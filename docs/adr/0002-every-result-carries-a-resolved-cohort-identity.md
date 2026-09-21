---
type: Architecture Decision Record
title: Every result carries a resolved cohort identity
description: Verification results identify the complete runtime cohort actually selected by Cabal, including immutable sources and a deterministic plan hash, rather than recording only intended pins.
timestamp: 2026-09-20T00:05:00Z
generated:
  by: human:nadeem
  at: "2026-09-20T00:05:00Z"
docId: ADR-2
status: Accepted
date: 2026-09-20
---

# Every result carries a resolved cohort identity

## Context

Kenshou compares behavior across a family of independently released runtime
packages. A version label such as "keiro 0.17" is insufficient evidence: the
result also depends on every substrate and adapter version, the Hackage index
state, any git source, solver flags, and narrowly lifted bounds.

Intended pins are not proof of what Cabal selected. Cabal also caches imported
project files without noticing a direct edit to `cohort/active.project`; during
bootstrap, changing that file by hand left the previous plan in place. A result
that copied the intended descriptor could therefore claim one cohort while the
executable actually linked another.

The released-first policy follows
`mori://shinzui/jinmyaku/okf/adrs/concepts/ADR-1`. Exception evidence follows
`mori://shinzui/rei/okf/adrs/concepts/ADR-16`, and exact index-state adoption
follows `mori://shinzui/rei/okf/adrs/concepts/ADR-18`.

## Decision

A cohort is an explicit, complete, named pin set. `released` selects Hackage
packages at an exact reachable `index-state`; `head` replaces selected components
with HTTPS git sources at immutable commit hashes. Both are first-class cohorts
and each is self-contained. Git branches, `file://` locations, and local-path
runtime sources are forbidden.

Each cohort has two coordinated inputs:

- `cohort/<name>.project` is the Cabal solver input. Every Hackage-backed member
  is both exactly constrained and listed in `extra-packages`, so it appears in
  the solver plan even before a scenario imports it.
- `cohort/<name>.json` is the machine-readable descriptor. It groups packages by
  component and maps every component to its canonical `mori://` project URI.

`cohort/active.project` contains exactly one cohort import. It is changed only
through `just use-cohort <name>`, which also deletes Cabal's cached project
configuration and plan. A direct edit is not an accepted switch procedure.

Every verification result embeds the `CohortIdentity` derived from Cabal's
resolved `plan.json`, not a copy of the intended descriptor. The identity records
compiler and Cabal versions, platform, index state, descriptor digest, resolved
package versions and sources, and a deterministic plan hash. Local repository
units and absolute paths are excluded from the hash. `kenshou cohort check`
rejects missing packages, version or source drift, and runtime packages resolved
from local paths.

A package-qualified `allow-newer` is permitted only when its adjacent evidence
names the bound, explains why the incompatible surface does not reach this
consumer, identifies a test that exercises the used surface (including live
migrations when applicable), and states the removal condition. Blanket
`allow-newer` entries are forbidden.

The operator CLI also adopts the Git-aware release identity from
`mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`. `kenshou --version`
prints the Cabal package version and a seven-character source revision; local
Cabal builds read Git metadata, Nix injects the clean flake revision, and a dirty
Nix source reports `dirty` instead of reusing a stale clean revision. This binary
identity accompanies, but never substitutes for, the full resolved cohort
identity.

## Consequences

- Results remain attributable and comparable after package indexes, branches,
  or local checkouts move.
- Operators can distinguish the harness revision from the runtime cohort it
  verified; both identities are required to reproduce a result.
- Reproducing a result starts with its embedded identity rather than reconstructing
  dependency intent from repository history.
- Adding a runtime package requires updating both cohort project files and both
  descriptors, then regenerating the plan and running `kenshou cohort check`.
- Cohort switching is deliberately a recipe, not a text edit, because cache
  invalidation is part of correctness.
- The descriptor and project file duplicate package information; the consistency
  check makes that duplication explicit and fail-fast.
- Plan hashes may differ across platforms when platform-conditional dependencies
  differ. Consumers compare resolved components as the semantic cohort and treat
  the plan hash as supporting evidence.
