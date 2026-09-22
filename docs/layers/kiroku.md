# Kiroku layer

The `kiroku` layer checks the PostgreSQL event store in an isolated, migrated database. Run a scenario from the repository root inside `nix develop`:

```bash
cabal run -v0 kenshou -- list --layer kiroku
cabal run -v0 kenshou -- run kiroku/append/correctness/expected-version-matrix --out runs/
```

The implemented scenarios are listed below. The global-order and cursor scenarios use the `standard` tier; the rest use `smoke`. They all have `either` placement and support PostgreSQL 17 and 18, and both `fsync-off` and `durable` PostgreSQL modes. Each writes a separate `kenshou.verdict/v1` verdict for every assertion into the run's `verdicts/` directory. The verdict marks a documented guarantee as `contract` and an incidental behavior as `implementation`.

| Scenario | Contract checked |
| --- | --- |
| `kiroku/append/correctness/expected-version-matrix` | Append preconditions on missing, live and soft-deleted streams, plus invalid names and empty batches. |
| `kiroku/append/correctness/idempotent-event-ids` | Caller event IDs reject retry, cross-stream and larger-batch duplicates without changing versions or the global log. The optional parsed ID in `DuplicateEvent` may be absent. |
| `kiroku/append/correctness/multi-stream-atomicity` | Multi-stream appends commit all operations or none when a precondition, reserved stream name or empty batch fails. |
| `kiroku/append/correctness/all-order-and-gaps` | A 5,000-event, 50-stream workload preserves append and read order; five hard deletes create exactly the reported gaps. Mixed `appendMultiStream` writes, native table counts and inventory-head comparison remain to be added. |
| `kiroku/read/correctness/cursor-semantics` | Paged global, stream, category and Streamly reads preserve order and exact membership; source stream names resolve from surrogate IDs. |
| `kiroku/lifecycle/correctness/delete-and-truncate` | Soft delete, restoration, truncation, reserved stream protection, hard delete, its event handler signal and a live `$all` subscriber that stays ordered throughout. |
| `kiroku/transaction/correctness/append-with-continuation` | Caller SQL and an event append commit together; a condemned transaction rolls both back; a rejected version skips the continuation. The planned enrich-hook comparison remains to be added. |
| `kiroku/subscription/correctness/checkpoint-policies` | Missing checkpoints refuse startup or initialize at zero or the current head; existing rows win; explicit reset reports missing names and causes redelivery. |

All eight accept `kiroku.pool-size` (1 to 64, default 10), `kiroku.statement-timeout-seconds` (0 to 600, default 0, where zero disables the timeout), `kiroku.idle-in-transaction-timeout-seconds` (1 to 3600, default 30), and `kiroku.conn.keepalives` (boolean, default false). The read scenario also accepts `kiroku.read.page-size` (1 to 1000, default 256; declared variants 1, 7, 256, 1000). The global-order scenario accepts `workload.events` (100 to 100,000, default 5,000) and `kiroku.append.streams` (5 to 1,000, default 50). Tracing and metrics arms are currently restricted to `off` while the store fixture is being built.

The change-aware planner should map `kiroku/append/**` and the other store components to `kiroku-store` and `kiroku-store-migrations`, `kiroku/metrics/**` to `kiroku-metrics`, and `kiroku/otel/**` to `kiroku-otel`. The latter components will appear as their scenarios are implemented.
