# Bounded trace probe retains evicted spans

Status: repaired in source; focused regression and full repository checks pass. Matched process-soak
confirmation is pending.
Owner: this repository's in-memory tracing probe. No runtime owner defect is
assigned and no dependency version changes.

The twenty-minute queue process diagnostic
`01a0ff9f-1064-7507-8640-9d362911debb` under
`runs/ep13-queue-process-reduced` held all ten business checks over 6,051 jobs
and 303 archived dead jobs, but reported sustained heap growth in the main
process and both workers. The worker second-half slopes were approximately
83.8 and 85.7 MB/hour. Other bounded probes were stable. It used
`sdk-inmemory`, served/scraped metrics, and forced major GC every five seconds.
The source capture predates the repair below; its failure remains unchanged.

`ProbeState` in
[kenshou-telemetry/src/Kenshou/Telemetry/Tracing/Probe.hs](../../kenshou-telemetry/src/Kenshou/Telemetry/Tracing/Probe.hs)
had lazy counter and sequence fields. `atomicModifyIORef'` evaluated only the
outer constructor, allowing unevaluated append/eviction operations to retain
older spans until the probe was read. A nominal capacity of 4,096 therefore
did not bound retained tracing state during an unattended soak.

The focused regression emits ten spans into capacities zero and one, keeps the
provider and probe alive, performs a major GC before reading either probe
field, and requires the first span's mutable-state value to be unreachable via
a weak reference. The unrepaired implementation fails; strict counter and
sequence fields make it pass. The test also checks the final observed count
and retained capacity. It refers to `SpanHot`, since the SDK's outer span
wrapper may be collected even while the captured state is retained.

```bash
nix develop -c cabal test kenshou-telemetry-test \
  --test-show-details=direct \
  '--test-options=--match="releases evicted spans"'
```

The fix evaluates eviction on capture; it changes neither sampling policy nor
leak thresholds. Full process-soak resource attribution remains subject to the
matched repaired run. This is distinct from finding 3's historical default-GC
thread-count signal. Existing telemetry-off full soaks are not invalidated by
this in-memory tracing defect.

Validation: the full `nix develop -c just verify` gate and all 36 telemetry
examples pass. The focused regression fails before the strict-state repair
and passes after it. Matched reduced process runs remain pending.
