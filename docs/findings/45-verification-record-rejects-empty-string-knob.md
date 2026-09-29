# Verification recorder rejects a valid empty-string knob

Status: reproduced and repaired in this repository's verification-profile integration. The passed Keiro run is now digest-linked in the historical OKF bundle.

The clean alpha queue sweep `01a0ef4f-ce12-74f3-823c-360e44b1ff93` verified nested `keiro/queue/correctness/telemetry-contract` run `01a0ef4d-d6ae-76a1-8a59-c3c7a8d482e0` as passed. Its effective run specification includes `otel.endpoint=""`, the normal default for the in-memory telemetry arm. `kenshou record ... --purpose baseline --verify-only` rejected the run with `MissingNestedProfileField ... knobs[9].value`. The recorder emits that knob as a present empty string, while the shared verification profile requires every `knobs[].value` and OKF's scalar-presence rule counts a blank string as absent.

The local profile overlay now relaxes only the Verification Run `knobs[].value` presence rule; the evidence parser still requires the `value` key and preserves the empty string. The profile regression fixture accepts a valid empty endpoint, and the [same sealed run](../verification/runs/keiro/2026/09/01a0ef4d-d6ae-76a1-8a59-c3c7a8d482e0.md) recorded with `--verify-only`. No Keiro or OpenTelemetry defect follows from this recorder rejection.
