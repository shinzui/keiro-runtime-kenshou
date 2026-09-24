# Keiro write-side verification

The `keiro` layer runs against a harness-provisioned PostgreSQL 18 database
with the kiroku and keiro schemas migrated together. It uses a bank-ledger
fixture: account commands emit account events, and a pure model plus direct
SQL queries check what persisted. The fixture is owned by
`kenshou-keiro/src/Kenshou/Suite/Keiro/Fixture/`.

Run the first scenario from the repository root inside `nix develop`:

```bash
cabal run kenshou -- run keiro/command/correctness/fixture-roundtrip --out runs
```

The scenario opens 100 accounts, submits 500 seeded deposits, withdrawals,
transfer legs, and bonus declarations through the command runners, and reads
both event logs and the inline
balance table using a separate Hasql connection. It emits four contract
verdicts: `log-is-well-formed`, `model-equals-log`,
`inline-read-model-equals-log`, and `money-is-conserved`, plus a bonus log
verdict. The conservation check includes debited transfer value still in flight. The
`workload.operations` knob defaults to 500.

The fixture also defines a bonus event stream and a transfer process manager
with deterministic target commands. Their scenario coverage is being added
under the repository-local `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md` plan.

The registered command scenarios also cover duplicate event identifiers,
optimistic retry and exhaustion, controlled SQL rollback, and hydration over
stream lengths and page sizes. `keiro/snapshot/correctness/policy-matrix`
checks the persisted snapshot version and register values for all five
policies. Two concurrency scenarios check simultaneous submission of one
identifier and sustained writes to one hot stream. The scenario IDs and
their knobs are available through `cabal run kenshou -- list --layer keiro`.
The writer crash scenario runs paced deposit sequences in separate processes,
kills writers at configured intervals, and restarts each from an overlap with
its last acknowledged operation. Deterministic IDs make the overlap safe. It
checks that restarted writers report duplicates and that SQL has exactly one
event for every submitted operation ID. The default three-process run passed
with 1,200 operations per writer, twelve kills, and six durable checks.
The model based parallel scenario generates concurrent account commands over
three streams and checks their observed versions against the reference model.
`identical-commands-one-batch` accepts `command.processes=4` to run real
writer processes; it checks that one reports an append, the others report
duplicates, and SQL contains one event. The snapshot seed divergence scenario
corrupts a persisted balance and runs the writer with
`snapshot.seed-verify-sample-rate=1` or `0`. The sampled run must log the
divergence while accepting the command; the unsampled run must omit the marker.
An instrumented follow-up command checks that
`keiro.snapshot.seed.divergence` increments once with collection enabled and
sampling on, and remains zero with sampling off or metrics off.

