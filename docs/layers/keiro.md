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
with deterministic target commands. The command, process-manager, router,
projection, snapshot, benchmark, soak, and telemetry scenarios share this
fixture. Their implementation record is the repository-local
`docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md` plan.

## Durable execution probes

The durable-execution work tracked by
`docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md`
has incremental runnable probes. `keiro/workflow/correctness/linear-replay-smoke`
checks that replay returns the recorded result without repeating a step effect,
and that journal event IDs match the step index. The
`keiro/workflow/concurrency/linear-self-sigkill-smoke` run starts a resume
worker as a separate process, kills it immediately after an `s2` effect, then
checks that its replacement completes with one `s2` journal entry and the
expected duplicate effect. Run the crash probe with durable PostgreSQL:

```bash
cabal run kenshou -- run keiro/workflow/concurrency/linear-self-sigkill-smoke \
  --dim pg.durability=durable --out runs
```

`keiro/workflow/correctness/sleep-via-timers` checks that named and ordinal
sleeps arm deterministic timer rows, replay leaves the deadline and wake hint
unchanged, due discovery waits for a timer worker, and one drain pass wakes
both workflows with journaled completions. It also checks terminal-owner timer
cancellation and the timer generation after workflow rotation.
`keiro/workflow/correctness/awakeable-signal-semantics` checks a journaled
approval id, first-signal payload preservation, repeated and unknown signal
refusals, terminal-owner settlement, cancellation, and a signal that arrives
before the workflow awaits it.
`keiro/workflow/correctness/continue-as-new-abandons-awakeable-ids` records
that rotation publishes a new approval id; an old signal settles its original
row without waking the new generation, and the new id completes it.
`keiro/workflow/correctness/exact-discovery` parks awakeables, sleeps, or
parents with sleeping children according to `workflow.parked-on`. It measures
an idle pass with no candidates and samples the pending-awakeable count query
through `pg_stat_statements`. Signalling or draining ten wake sources then
discovers exactly ten workflows; children wake their parents on a following
pass. Its `workflow.population.parked` knob defaults to 2,000.
`keiro/workflow/correctness/patch-decisions-are-frozen` parks an instance
before enabling patch `p1`, then checks that its old branch is preserved while
a fresh instance takes the new branch. Two concurrent runs with different
patch sets share one recorded decision.
`keiro/workflow/correctness/children-spawn-await-cancel-fail` checks that a
spawned child is discoverable before any child step, that the parent remains
parked, and that completion writes an `{"ok": …}` result in the parent
journal. It also checks cancellation markers and a child failure at the
attempt ceiling. A rotated parent reattaches to a completed child and reads
its result from the new generation.

