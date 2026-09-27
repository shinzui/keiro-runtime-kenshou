#!/usr/bin/env bash
set -euo pipefail

project=${1:-cohort/shibuya-current.project}
out=${2:-runs}

cabal --project-file="$project" build -v0 kenshou-shibuya-run
runner=$(cabal --project-file="$project" list-bin kenshou-shibuya-run)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

while IFS= read -r scenario; do
  jq -n --arg scenario "$scenario" \
    '{schema:"kenshou.run-spec/v1",scenario:$scenario,dimensions:{},knobs:{},environment:{placement:"local"}}' \
    > "$scratch/spec.json"
  if output=$("$runner" run "$scratch/spec.json" "$out" 2>&1); then
    path=$(printf '%s\n' "$output" | tail -n 1 | awk '{print $NF}')
    jq -r '[.runId,.scenario,.outcome,(.blocking|tostring),(.knownDefect.status // "-")] | @tsv' "$path/run-result.json"
  else
    printf '%s\n' "$output" >&2
    exit 1
  fi
done < scripts/shibuya-core-metrics-scenarios.txt
