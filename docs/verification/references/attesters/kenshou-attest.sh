#!/usr/bin/env bash
set -euo pipefail

# Deterministic verifier entry point; no language model or clock-based decision.
exec kenshou attest "$1" --bundle docs/verification