The two timer correctness scenarios,
`keiro/timer/correctness/lifecycle-and-at-least-once` and
`keiro/timer/correctness/max-attempts-dead-letters-post-claim`, cover first
arm, rearm, ordered claims, stuck recovery, repeated callback execution, and
the post-claim dead-letter ceiling. The
`keiro/timer/concurrency/skip-locked-claims-across-processes` scenario starts
four timer-worker processes against due timers and checks that each timer has
one claim, one flushed effect, and one deterministic business event. Its
`timer.count` knob defaults to 5,000; the default durable run passed.
`keiro/timer/concurrency/sigkill-between-fire-and-mark` kills a worker after
the business event append. A replacement requeues the firing row and marks it
fired on attempt two while the business stream still has one event.
That scenario also runs a fifty-timer seeded random-delay kill arm: three
workers die, a replacement drains the work, and the oracle bounds raw fires
by recorded attempts while requiring one business event per timer.
`keiro/timer/concurrency/slow-fire-double-fires` pauses the first worker after
its business append while a second worker requeues and completes the stale
claim. The probe confirms two fire attempts, one business event, and refusal
of the first worker's late mark.
`keiro/timer/concurrency/foreground-resume-tokens` races four claimant
processes for one dead timer. It checks one owner, renewal, guarded mutation
refusals, recovery after lease expiry with stuck requeue disabled, retained
reason and attempts, and refusal of an expired owner's completion.
The
`keiro/shard/correctness/lease-coverage-smoke` scenario claims four buckets
one per pass, relinquishes them, and checks that another owner can claim them
without overlap. `keiro/shard/correctness/shard-count-mismatch` starts
separate workers with smaller and larger shard counts against a four-bucket
subscription, then starts another correctly configured worker. Keiro 0.17.0.0 rejects the larger caller
after inserting two extra rows, so the scenario reports a reproduced known
defect at `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-49`.
The mismatch probe also seeds an account event and confirms the rejected
delivery workers do not consume it.
The shard worker accepts validated `shard.*` options, including bucket count,
lease duration, renewal interval, batch and buffer sizes, and retry limits.
`keiro/shard/correctness/single-worker-drains-all-buckets` runs its delivery
loop against account-category events, checks the durable sink and flushed
effect facts, then checks graceful lease relinquish.
Its sink records first-delivery sequence, so the oracle also verifies strict
per-stream order. The default 20,000-event durable run passed.
The `keiro/shard-appender` role now seeds that account-category stream from
a separate supervised process, with deterministic event IDs and progress
reports every thousand events.
`keiro/shard/concurrency/late-joiner-gets-no-buckets` starts two more workers
after the first owns every bucket. Both durability modes reproduce the declared
Keiro 0.17.0.0 limitation: healthy ownership remains with the first worker,
while complete coverage persists.
`keiro/shard/concurrency/sigkill-failover-vs-graceful-relinquish` checks lease
retention after a killed worker, transfer by the calculated failover deadline,
and immediate release and faster recovery after a graceful stop.
`keiro/shard/concurrency/coverage-after-membership-change` runs a paced
appender during those membership changes, samples ownership every 100 ms,
and reports measured recovery gaps. The default durable run delivered all
20,000 events; graceful and killed recovery took 3.54 s and 6.60 s.
`keiro/shard/concurrency/fair-share-shedding` joins a second worker before
full coverage, forces the first to shed an in-flight bucket, and checks
balanced ownership, redelivery of that event, and complete sink delivery.
`keiro/shard/correctness/ack-coupled-handler-variants` checks explicit
retries, retry exhaustion, explicit dead letters, a plain handler that throws
once, and delivery of events that follow each failure.
`keiro/shard/concurrency/zombie-past-lease-ttl` pauses an owner past lease
expiry, lets another worker claim its buckets, resumes the old process, and
checks checkpoint direction, the post-resume effect window, and full delivery.
`keiro/shard/concurrency/database-faults` terminates shard worker database
backends and restarts the run's PostgreSQL server. It checks the worker error
hook, continued process life, recovered ownership, and delivery of all events.
These correctness probes support both PostgreSQL durability modes. The remaining workflow kinds, process concurrency cases,
subscription delivery checks, benchmarks and soaks remain in the plan's
Progress section.

A Keiro-only smoke plan selected sixteen scenarios and completed locally in
about half a minute. Fifteen passed; the `NoAdvance` receipt scenario reproduced
its declared nonblocking known defect. The plan executor exited zero.

