# Inbox handler counter counts an unused sequence

Status: fixed and verified by the expanded durable regression matrix.
Owner: this repository's inbox verification scenarios. No upstream runtime
defect or owner bug report is assigned.

The poison and batch scenarios counted handler invocations with
`SELECT last_value FROM kenshou_fx.poison_calls`. A newly created sequence
already exposes its start value, one, before any `nextval` call. The SQL-error
oracle therefore could not distinguish zero handler invocations from one.
In particular, its call-count check alone could accept an error before handler
entry. This is a verification gap, not evidence that Keiro skipped a handler
in a previously recorded run.

An initial-zero check added before delivery reproduced the problem in all five
table-backed controls: pure-exception, condemned and SQL-error poison intake,
plus pure-exception and condemned batch intake. Each failed only
`handler-count-starts-at-zero`; both delegated controls passed. The seven-arm
before matrix is under `runs/ep13-poison-effects/before/`, with exact run IDs
and expected outcomes in `summary.json`.

The query now returns zero while `is_called` is false, otherwise `last_value`.
These fixtures use a fresh default sequence, increment it once per handler
entry and never reset it. Sequence increments survive transaction rollback,
so the counter can distinguish an attempted handler from committed effects.
The initial-zero guard remains in both scenario families at revision 2.

Poison recovery also now inserts an actual effect before throwing and checks
that failed attempts leave no effects. Three permanently failing invocations
must reach the ceiling without a fourth handler call. Two recovery failures
must roll back, the succeeding third attempt must leave exactly one recovery
effect, and redelivery must add neither an invocation nor an effect. SQL-error
and condemned handlers likewise insert before failing so their rollback
checks exercise writes. Delegated behavior remains unchanged.

Reproduce a fixed SQL-error arm from the repository root:

```bash
nix develop -c cabal run -v0 kenshou -- run \
  keiro/inbox/correctness/poison-accounting \
  --dim pg.durability=durable \
  --set inbox.failure-mode=sql-error --out runs/
```

Historical sealed runs are not rewritten or promoted to stronger coverage.
The new observations do not add independent poison/batch VC-1 replay.

Validation: all seven repaired arms pass under
`runs/ep13-poison-effects/after/`. Each before/after matrix passes 55 schema
and 62 artifact checks. The full `nix develop -c just verify` gate passes,
including 50 Keiro and 52 CLI examples and the 169-concept evidence bundle.
