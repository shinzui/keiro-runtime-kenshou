# Diagnosing leaks and concurrency stalls

This guide starts from a completed Kenshou run. Offline diagnosis treats that
run directory as sealed: it reads the manifest, result, sampled series, and
saved captures, but never adds or changes a file there. Put any JSON or DOT
output elsewhere with `--out` or `--dot`.

## Start with the result

Inspect the outcome and its diagnosis summary before choosing a tool:

```console
jq '{outcome, diagnosis}' .dev/runs/RUN-ID/run-result.json
```

The summary tells you whether the finding is a leak or a stall and names the
supporting diagnosis. The diagnosis is evidence, not merely a label: it records
the source series, window, estimator, thresholds, captured threads, PostgreSQL
sessions, locks, and pool occupancy used to reach the result.

## Follow a suspected leak

Re-judge the original samples using the default policy:

```console
cabal run kenshou -- diagnose leak .dev/runs/RUN-ID
```

Exit 1 means at least one bounded probe has credible growth, 0 means stable, 3
means the run did not contain enough evidence, and 4 means its inputs could not
be read. `--policy FILE` (or `--policy -` for stdin) changes thresholds without
rerunning the workload. Use `--json` or `--out ../leak.json` for the full
recomputable report.

First identify the process and probe. Growth in `heap.live-bytes` means objects
remain reachable after collection. Growth in `process.native-bytes` without
heap growth points instead to the RTS allocator or foreign libraries such as
libpq and librdkafka. Thread, descriptor, connection, table, and queue probes
name the resource that is accumulating directly.

Make the shortest reproduction that still shows the slope. For heap work,
enable exact post-collection points with the scenario knob:

```console
cabal run kenshou -- run SCENARIO --out .dev/runs \
  --set diagnose.major-gc-interval-ms=1000
```

Forced major collections perturb timing and CPU use. They can also make
`BlockedIndefinitelyOnMVar` or `BlockedIndefinitelyOnSTM` surface sooner, because
the RTS discovers unreachable wake-up sources during collection. Compare with
the knob set to 0, which uses the lower envelope of ordinary samples.

Next learn what grows with a closure-type profile:

```console
cabal run kenshou -- diagnose profile SCENARIO \
  --mode closure-type --interval-s 1 --out .dev/profiles
```

In eventlog2html, a growing `ARR_WORDS` band commonly means byte arrays or text;
a growing `THUNK` band suggests unevaluated work; a constructor name points to
a retained data structure. This mode uses the ordinary build.

To locate the allocator, build the info-table variant and run the same scenario
with that binary:

```console
just diagnose-build-info-table
$(nix develop -c cabal --project-file=cabal.diagnose-info-table.project \
  --builddir=dist-diagnose/info-table list-bin kenshou-cli:exe:kenshou) \
  diagnose profile SCENARIO --mode info-table --out .dev/profiles
```

The exact platform component in the path differs by machine. Open the generated
event log in eventlog2html and use its detailed view; the rising band identifies
the allocating source location. For the leaking diagnostic self-test it should
lead to `kenshou-diagnose/src/Kenshou/Diagnose/SelfTest/Leak.hs`.

If allocation is expected but retention is not, use a profiled build with
`--mode profiled --breakdown r` for a retainer profile. As a deeper alternative,
build with the `ghc-debug` Cabal flag, set `KENSHOU_GHC_DEBUG_SOCKET`, and attach
`ghc-debug-brick` 0.8.0.0 to walk retaining paths. Local attachment uses the Unix
socket. On a verification cell, forward the socket through the IAP-tunnelled SSH
connection; the existing wrapper is `scripts/iap-ssh.sh tunnel <instance>
<remote-port> <local-port>` in `mori://shinzui/load-testing-infra`. Cell-side
attachment is documented here but has not been exercised; it depends on
[`docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md`](../plans/16-provide-leased-verification-cells-in-load-testing-infra.md)
and [`docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`](../plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md).

Do not diagnose a leak from `max_live_bytes`. It is a lifetime high-water mark,
so it cannot decrease and usually grows even when the current live heap reaches
a plateau. Use live bytes after major collections or the documented envelope.

Known places worth checking after evidence points at them include fire-and-forget
snapshot-seed verification in keiro, unbounded in-progress batch keys in
shibuya, and foreign allocations in libpq or librdkafka. Treat these as leads,
not conclusions.

## Follow a concurrency stall

Render every saved watchdog capture:

```console
cabal run kenshou -- diagnose stall .dev/runs/RUN-ID
cabal run kenshou -- diagnose stall .dev/runs/RUN-ID \
  --reclassify --dot ../wait-graph.dot
```

`--reclassify` applies the current classifier to old evidence. The DOT graph has
an edge from each waiting PostgreSQL backend to its blocker. To capture the
current local and PostgreSQL state outside a run, use:

```console
cabal run kenshou -- diagnose stall --live \
  --connection "$DATABASE_URL" --out ../live-stall.json
```

Interpret the primary classification as follows:

- `deadlock`: a wait-for cycle is present. Match each PID to its labelled
  application and statement, then inspect the inconsistent lock ordering.
- `lock-wait`: a chain has a root blocker but no cycle. Find that backend's
  transaction and explain why it remains open; an `idle in transaction` root is
  especially suspicious.
- `pool-starvation`: all registered connections are in use while callers wait.
  Look for code that acquires a second connection while holding the first, and
  compare pool size with the maximum worker concurrency.
- `blocked-indefinitely`: the RTS reports an unreachable `MVar` or STM wake-up
  source. In an info-table build, use the decoded stacks of the named blocked
  threads to find the abandoned synchronisation path.
- `idle-spin`: work does not advance while CPU or query-call rate does. Inspect
  the top `pg_stat_statements` entries by calls per second and the corresponding
  worker loop.
- `unknown`: the snapshot proves that progress stopped but does not meet a
  stronger rule. Preserve the raw capture, add thread labels and pool observers,
  and rerun under the info-table or eventlog profile.

Profiling and diagnosis are themselves observable work: thread-stack decoding,
PostgreSQL catalog queries, forced collections, and event logging all perturb a
run. Reproduce once without them, then add one diagnostic layer at a time and
record its settings with the evidence.