The process manager scenarios check stable manager and target identities under
redelivery, timer persistence, and both orders of transfer inputs. The reactive
manager scenario checks insert-only timeout scheduling, reminder rearming,
cancellation, and duplicate delivery. The `reaction-no-advance-receipt` run
reproduces the documented missing durable receipt for a `NoAdvance` input;
the harness reports it as a nonblocking known defect tied to
`mori://shinzui/keiro/okf/adrs/concepts/ADR-41`. The process-manager
`policy-matrix` run checks all nine poison and rejected-command policy
combinations, including acknowledgement decisions and durable dead letters.
It checks nine `keiro.dispatch.poison` counter increments with metrics
collected and zero exports with metrics off.
The `transient-classification` scenario checks conflicting credits, backend
termination during a credit projection, malformed destination history, and a
mixed rejected/transient dispatch group. It expects retry for transient groups
and halt for deterministic hydration failure. A direct credit also witnesses
the two-attempt `RetryExhausted` result.
The `sigkill-crash-windows` scenario runs a separate process-manager worker,
parks it at one of four append or acknowledgement boundaries, kills it, and
checks the durable saga and target effects for that transfer and its neighbour
after a fresh worker resumes the same subscription. Select a boundary with
`--set pm.kill-window=between-targets`.
`random-kill-exactly-once` paces debit and announcement commands while
restarting the real saga worker at a configured interval. An optional arm
terminates one of its PostgreSQL backends before alternating restarts. A
30-second local run submitted 300 transfers, restarted the worker nine times,
terminated four backends, and passed its durable effect and dead-letter checks.
A default run completed 6,000 transfers with 60 restarts and 30 confirmed
backend terminations, passing all six durable checks. It took about 249 seconds
on this host, so the scenario now reports effective rate and marks runs that
miss their paced schedule as inconclusive for rate validation.
`retry-budget-dead-letter` keeps one credit in conflict while a healthy transfer
follows it. The production adapter dead-letters after five deliveries;
`--set pm.source=ack-stream --set kiroku.retry-max-attempts=3` tests a
configurable budget. Both bridges advance to the healthy transfer, and replay
of the dead letter appends the missing credit once. The scenario also reads the
durable subscription checkpoint beyond both source transfers and checks that
Kiroku's terminal dead-letter event increments
`keiro.subscription.deadlettered` once when metrics are collected.
`topologies` runs two process manager roles against one subscription as
duplicate subscribers, consumer-group members, or lease-owned shard workers.
Ten transfers use both input
orders; each saga has one debit and one announcement observation, and each
transfer has one credit and confirmation. The run reports the share of sagas
whose announcement arrived first.
The router's `sigkill-mid-fanout` scenario checks a partial durable fanout
before killing the worker and exact recovery after restart. The router
correctness scenarios check fanout under redelivery and selection drift, independent
target commits with a durable dead letter, and the declarative selection
policy matrix. A reordered redelivery probe checks that dead-letter rows still
identify their rejected targets. The asynchronous projection scenario checks deduplication,
rebuild fencing, and the documented effect of pruning deduplication rows. A
projection worker crash after apply checks that redelivery is deduplicated;
the `skip-dedup` arm fails. `projection.batch-size` and `projection.events`
let the run keep more events pending across the crash; batch sizes 1 and 10
both replayed one duplicate within the batch bound. The stronger
apply/checkpoint atomicity run
reproduces the known defect at
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10`.
The inline projection scenario interrupts an open command transaction with
SIGKILL, backend termination, or a projection SQL error, then checks the
account log and balance table together.

The command `throughput-latency` benchmark uses the measurement toolkit's
warm-up, steady, and drain phases and verifies the durable ledger after the
drain. It writes raw samples and time series. `command.writers` selects the
load workers, `command.accounts` selects the account streams, and
`command.duration-seconds` sets the steady window. Pool size, snapshot policy,
memo length, replay verification, and the plain, SQL callback, and inline
projection command paths are selectable. The inline path checks its balance
table against the log. Paced 15-second local runs passed all three command
paths with two writers and sixteen accounts. An unpaced run completed 10,811
commands with all durable checks passing but hit the local driver CPU gate;
paired trials on the target cell are still required for comparisons.
`hydration-cost` prepares a selected stream length with `snapshot.policy=never`
or `every-100` and a selected `command.page-size`. Its timed close command
is rejected after hydration, keeping the stream length fixed across samples.
History setup appends batches directly and uses commands at each snapshot
boundary, so the snapshot arm starts with the expected saved state. The final
ledger and snapshot checks confirm the prepared history and that measurement
added no events. Both policy arms passed local 15-second runs at length 100;
the snapshot arm also passed at lengths 1,000 and 10,000. The 10,000-event
replay arm passed its durable checks over 129 commands in 30 seconds but had
only 109 steady samples, leaving its benchmark grade inconclusive.
`all-stream-append-ceiling` uses independent account streams, so its writers
share the Kiroku global append position without account version conflicts.
`kiroku.pool-size` and `command.writers` select a cell for a scaling sweep.
Local one- and four-writer runs passed the ledger checks; their throughput
is exploratory until paired cell trials cover the full matrix.
All three command benchmarks accept the four tracing and four metrics modes.
The throughput benchmark passed local two-writer runs with telemetry off,
in-memory collection, OTLP tracing with scraped metrics, and no-op tracing
with served metrics. The in-memory run recorded command spans with no drops
or export failures, and the scraped run completed an endpoint scrape.

The process manager `dispatch-latency` benchmark creates a fresh transfer per
operation and handles its debit through the list adapter. A configured
percentage is delivered a second time. The run records handling time and
source append to worker completion time, then checks that each destination
was credited once and each saga appended one event. Its summary separates
fresh-only and redelivery handling times. A 15-second local two-worker run
passed with 1,181 steady samples, and another passed with in-memory traces
and collected metrics. The Kiroku adapter arm remains to be exercised.

The router `fanout-dispatch` benchmark preopens a fixed recipient set, creates
one bonus declaration per operation, and sends it through the list worker.
It records worker handling time and source append to completion time, with
separate summaries for fresh-only and redelivered inputs. SQL checks the bonus
source count, target credit count, and total money. A 40-second one-recipient
local run passed. The ten-recipient two-worker run had correct durable effects
but exceeded the local driver CPU gate, so the default uses one worker.

`write-side-signals` exercises a command conflict and retry, a repeated event
ID, snapshot hydration, router redelivery, a poison input, and a rejected
dispatch. With in-memory tracing and collected metrics it checks command span
names, internal kind, stream and database attributes, retry attempts, append
counts, and error class. It compares nine counter totals with the durable
account and dead-letter rows. With both telemetry dimensions off, the same
durable outcomes pass and no spans or metric sums are exported.
The command telemetry overhead comparison produced a three-trial report with
18 successful slots and three valid paired blocks. The overall result was
inconclusive because the scraped-metrics and in-memory-tracing comparisons
had wide confidence intervals; the other three comparisons passed their
policy. Results remain in the ignored `runs/` directory.
The matching process-manager dispatch comparison completed 18 successful
slots and three valid paired blocks. Its overall result was inconclusive
because the in-memory tracing arm had a wide confidence interval.

`seed-verification-backlog` runs commands on one snapshotted stream at a
configured verification sampling rate and stream length. It writes measurement
series, checks the final account ledger, and produces a leak diagnosis for
heap, threads, file descriptors, and connections. The reduced duration is 20
minutes by default. One-minute local probes at stream length 100 completed
without command failures at rates zero and one. Rate zero had too few major
collections for a heap verdict. Rate one saturated the local load driver and
showed a short-window heap-growth signal; a longer controlled run is needed to
tell whether growth persists.

`write-side-steady-state` starts two command-writer processes and durable
process-manager, router, and activity-projection workers. It stops writers at
an operation boundary, waits for dispatch and projection to catch up, then
checks account and saga logs, inline balances, async activity, dead letters,
snapshot row bounds, and projection dedup retention. Every child writes its
own RTS and process series and receives a separate leak diagnosis, including
connections selected by its PostgreSQL application name. The pruning interval
defaults to five minutes, and dedup keys are retained for one hour by default.
The retention knob must exceed the expected redelivery horizon. A one-minute
four-account, one-recipient local probe
passed all nine SQL checks over 865 account events with pruning invoked every
second and no old dedup rows. All five child leak verdicts were inconclusive
because the probe was too short. A follow-up one-minute probe passed nine SQL
checks over 868 account events and wrote both writer latency series and
application-specific connection probes. Its first and last tenth had 64 and
63 latency samples, below the minimum for a decided drift comparison.
Periodic kills, telemetry arms, and longer runs remain pending.
