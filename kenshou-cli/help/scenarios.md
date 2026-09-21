# Scenarios

A scenario is one named verification procedure. Its stable identifier has four lowercase segments: `layer/component/kind/name`. The layer identifies the runtime boundary under test, and the kind is `correctness`, `concurrency`, `soak`, or `benchmark`.

Use `kenshou list` to inspect registered scenarios. Scenario identifiers are versioned by a separate revision number so a changed workload is never silently compared with an older one.
