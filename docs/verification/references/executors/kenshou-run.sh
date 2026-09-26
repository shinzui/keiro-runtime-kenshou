#!/usr/bin/env bash
set -euo pipefail

# Reproduce a run from its saved run specification.
exec kenshou run "$1" --out "$2"
