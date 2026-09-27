#!/usr/bin/env bash
set -euo pipefail

cabal build -v0 kenshou
binary=$(cabal list-bin kenshou)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

for shell in bash zsh fish; do
  script=$("$binary" completions "$shell")
  printf '%s\n' "$script" | grep -Fq -- '--bash-completion-word'
  completion_flags=()
  if [[ "$shell" != bash ]]; then
    printf '%s\n' "$script" | grep -Fq -- '--bash-completion-enriched'
    completion_flags+=(--bash-completion-enriched)
  fi

  query_completion() {
    local index=$1
    shift
    local arguments=("${completion_flags[@]}" --bash-completion-index "$index")
    for word in "$@"; do
      arguments+=(--bash-completion-word "$word")
    done
    "$binary" "${arguments[@]}" | cut -f1
  }

  query_completion 1 kenshou '' > "$scratch/top"
  for command in record attest evidence history; do
    grep -Fxq -- "$command" "$scratch/top"
  done

  query_completion 2 kenshou record '' > "$scratch/record"
  for flag in --comparison --bundle --project --data-base-uri --purpose --json; do
    grep -Fxq -- "$flag" "$scratch/record"
  done

  query_completion 2 kenshou attest '' > "$scratch/attest"
  for flag in --bundle --project --offline --linked-only --accept-anomaly --json; do
    grep -Fxq -- "$flag" "$scratch/attest"
  done

  query_completion 2 kenshou history '' > "$scratch/history"
  for flag in --scenario --cohort-component --confirmed-only --json; do
    grep -Fxq -- "$flag" "$scratch/history"
  done

  query_completion 2 kenshou evidence '' > "$scratch/evidence"
  grep -Fxq -- check "$scratch/evidence"
  query_completion 3 kenshou evidence check '' > "$scratch/check"
  for flag in --bundle --network --deep --json; do
    grep -Fxq -- "$flag" "$scratch/check"
  done
  echo "$shell: evidence completions present"
done

"$binary" record --help > "$scratch/record-help"
for group in 'Record source' Configuration 'Evidence destination' Verification Output; do
  grep -Fxq -- "$group" "$scratch/record-help"
done
"$binary" attest --help > "$scratch/attest-help"
for group in 'Evidence source' Recomputation 'Anomaly acceptance' Output; do
  grep -Fxq -- "$group" "$scratch/attest-help"
done
"$binary" history --help > "$scratch/history-help"
for group in Configuration 'Scenario filters' 'Trust filters' Output; do
  grep -Fxq -- "$group" "$scratch/history-help"
done

"$binary" help evidence --width 80 > "$scratch/help-80"
awk 'length($0) > 80 { print "help line exceeds 80 columns: " NR > "/dev/stderr"; exit 1 }' "$scratch/help-80"
cmp kenshou-cli/test/golden/help-evidence-80.txt "$scratch/help-80"
"$binary" help evidence > "$scratch/help-default-first"
"$binary" help evidence > "$scratch/help-default-second"
cmp "$scratch/help-default-first" "$scratch/help-default-second"
echo 'evidence help snapshot and piped default stable'

cp -R docs/verification "$scratch/bundle"
"$binary" run selftest/kernel/correctness/always-pass --out "$scratch/runs" > /dev/null
run_dir=$(find "$scratch/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)
git status --porcelain > "$scratch/status-before"

set +e
"$binary" record "$run_dir" --bundle "$scratch/bundle" --store-root "$scratch/store" \
  --data-base-uri file:///tmp/x --purpose investigation --allow-dirty --json \
  > "$scratch/invalid-uri.json" 2> "$scratch/invalid-uri.stderr"
invalid_code=$?
set -e
test "$invalid_code" = 2
jq -e '.exitCode == 2 and .status == "error"' "$scratch/invalid-uri.json" > /dev/null
check-jsonschema --schemafile schemas/record-result-v1.schema.json "$scratch/invalid-uri.json"
grep -Fq -- 'gs://BUCKET/PREFIX' "$scratch/invalid-uri.stderr"

"$binary" record "$run_dir" --bundle "$scratch/bundle" --store-root "$scratch/store" \
  --data-base-uri gs://fixture-bucket/runs --purpose investigation --allow-dirty --json \
  > "$scratch/record.json" 2> "$scratch/record.stderr"
jq -e '.schema == "kenshou.record-result/v1" and .status == "ok" and .message == "recorded"' "$scratch/record.json" > /dev/null
check-jsonschema --schemafile schemas/record-result-v1.schema.json "$scratch/record.json"
grep -Fq -- 'warning: --allow-dirty' "$scratch/record.stderr"
"$binary" record "$run_dir" --bundle "$scratch/bundle" --store-root "$scratch/store" \
  --data-base-uri gs://fixture-bucket/runs --purpose investigation --allow-dirty --json \
  > "$scratch/replay.json" 2> "$scratch/replay.stderr"
jq -e '.message == "already recorded"' "$scratch/replay.json" > /dev/null
git status --porcelain > "$scratch/status-after"
cmp "$scratch/status-before" "$scratch/status-after"

run_id=$(basename "$(jq -r '.path' "$scratch/record.json")" .md)
set +e
CI=true "$binary" attest "$run_id" --accept-anomaly --authority human:fixture \
  --reason 'test refusal' --json > "$scratch/ci-refusal.json" 2> "$scratch/ci-refusal.stderr"
ci_code=$?
set -e
test "$ci_code" = 2
jq -e '.exitCode == 2' "$scratch/ci-refusal.json" > /dev/null
check-jsonschema --schemafile schemas/attest-result-v1.schema.json "$scratch/ci-refusal.json"
grep -Fq -- 'CI' "$scratch/ci-refusal.stderr"

printf x >> "$scratch/store/fixture-bucket/runs/$run_id/run-result.json"
set +e
"$binary" attest "$run_id" --bundle "$scratch/bundle" --store-root "$scratch/store" \
  --offline --json > "$scratch/tampered.json" 2> "$scratch/tampered.stderr"
tampered_code=$?
set -e
test "$tampered_code" = 1
jq -e '.exitCode == 1 and .message == "refuted"' "$scratch/tampered.json" > /dev/null
check-jsonschema --schemafile schemas/attest-result-v1.schema.json "$scratch/tampered.json"
"$binary" evidence check --bundle "$scratch/bundle" > "$scratch/check-result"
grep -Fxq -- 'evidence clean' "$scratch/check-result"

record_path="$scratch/bundle/$(jq -r '.path' "$scratch/record.json")"
python3 -c 'from pathlib import Path; import sys; path = Path(sys.argv[1]); contents = path.read_text(); assert "\nrecordKind:" in contents; path.write_text(contents.replace("\nrecordKind:", "\nstatus: stable\nrecordKind:", 1))' "$record_path"
set +e
"$binary" evidence check --bundle "$scratch/bundle" --json \
  > "$scratch/finding.json" 2> "$scratch/finding.stderr"
finding_code=$?
set -e
test "$finding_code" = 1
check-jsonschema --schemafile schemas/evidence-check-v1.schema.json "$scratch/finding.json"
jq -e 'any(.findings[]; .rule == "event-keys")' "$scratch/finding.json" > /dev/null
grep -Fq -- 'event-keys' "$scratch/finding.stderr"
echo 'record replay, URI refusal, CI refusal, tamper verdict, and JSON finding channels passed'
