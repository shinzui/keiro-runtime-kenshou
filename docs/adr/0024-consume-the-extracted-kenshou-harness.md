---
type: Architecture Decision Record
title: Consume the extracted Kenshou harness
description: Keep runtime verification and executable assembly here while consuming the generic harness from its own immutable upstream source.
generated:
  by: process:codex
  at: "2026-11-17T16:22:25Z"
docId: ADR-24
status: Accepted
date: 2026-11-17
---

# Consume the extracted Kenshou harness

## Context

The reusable kernel, toolkits and operator commands were extracted into
mori://shinzui/kenshou. Maintaining their original copies here would create two
owners for the same APIs and verification behavior. Upstream has Hackage
candidates but no published release or remote release tag at adoption time.

## Decision

Consume the eight generic packages at an immutable upstream HTTPS commit in
`cohort/kenshou.project`. Nix selects the same source revision with a fixed hash.
Move to published package pins once that release exists. Runtime cohort versions
remain independently selected by their existing descriptors.

`kenshou-suite` owns the `kenshou` executable, runtime component graph,
performance contracts, bundle assembly and runtime outcome attestation routing.
Layer packages own their oracle queries and replay implementations. The
`kenshou-support` package carries shared runtime migration names and components;
its optional Keiro schema flag preserves the isolated Shibuya lane without
introducing dependencies between layer packages. The extracted kernel receives
these facts through its public bundle and program APIs.

Named Kafka registration must retain the legacy cell broker wipe and the
scenario-owned local broker lifecycle. Cell preparation is covered by a consumer
integration test so this isolation contract survives harness API changes.

Layer strings, migration names, scenario revisions and recomputer names remain
stable. Preserve existing evidence records and test fixtures. Dependency source
changes are recorded honestly in resolved identities, even when scenario
semantics stay the same. Evidence history targets this repository's verification
bundle through `KENSHOU_EVIDENCE_BUNDLE_URI`.

## Consequences

Generic harness fixes belong upstream. This repository can add runtime coverage
without forking the command library or kernel. The isolated and assembled lanes
must both build after API changes. Active validation recipes exercise the
consumer and its preserved compatibility fixtures; upstream owns generic toolkit
unit tests.