`keiro/workflow/concurrency/direct-run-vs-resume-worker` races inline
linear runs with a polling resume process. Journals and replay results stay
exact; the default durable run measured 61 duplicate step effects over 100
instances without a crash.
`keiro/workflow/concurrency/resume-workers-race` seeds deferred instances
and starts multiple resume processes. A durable run with 100 instances, four
workers, four store connections per process, and sixteen concurrent advances
per worker completed with one journal entry and one effect per step.
`keiro/workflow/concurrency/sigkill-step-boundary` kills two workers after
flushed step effects and a third during a step pause. Replacement workers
complete the cohort; the default 100-instance durable run recorded three
crash-bounded duplicate effects, exact journals, and no retry attempts.
`keiro/workflow/concurrency/crash-backoff-and-max-attempts` runs a flaky step
through its retry ceiling, checks the 2, 4, and 8 second spacing at four
attempts, observes a quiet failed instance for sixteen seconds, then
resurrects it and completes it with a repaired worker. The failure event
remains in the journal.
`keiro/workflow/concurrency/database-faults` terminates a resume worker's
PostgreSQL backends during an effect pause and restarts the PostgreSQL server.
The worker survives and two other
workers finish the cohort. The default 100-instance durable run passed exact
journals, at-least-once effects, and zero consumed retry attempts.
`keiro/wake/correctness/push-fallback-when-notify-dropped` runs one approval
through a wake source that never notifies, then another through a push source
whose `kiroku-listener` backend is terminated before the signal. At a one-second
fallback interval, both PostgreSQL modes completed within the interval plus
two seconds. The resume role uses Keiro's notifier for `push` mode.
`keiro/workflow/benchmark/parked-population-pass-cost` measures repeated idle
resume passes over workflows parked on awakeables, sleeps or children. The
`workflow.population.parked`, `workflow.parked-on` and
`workflow.benchmark-duration-seconds` knobs control the shape. A three-second
durable run at 2,000 awakeables recorded 7,381 idle passes and wrote raw
samples, latency histograms and the pending-awakeable count statement delta.

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
`--set pm.kill-window=between-targets`. The resumed worker also replays an
acknowledged signal through the manager and reports `PMStateDuplicate`; all
four crash windows passed this fact and the durable oracle.
`random-kill-exactly-once` paces debit and announcement commands while
restarting the real saga worker at a configured interval. An optional arm
terminates one of its PostgreSQL backends before alternating restarts. A
30-second local run submitted 300 transfers, restarted the worker nine times,
terminated four backends, and passed its durable effect and dead-letter checks.
A default run completed 6,000 transfers with 60 restarts and 30 confirmed
backend terminations, passing all six durable checks. It took about 249 seconds
on this host, so the scenario now reports effective rate and marks runs that
miss their paced schedule as inconclusive for rate validation.
A rate-valid full-duration run at twenty transfers per second completed 2,400
transfers in 120.01 seconds with 29 restarts and 14 confirmed backend
terminations. All six durable checks passed. The earlier 50/s default result
remains rate-inconclusive on this host.
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
For duplicate subscribers and consumer groups, the process-manager worker can
optionally replay a successfully acknowledged signal through the manager and
report whether the manager state result is `PMStateDuplicate`. The topology
scenario requires that reported fact and the unchanged exact SQL effects.
Both topologies passed with seven checks; the shard topology passed its six
SQL and process checks without the acknowledgement probe.
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
both replayed one duplicate within the batch bound. `projection.crash-count`
repeats the apply-before-checkpoint kill on successive events; a three-kill
batch-size-one run passed its per-kill activity and deduplication checks.
Larger batches can replay the whole applied prefix after each kill; a
five-kill batch-size-ten run passed with one to five reported duplicates.
Set `projection.random-kill-positions=true` to choose applied-event positions
from the run seed while keeping each crash before its checkpoint. A five-kill
batch-size-ten run parked after 3, 5, 8, 10, and 11 cumulative applies and
passed all six durable checks; replay counts stayed within the batch bound.
The oracle bounds that count by the batch size. The stronger
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
and collected metrics. `pm.source=kiroku-adapter` runs the production durable
bridge, injecting one immediate retry for the selected redelivery share. A
15-second local run completed 1,399 transfers, including 350 redeliveries,
with a benchmark grade and all three durable checks passing.

The router `fanout-dispatch` benchmark preopens a fixed recipient set, creates
one bonus declaration per operation, and sends it through the list worker.
It records worker handling time and source append to completion time, with
separate summaries for fresh-only and redelivered inputs. SQL checks the bonus
source count, target credit count, and total money. A 40-second one-recipient
local run passed. The ten-recipient two-worker run had correct durable effects
but exceeded the local driver CPU gate, so the default uses one worker.
`router.source=kiroku-adapter` runs the production durable bridge and injects
one immediate retry for the configured redelivery share. A 40-second
one-recipient run completed 1,368 fanouts, including 350 redeliveries, with a
benchmark grade and all four durable checks passing.

