---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [Layer packages never import one another](0001-layer-packages-never-import-one-another.md) - Each runtime layer is its own cabal package depending only on the kernel and toolkits, so a red layer is attributable and layers build and run independently.
- [Every result carries a resolved cohort identity](0002-every-result-carries-a-resolved-cohort-identity.md) - Verification results identify the complete runtime cohort actually selected by Cabal, including immutable sources and a deterministic plan hash, rather than recording only intended pins.

