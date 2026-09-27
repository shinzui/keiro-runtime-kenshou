---
type: Term
title: attestation
description: A separate verification record reporting whether an evidence claim is confirmed, refuted, or incomplete.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-28
status: current
tags: [evidence]
related: [TERM-21, TERM-27]
anchors:
  - {kind: file, resource: kenshou-evidence/src/Kenshou/Evidence/Attest.hs}
  - {kind: doc, resource: docs/guides/recording-evidence.md}
---

# attestation

`kenshou attest` fetches linked bytes, verifies digests, and recomputes
available claims under their saved definitions. It writes an attestation with
named checks and a `confirmed`, `refuted`, or `incomplete` result. Only a
confirmed machine attestation adds a machine `verified` entry to the target
[evidence record](evidence-record.md); a human sign-off is separate. See
[recording evidence](../guides/recording-evidence.md).