`write-side-signals` exercises a command conflict and retry, a repeated event
ID, snapshot hydration, router redelivery, a poison input, and a rejected
dispatch. With in-memory tracing and collected metrics it checks command span
names, internal kind, stream and database attributes, retry attempts, append
counts, and error class. It compares nine counter totals with the durable
account and dead-letter rows. With both telemetry dimensions off, the same
durable outcomes pass and no spans or metric sums are exported.
The fixture runtime supplies the shared tracer and Keiro metrics handles to
command and worker options in this scenario.
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
minutes by default. History setup appends batches directly and crosses each
snapshot boundary through the Keiro command runner. A 10,000-event starting
stream passed all four durable checks in a one-minute rate-zero probe over
6,596 timed commands. Set `diagnose.major-gc-interval-ms` to request
post-major heap samples for a diagnostic soak; this perturbs latency and must
not be used for performance comparisons. One-minute local probes at stream
length 100 completed without command failures at rates zero and one. Rate zero
had too few major collections for a heap verdict. Rate one saturated the local load driver and
showed a short-window heap-growth signal; a longer controlled run is needed to
tell whether growth persists.
Three-minute diagnostic sampling with forced major collections found heap
growth even with seed verification disabled. A two-minute constant-rate pair
completed 391 commands in each arm and showed almost identical growth with
verification on and off. The runs passed the durable checks but had too few
steady samples for benchmark grading. The evidence and follow-up are in
`docs/findings/2-keiro-seed-backlog-heap-growth.md`.
An in-memory tracing and collected-metrics arm completed 211 commands in one
minute and passed four durable checks with 211 exported spans and no drops.
Its overall result was `failed` on main-process Haskell thread growth; a
matching earlier run was inconclusive on that probe. See
`docs/findings/3-keiro-steady-restart-harness-threads.md` for both observations.

## Outbox

The outbox scenarios use Keiro's publisher against a synthetic broker. The
single-process broker stores wire records in memory; crash and competing-worker
scenarios store them in `kenshou_fx.broker_log` through a separate PostgreSQL
pool. Both use `Keiro.Outbox.Kafka.outboxRowToKafkaRecord` for the published
envelope. The table broker allocates offsets per topic and partition; the
multi-process scenario checks that each partition's offsets remain contiguous
under competing publishers. List the current scenarios with
`cabal run kenshou -- list 'keiro/outbox/**'`.

The correctness runs cover terminal `sent`, `rejected`, and `dead` states,
ordered publication after a transient failure, skipped successor attempts,
publisher callback errors, and stable producer identity.
The identity probe also asserts the literal UUID and message ID vector from
`mori://shinzui/keiro/okf/adrs/concepts/ADR-42`.
The failure-skip probe exercises per-key, per-source, and stop-the-line
ordering, including the summary's halted pivot for stop-the-line.
Terminal rejection leaves successors publishable under all three ordered
policies; stop-the-line does not halt on a rejected row. The producer replay
probe retains a rejected row through maintenance and zero-retention GC. An
identical re-enqueue returns `ProducerDuplicateIdentical`, leaves the entire
row unchanged, and does not add to the outbox backlog.
The terminal-state probe has passed all four policies with constant and
exponential backoff at 200 rows. The serialized-order probe passed all three
ordered policies at 5,000 rows; its per-source broker callback stops dispatch
after a source failure so later rows are never appended and then marked skipped.

The crash scenario
parks a publisher after the broker append, kills its process with `SIGKILL`,
and checks that only maintenance reclaims the stranded rows. Its 2,000-row
default passed with three kills on durable PostgreSQL. The run writes
`no-loss.json`, `bounded-duplicates.json`, and
`reclaimed-only-by-maintenance.json` with counts and killed process IDs. The
`outbox.crash-point=after-claim` arm parks before any broker append; its
32-row durable run left no broker duplicates and recovered all rows through
maintenance. The default after-append arm passed again after this role change.
The `backend-kill-during-mark` arm releases the post-append hook while a table
lock blocks finalization, then terminates the waiting PostgreSQL backend. Its
32-row durable run left the batch publishing until maintenance reclaimed it;
replay stayed within the declared duplicate bound.
With `outbox.exhaust-attempts=true`, two after-claim kills consumed the attempt
ceiling: maintenance left 32 dead rows, and 32 later rows of the same key
reached the broker. The dead rows remain visible for operator action.
The four-process publisher scenario passed with 20,000 rows and 200 keys: each
outbox row had one broker record and one consumed attempt, and first-record
order held within each key. A strengthened 2,000-row run observed records from
two publishers, with no loss or duplicate records. The inline enqueue ordering
scenario uses an advisory lock to start one transaction before another but
commit it later. Its durable run published `second` before `first` as documented
in `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16`; the schedule
and no-loss contract verdicts held, while the scoped per-key-order verdict was
violated under the known-defect reference. These concurrency scenarios require
`pg.durability=durable`.
With `--set outbox.enqueue-path=producer-direct`, the ordering scenario makes
two serialized calls to `enqueueProducerEventTx`; its durable control run passed
the schedule, no-loss, and per-key-order verdicts. With
`outbox.enqueue-path=producer`, two durable account events pass
through Kiroku's ack-coupled subscription. Each event is decoded and enqueued
before its acknowledgement; the subscription stops after the second
checkpoint. The durable control run passed the stream-order, no-loss, and
per-key-order verdicts.
`producer-identity-race-with-gc` runs four concurrent replayers of 128 stable
source events while a publisher drains and zero-retention GC deletes sent rows.
Its durable run deleted 192 rows and observed 106 republications. All 640
enqueue calls returned inserted or identical-duplicate outcomes within the
bound; retained identities stayed unique, and every broker record carried the
derived message ID for its source event. Use `outbox.enqueuers` and
`outbox.source-events` to change the contention size. Republications are
expected because suppression ends when GC removes a sent row.

