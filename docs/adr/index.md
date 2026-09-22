---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [Layer packages never import one another](0001-layer-packages-never-import-one-another.md) - Each runtime layer is its own cabal package depending only on the kernel and toolkits, so a red layer is attributable and layers build and run independently.
- [Every result carries a resolved cohort identity](0002-every-result-carries-a-resolved-cohort-identity.md) - Verification results identify the complete runtime cohort actually selected by Cabal, including immutable sources and a deterministic plan hash, rather than recording only intended pins.
- [Kenshou owns the runtime verification protocol](0003-kenshou-owns-the-runtime-verification-protocol.md) - The harness kernel owns versioned list, run, result, worker, and manifest documents so every layer and external runner shares one stable protocol.
- [Scenarios use provisioned databases and one migration ledger](0004-scenarios-use-provisioned-databases-and-one-ledger.md) - Scenarios receive database handles from the harness; the environment composes Kiroku, Keiro, and PGMQ migrations through one pg-migrate ledger per database.
- [Select runs from a checked-in component graph and over-select when unsure](0005-select-runs-from-a-checked-in-component-graph.md) - Kenshou maps changes through a reviewed build-and-runtime dependency graph, verifies build edges mechanically, and selects all evidence when an input cannot be mapped safely.
- [Comparison verdicts require controlled benchmark evidence](0006-comparison-verdicts-require-controlled-benchmark-evidence.md) - Performance verdicts come only from paired, interleaved, compatibility-checked, benchmark-grade runs, while historical measurements remain telemetry.
- [Record measurements independently of the feature under test](0007-record-measurements-independently-of-the-feature-under-test.md) - The measurement toolkit records latency, load, runtime, process, host, and database evidence without depending on application telemetry paths being tested.
- [Classify invariants by contract strength](0008-classify-invariants-by-contract-strength.md) - Kenshou labels every correctness invariant as a public contract or an implementation property and only contract failures block a release.
- [Define crashes as process or backend termination](0009-define-crashes-as-process-or-backend-termination.md) - Kenshou exercises crash recovery by terminating an operating-system process or PostgreSQL backend, never by throwing an in-process exception.
- [Judge heap leaks on live bytes after major collections](0010-judge-heap-leaks-on-live-bytes-after-major-collections.md) - Heap leak verdicts use forced-major-collection samples or the lower envelope of post-major live bytes, while native memory is reported separately.
- [Never mutate a sealed run during offline diagnosis](0011-never-mutate-a-sealed-run-during-offline-diagnosis.md) - Offline analysis reads immutable run evidence and writes requested derived output outside the sealed run directory.
- [Judge message leases on the database clock](0012-judge-message-leases-on-the-database-clock.md) - PGMQ lease and due-time verdicts compare timestamps produced by PostgreSQL rather than clocks from harness or worker processes.
- [Collect layer metrics through the native SQL surface](0013-collect-layer-metrics-through-the-native-sql-surface.md) - A layer without a metrics endpoint implements telemetry collection by polling its native SQL metrics API on a dedicated connection.
- [Distinguish documented limitations from known defects](0014-distinguish-documented-limitations-from-known-defects.md) - Verification asserts documented implementation limitations as expected behavior and reserves known-defect status for behavior with an identified upstream correction.

