---
type: Architecture Decision Record
title: Pin cell payloads to verified cohort identities
description: A cell payload pins runtime packages from the cohort descriptor and is accepted only after its resolved Nix identity passes the cohort check.
timestamp: 2026-09-29T00:06:41Z
generated:
  by: process:codex
  at: "2026-09-29T00:06:41Z"
docId: ADR-20
status: Accepted
date: 2026-09-29
originatingPlan: docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md
---

# Pin cell payloads to verified cohort identities

## Context

A cell runs a Linux Nix closure, while local development can use Cabal's
solver. The shared `mori://shinzui/haskell-nix` channel supplies compatibility
patches but can pin older first-party packages and strip their Cabal bounds.
A successful Nix build therefore does not prove which runtime cohort was
linked. A cell must also be able to carry released, head, and older baseline
cohorts at the same time.

The service-repository pinning rule in
`mori://shinzui/mori/okf/adrs/concepts/ADR-24` and
`mori://shinzui/rei/okf/adrs/concepts/ADR-18` protects applications from
silently replacing a shared first-party package set. Kenshou's runtime cohort
is itself the subject of verification, so it needs an explicit local pin set
and an identity check.

## Decision

The payload's Nix overlay pins every runtime cohort package from
`cohort/<name>.json` and its generated source-hash lock. It is composed after
the shared channel, which supplies third-party compatibility fixes. Each
payload variant and cohort has its own closure; publishing it records the
closure identity and the SHA-256 of its immutable export bundle.

The Nix build generates `kenshou.cohort-identity/v1` from resolved package
versions and sources. Its plan hash covers the cohort lock, compiler, nixpkgs,
and haskell-nix revisions, and its resolver is `nix`. Before publication or
execution as verified evidence, `kenshou cohort check` compares that identity
with the descriptor. The Cabal lane checks its resolved plan against the same
descriptor. Equality of the resolved cohort components, rather than equality
of platform-specific plan hashes, establishes that the two lanes verify the
same cohort.

This extends [ADR-2](0002-every-result-carries-a-resolved-cohort-identity.md).
The payload's harness revision and dirty flag remain separate from runtime
cohort identity.

## Consequences

- A green Nix build alone cannot authorize a cell payload as cohort evidence.
- Released, head, and baseline cohorts can be built side by side without the
  channel selecting one first-party version for all of them.
- Every lock refresh must be followed by the identity check; stale or drifting
  package sources fail before a payload is published.
- Consumers compare resolved components for semantic cohort equality and keep
  the Nix or Cabal plan hash as supporting provenance.