`zombie-publisher-finalization` stops a publisher after it claims one row,
lets maintenance requeue that row, and parks a second publisher after its
broker append. When the first publisher resumes, its late finalization
changes the second publisher's claim. The `failed` and `dead` arms leave the
row in those states despite the second publisher reporting success; the
`succeeded` arm also proves that the old publisher can finalize the newer
claim. All three durable schedules were realised. The ideal finalization
verdicts are scoped to upstream
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5` and are reported as a
known defect, while a missed schedule remains a blocking failure. Select the
arm with `outbox.zombie-outcome=failed|succeeded|dead`.

## Inbox

`keiro/inbox/correctness/envelope-round-trip` passes outbox records through
the synthetic broker and Keiro's inbox decoder. It checks the reconstructed
integration events and all six required headers. The table-backed
`effectively-once-matrix` now passes all eight combinations of message-ID,
source-event, Kafka-delivery, and custom business-key dedupe with full-envelope
or dedupe-only persistence. It redelivers each of 16 messages at the same
offset, then republishes it with a new message ID and offset. The republish
produces 32 total effects under message-ID and Kafka-delivery identity, and 16
under source-event and custom identity. A missing field required by each
policy fails without a receipt. Dedupe-only rows have empty payloads and no
attributes; full-envelope rows retain both. The effect table has no uniqueness
constraint, so the inbox receipt enforces the one-effect result. The oracle
compares the complete set of effect message IDs and dedupe keys to the
expected deliveries.
With `inbox.idempotence=delegated`, the same four policies use deterministic
event IDs on account streams as receipts. Each of 16 accounts receives one
deposit on first delivery, no deposit on redelivery, and a second deposit on
republish only for message-ID and Kafka-delivery identity. The inbox table
stays empty. A zero-event command and a rejected command return their typed
delegated errors without changing the target stream. All four delegated arms
passed on durable PostgreSQL. Each also rejects a delivery missing its
policy-required identity without adding a receipt.
`poison-accounting` verifies the default exception path's three-attempt
ceiling and retention of failed rows. With `inbox.failure-mode=condemn`, two
deliveries each report processed but roll back; a nontransactional sequence
confirms that the handler ran twice, while no inbox row or effect remains. With
`inbox.failure-mode=sql-error`, division by zero returns Keiro's
`UnexpectedServerError` classification and leaves no completed row or effect.
With `inbox.idempotence=delegated`, the caller-owned retry context stops an
attempt above the ceiling before invoking the handler; the ceiling attempt
runs it, and neither creates an inbox row.
`batch-fast-path-and-fallback` checks that a clean batch shares one transaction
and a throwing delivery falls back to per-message processing without
duplicating other effects. With `inbox.failure-mode=condemn`, the batch rolls
back, the poison handler runs again in the fallback, its reported processed
receipt leaves no row, and the other deliveries commit one effect each. Both
arms passed with durable PostgreSQL.
With `inbox.idempotence=delegated`, the batch runner returns results in
delivery order, suppresses a repeated successful key within the call, and
retries a key whose first handler invocation threw. A second batch invokes
the handler again for the same key, showing that batch memory is call local.
The delegated arm leaves the inbox table empty.
The `race-one-key` no-kill arm starts four real consumer processes against a
slow transactional handler. Its durable run observed one processed delivery,
three duplicates, one completed inbox row, and one protected effect.
The `--set inbox.kill-winner=sigkill` arm waits until the first consumer is
inside its SQL handler, kills that process and its still-running database
backend, then starts the peers. One of them commits the effect; the other two
see a duplicate. `inbox.kill-winner=backend-kill` terminates only the first
consumer's database backend and checks that its connection error is visible.
In both fault arms a fresh consumer redelivers the message after the peers
finish and reports duplicate; the final effect count remains one.
`gc-vs-insert-race` is registered with the documented inbox GC limitation.
The current staged proxy runs delete the old receipt and observe a second
handler effect, but the consumer leaves a replacement receipt. The strict
schedule guard therefore reports these runs as inconclusive while the
insert-versus-lookup gap is investigated.

## Job queue

The queue scenarios provision PGMQ through the harness migration and run
Keiro's typed job API through its separate runtime pool.
`consumption-config-rejections` checks invalid tuning, ordering mismatch,
unsafe legacy FIFO batch size, and error precedence. Direct SQL confirms that
the queued row still has `read_ct = 0` after all rejections; valid tuning then
drains it. `max-retries-before-handler` checks that three immediate retries
call the handler three times and the fourth read moves the row to the DLQ
with `max_retries_exceeded` and `read_count = 4`. A zero ceiling moves its
row to the DLQ on the first read without a handler call.
The `job-outcome-semantics` arms check Done deletion, explicit and default
retry delays and attempt numbering, delayed enqueue, terminal Dead routing to
a DLQ or archive, batch ID uniqueness and rows, FIFO group headers, and
redelivery at the visibility timeout after a thrown drain handler.
Malformed payloads move to the DLQ; future-version payloads stay queued and
consume delivery attempts while the worker waits for a compatible version.
The worker Done arm confirms attempt zero, an absent arbitrary-headers context,
one effect, and source-row deletion.
The worker Retry arm checks a second handler effect after its one-second delay
and eventual source-row deletion. The worker Dead arm checks one handler effect,
source-row deletion, and a poison-pill wrapper in the DLQ.
The decoded wrapper retains the original payload, message ID and read count.
For this untraced job it includes an `original_headers` key with a null value;
Keiro's decoded view reports that as absent headers.
A thrown worker handler is redelivered after the one-second visibility timeout;
the second delivery completes, leaving two observed handler effects and no
source row.

`workers-survive-transient-polling-error` runs a continuous supervised job
worker and terminates its PostgreSQL polling backend. The current released
cohort stops after the first termination with an unexpected row-count error;
the next batch stays queued. The scenario records contract verdicts and tracks
the upstream finding at `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3`.

`crash-redelivery-cadence` kills three worker processes while their handlers
hold the same job. With ordinary polling, deliveries occur about three seconds
apart, attempts increase from zero through two, and the next read moves the job
to the DLQ even though the retry policy delay is 60 seconds. The long-poll arm
currently consumes an extra read attempt without a matching handler delivery;
the failing verdicts are tracked at `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4`.

`lease-extension` runs two continuous workers with a six-second handler and a
two-second base visibility timeout. The current worker-path arm observes two
effects when the handler leaves the lease alone and one effect when it extends
the lease by ten seconds before work. Set `queue.execution-shape=drain` to
exercise bounded `runJobOnceWithContext` calls with the same timing. Its durable
run observed two unextended effects and one extended effect; the extended job
was delivered once at attempt zero. The worker path also passed that attempt
check, regardless of which worker claimed the job.

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
Set `soak.kill-interval-seconds` to rotate SIGKILL and restart across the saga,
router, and projection workers while writers continue. A one-minute run with
ten-second intervals recorded six restarts and passed all ten checks over
1,593 account events. Its overall outcome was `failed`: the harness process's
Haskell thread probe rose by six, while its native memory, OS threads,
descriptors, and database connections were stable. Retiring exited children
from the supervisor did not remove the signal. The finding is recorded in
`docs/findings/3-keiro-steady-restart-harness-threads.md`. Telemetry arms and
longer runs remain pending.
A five-minute sixteen-account run passed all nine durable checks over 9,250
account events. The process-manager and router child reports flagged growing
post-GC live heaps, while their native memory, threads, descriptors, and
connections were stable. The signal and reproduction steps are recorded in
`docs/findings/1-keiro-write-side-worker-heap-growth.md`; a longer isolated
subscription run is needed to determine whether this is retained runtime
state or a true leak.
