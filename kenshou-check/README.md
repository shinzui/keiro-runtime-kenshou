# `kenshou-check`

`kenshou-check` is the correctness-evidence toolkit used by Kenshou scenarios.
It writes bounded append-only fact ledgers, evaluates invariants independently
of the runtime libraries, supervises real worker processes, injects failures,
and emits `kenshou.verdict/v1` documents.

## Evidence and verdicts

Each process incarnation gets its own rotating JSON Lines ledger under
`verdicts/ledger/`. Writers may choose buffered or durable recording; facts that
must survive a worker crash are flushed before the runtime operation is
acknowledged. Readers tolerate a torn final line, and checkers consume bounded
external sorts rather than loading an entire soak ledger into memory.

A verdict is `held`, `violated`, or `not-evaluated`. Contract violations block a
run; implementation-property findings remain evidence but do not block. Empty
input is `not-evaluated` unless a checker explicitly permits it.

## Checker catalogue

- `no-loss`: every acknowledged item is observed, and observations have an
  intent.
- `duplicates-within-windows`: duplicates occur only within declared fault or
  crash windows and their budgets.
- `per-key-order` and `global-order`: first observations remain monotonic.
- `gapless-positions`: an implementation check for contiguous positions.
- `exactly-n-effects`: every idempotency key has the configured effect count.
- `eventual-quiescence`: acknowledged work reaches a terminal fact by a
  deadline.
- `monotonic-checkpoints`: checkpoints do not regress without an explicit
  reset.
- `disjoint-ownership`: two owners do not act for the same lease concurrently.
- `linearizability`: completed histories admit a legal sequential execution;
  bounded-search exhaustion is inconclusive.

The SQL oracle catalogue reconciles ledger evidence with durable Kiroku, Keiro,
and PGMQ tables without linking those runtime libraries.

## Failure controls

`Kenshou.Check.Process` uses operating-system process groups and signals,
including `SIGKILL`, and records crash windows. `Kenshou.Check.Fault` schedules
PostgreSQL backend termination, locks and server restarts; TCP latency, throttle,
stall, blackhole, reset and refusal; dropped wake-ups; and cell-provided hooks.
Every injected fault reports whether it is available in the current placement.

## Clock regimes

There are three deliberately separate clock regimes:

1. Caller-supplied time uses `newVirtualNow`; tests can advance it instantly.
2. Database-clock state uses `backdateRows` on the timestamp that PostgreSQL
   evaluates.
3. Code that calls the host clock internally uses short real timeouts.

Fact timestamps also carry clock-source and skew metadata. Cross-host
disturbance comparisons must use the measured skew bound supplied by the cell;
same-host runs use a conservative local bound.

## Self-tests

The `selftest/check` scenarios exercise ledger non-vacuity, real worker
kill/restart, PostgreSQL backend termination, the TCP proxy, replayable Hedgehog
counter-examples, and the linearizability checker. They are registered in the
normal scenario catalogue and can be run with `kenshou run <scenario>`.
