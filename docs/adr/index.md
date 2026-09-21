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

