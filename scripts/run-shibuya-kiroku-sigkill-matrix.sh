#!/usr/bin/env bash
set -euo pipefail

project_file="${1:-cabal.project}"
spec_dir=".tmp/kiroku-sigkill-matrix"
mkdir -p "$spec_dir"

for pg_version in 17 18; do
  for phase in catch-up live; do
    for target in category all-streams; do
      for batch_size in 1 10 100; do
        spec="$spec_dir/$pg_version-$phase-$target-$batch_size.json"
        jq --arg pg "$pg_version" --arg phase "$phase" --arg target "$target" --argjson batch "$batch_size" \
          '.dimensions["pg.version"] = $pg | .knobs = {"kiroku-adapter.phase": $phase, "kiroku-adapter.target": $target, "kiroku-adapter.batch-size": $batch}' \
          specs/shibuya-kiroku-sigkill-pg18.json > "$spec"
        printf '%s %s %s batch=%s: ' "$pg_version" "$phase" "$target" "$batch_size"
        timeout -k 5 220 cabal --project-file="$project_file" -v0 run kenshou-shibuya-run -- run "$spec" runs
      done
    done
  done
  printf '%s random catch-up category batch=10: ' "$pg_version"
  timeout -k 5 220 cabal --project-file="$project_file" -v0 run kenshou-shibuya-run -- run "specs/shibuya-kiroku-sigkill-random-pg$pg_version.json" runs
done
