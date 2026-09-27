#!/usr/bin/env bash
set -euo pipefail

out=${1:-runs}

if [[ -n $(git status --porcelain) ]]; then
  printf 'run the cohort sweep from a clean worktree\n' >&2
  exit 2
fi

cabal build -v0 kenshou
runner=$(cabal list-bin kenshou)

while IFS= read -r scenario; do
  if output=$("$runner" run "$scenario" --out "$out" 2>&1); then
    path=$(printf '%s\n' "$output" | tail -n 1 | awk '{print $NF}')
    jq -r '[.runId,.scenario,.outcome,(.blocking|tostring),(.knownDefect.status // "-")] | @tsv' "$path/run-result.json"
  else
    printf '%s\n' "$output" >&2
    exit 1
  fi
done < scripts/shibuya-core-metrics-scenarios.txt
