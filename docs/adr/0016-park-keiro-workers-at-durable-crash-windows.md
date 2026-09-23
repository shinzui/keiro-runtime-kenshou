---
type: Architecture Decision Record
title: Park keiro workers at durable crash windows
description: Keiro crash scenarios park a worker inside append, acknowledgement, or projection hooks before externally terminating the process or backend.
timestamp: 2026-09-23T19:55:00Z
generated:
  by: process:codex
  at: "2026-09-23T19:55:00Z"
docId: ADR-16
status: Accepted
date: 2026-09-23
originatingPlan: docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md
---

# Park keiro workers at durable crash windows

## Context

The write side has several durable boundaries: a process manager's own append,
each target command append, and the source acknowledgement. A thrown exception
can run cleanup and cannot establish what survived an abrupt termination.
[ADR-9](0009-define-crashes-as-process-or-backend-termination.md) requires
real process or backend termination for crash evidence.

## Decision

The harness arms one boundary at a time and parks the worker at that point.
`RunCommandOptions.beforeAppend` marks the manager or target append window;
an interposed acknowledgement handle marks the post-target,
pre-acknowledgement window; and a PostgreSQL sleep in an inline projection
marks an open transaction before commit. After the worker reports that it is
parked, the harness sends `SIGKILL` or terminates its PostgreSQL backend,
then starts a replacement and checks the durable log.

The selected source event and target streams are isolated from unrelated
writers so append-hook counts identify the intended window. Every crash
scenario uses PostgreSQL with durable settings.

## Consequences

- Reports can identify the exact durable boundary that was interrupted.
- A restart must finish missing effects using deterministic identifiers.
- Hooks are coordination points only; verdicts come from SQL oracles after
  recovery, not from a worker's in-memory report.
