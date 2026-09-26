---
type: Architecture Decision Record
title: Keep verification records immutable and derive baselines
description: Verification records are immutable events that link to digest-pinned data, while baselines are selected from confirmed compatible history.
timestamp: 2026-09-26T19:56:01Z
generated:
  by: process:codex
  at: "2026-09-26T19:56:01Z"
docId: ADR-18
status: Accepted
date: 2026-09-26
originatingPlan: docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md
---

# Keep verification records immutable and derive baselines

## Context

A run can produce many samples and logs. A future reader needs its exact cohort,
environment, outcome, and raw files without treating a mutable report as proof.
Measurements are too large and too easy to copy incorrectly into OKF frontmatter.
A chosen baseline can also become stale when a newer confirmed compatible run
arrives.

## Decision

The `docs/verification` bundle holds three concept types: `Attested Computation`,
`Verification Run`, and `Attestation`. One run or comparison gets one path-addressed
record with a UUIDv7 identity. The record stores identity, provenance, outcome,
cohort, and a separate durable `gs://` link with SHA-256, media type, and byte count
for every required data artifact. It stores no measurement value. Data objects and
committed records are not replaced. A correction is a new record or a subsequent
attestation that refutes the original.

Attestations are separate events. A deterministic verifier checks linked bytes
and named computation definitions; only a confirmed result can add a machine
`verified` entry. Historical queries derive a baseline from the latest confirmed,
compatible evidence at read time. No record stores a `baseline` flag or a derived
trust tier.

## Consequences

- A reader can re-evaluate an old conclusion from digest-pinned data without
  changing what the original run claimed.
- A new confirmed run can become the baseline without rewriting prior records.
- The recorder and attester must refuse identity collisions and report incomplete
  recomputation honestly when an oracle cannot be replayed from saved artifacts.
- Storage retention and the repository's history are part of the evidence chain.
