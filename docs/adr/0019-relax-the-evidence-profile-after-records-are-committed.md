---
type: Architecture Decision Record
title: Relax the evidence profile after records are committed
description: Once an evidence record is committed, its type and field names stay stable and later profile revisions may only relax validation.
timestamp: 2026-09-26T19:56:01Z
generated:
  by: process:codex
  at: "2026-09-26T19:56:01Z"
docId: ADR-19
status: Accepted
date: 2026-09-26
originatingPlan: docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md
---

# Relax the evidence profile after records are committed

## Context

Verification runs and attestations are historical events. Changing the name or
meaning of a required field after records have been committed would either make
old evidence fail validation or silently reinterpret it. The local profile is
intended to become a published shared profile after a real corpus exists.

## Decision

The first committed run freezes the three concept type names and all field names
in `docs/verification/profile.dhall`. Later revisions can add optional fields,
accept additional values, or otherwise relax a rule. They cannot rename or remove
a field, narrow a vocabulary, or tighten a constraint that accepted committed
records. A computation that can change an answer takes a new `VC-N` handle and
supersedes its predecessor; the old definition remains available.

The repository validates the whole historical corpus before publishing a profile
change. Rules that OKF's descriptor cannot express, including digest syntax,
record immutability, event-only keys, and cross-field identity, belong to
`kenshou evidence check` and must likewise preserve the interpretation of older
records.

## Consequences

- The profile can move to `mori://shinzui/okf-profiles` without rewriting runs.
- A breaking evidence format needs an explicit new schema or bundle protocol
  rather than an in-place profile change.
- Historical validation cost grows with the corpus, so the index and check gates
  must be measured as records accumulate.
- A temporary corpus with 2,000 synthetic run records and 17 existing concepts
  passed strict validation in 6.740 seconds; index generation took 7.732 seconds.
  Validation stayed below the ten-second threshold for considering a year split.
- The local checker currently supplies constraints absent from the descriptor:
  decimal and fixed-length lowercase hexadecimal field formats, the ability to
  forbid core `status` on event types, and concept-typed path references. Profile
  publication may relax this division of work when OKF gains those rules, while
  preserving the meaning of committed records.
