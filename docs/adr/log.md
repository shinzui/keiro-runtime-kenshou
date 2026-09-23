# Bundle Update Log

## 2026-09-23
* **Decision**: Accepted parking in Keiro hooks before external process or backend termination.
* **Decision**: Accepted kenshou-keiro ownership of the shared ledger fixture and SQL oracles.

## 2026-09-22
* **Changed**: Applied contract-strength, known-defect, and controlled-benchmark decisions to Kiroku's isolation evidence.
* **Decision**: Distinguished documented implementation limitations from canonically referenced upstream known defects.
* **Decision**: Accepted native SQL polling on a dedicated connection for metrics-only layers.
* **Decision**: Accepted the PostgreSQL clock as the authority for message lease and due-time verdicts.

## 2026-09-21
* **Changed**: Document the telemetry-off control, isolated helpers, and controlled-evidence basis.
* **Decision**: Accepted sealed-run immutability for offline diagnosis.
* **Decision**: Accepted post-major live bytes as the heap leak basis and separated native-memory evidence.
* **Decision**: Accepted real process and PostgreSQL termination as the definition of a crash.
* **Decision**: Accepted contract-strength classifications and non-vacuous correctness verdicts.
* **Changed**: Added summarize and compare to the versioned runtime protocol.
* **Decision**: Accepted an independent measurement channel for benchmark evidence.
* **Decision**: Accepted controlled benchmark evidence requirements for comparison verdicts.
* **Addition**: ADR-5 accepts checked-in change selection with fail-safe over-selection.
* **Changed**: Record the Git-aware CLI release identity alongside the resolved cohort.
* **Changed**: Record the resolved cohort identity and cache-safe cohort switching contract.
* **Migration**: Adopt the shared architecture-decision profile.

## 2026-09-20
* **Decision**: Accepted harness-provisioned databases and one composed migration ledger per database.
* **Decision**: Accepted harness ownership of the versioned runtime verification protocol.
