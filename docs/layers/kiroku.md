# Kiroku layer

The `kiroku` layer checks the PostgreSQL event store in an isolated, migrated database. Run a scenario from the repository root inside `nix develop`:

```bash
cabal run -v0 kenshou -- list --layer kiroku
cabal run -v0 kenshou -- run kiroku/append/correctness/expected-version-matrix --out runs/
```

The implemented scenarios are listed below. Every check currently uses the `smoke` tier and `either` placement. They support PostgreSQL 17 and 18, and both `fsync-off` and `durable` PostgreSQL modes. Each writes a separate `kenshou.verdict/v1` verdict for every assertion into the run's `verdicts/` directory. The verdict marks a documented guarantee as `contract` and an incidental behavior as `implementation`.

| Scenario | Contract checked |
| --- | --- |
| `kiroku/append/correctness/expected-version-matrix` | Append preconditions on missing, live and soft-deleted streams, plus invalid names and empty batches. |
| `kiroku/append/correctness/idempotent-event-ids` | Caller event IDs reject retry, cross-stream and larger-batch duplicates without changing versions or the global log. The optional parsed ID in `DuplicateEvent` may be absent. |
| `kiroku/append/correctness/multi-stream-atomicity` | Multi-stream appends commit all operations or none when a precondition, reserved stream name or empty batch fails. |
| `kiroku/read/correctness/cursor-semantics` | Paged global, stream, category and Streamly reads preserve order and exact membership; source stream names resolve from surrogate IDs. |
| `kiroku/lifecycle/correctness/delete-and-truncate` | Soft delete, restoration, truncation, reserved stream protection, hard delete and the hard-delete event handler signal. The planned live-subscriber continuity check remains to be added. |
| `kiroku/transaction/correctness/append-with-continuation` | Caller SQL and an event append commit together; a condemned transaction rolls both back; a rejected version skips the continuation. The planned enrich-hook comparison remains to be added. |

All six accept `kiroku.pool-size` (1 to 64, default 10), `kiroku.statement-timeout-seconds` (0 to 600, default 0, where zero disables the timeout), `kiroku.idle-in-transaction-timeout-seconds` (1 to 3600, default 30), and `kiroku.conn.keepalives` (boolean, default false). The read scenario also accepts `kiroku.read.page-size` (1 to 1000, default 256; declared variants 1, 7, 256, 1000). Tracing and metrics arms are currently restricted to `off` while the store fixture is being built.

The change-aware planner should map `kiroku/append/**` and the other store components to `kiroku-store` and `kiroku-store-migrations`, `kiroku/metrics/**` to `kiroku-metrics`, and `kiroku/otel/**` to `kiroku-otel`. The latter components will appear as their scenarios are implemented.
