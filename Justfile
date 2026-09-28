set shell := ["zsh", "-cu"]

pg_host := env_var_or_default("PGHOST", "db")
pg_data := env_var_or_default("PGDATA", "db/db")
pg_log := env_var_or_default("PGLOG", "db/postgres.log")
pg_user := env_var_or_default("PGUSER", `whoami`)
pg_database := env_var_or_default("PGDATABASE", "kenshou")

[group('meta')]
default:
    just --list

[group('meta')]
verify: process-compose-check fmt-check haskell-build haskell-test link-proof cohort-assert-released cohort-check graph-check adr-validate terminology-validate evidence-validate evidence-index-check evidence-profile-test evidence-check schemas-check selftest

[group('verification')]
graph-check:
    cabal run -v0 kenshou -- plan --graph-check

[group('payload')]
payload-lock cohort:
    bash scripts/payload-lock.sh {{cohort}}

[group('payload')]
payload-check cohort:
    @tmp=$(mktemp); trap 'rm -f -- "$tmp"' EXIT; system=${KENSHOU_PAYLOAD_SYSTEM:-$(nix eval --raw --impure --expr builtins.currentSystem)}; nix eval --json ".#packages.$system.kenshou-{{cohort}}.cohortIdentity" > "$tmp"; check-jsonschema --schemafile schemas/kenshou.cohort-identity.v1.schema.json "$tmp"; cabal run -v0 kenshou -- cohort check --descriptor cohort/{{cohort}}.json --identity "$tmp"

[group('docs')]
adr-validate:
    okf validate docs/adr --strict \
      --profile docs/adr/profile.dhall \
      --profile-enforce \
      --log-enforce

[group('docs')]
terminology-validate:
    okf validate docs/terminology --strict \
      --profile mori/terminology-profile.dhall \
      --profile-enforce \
      --log-enforce

[group('verification')]
evidence-validate:
    okf validate docs/verification --strict \
      --profile docs/verification/profile.dhall \
      --profile-enforce \
      --log-enforce

[group('verification')]
evidence-index-check:
    okf index docs/verification --write
    git diff --exit-code -- docs/verification

[group('verification')]
evidence-profile-test:
    bash scripts/test-verification-profile.sh

[group('verification')]
evidence-check:
    cabal run -v0 kenshou -- evidence check
    bash scripts/test-evidence-cli-surface.sh

[group('verification')]
schemas-check:
    for fixture in kenshou-remote/test/golden/cell/cell.*.v1.json; do schema="${fixture%.json}.schema.json"; check-jsonschema --base-uri "file://$PWD/$schema" --schemafile "$schema" "$fixture" || exit; done
    check-jsonschema --schemafile schemas/kenshou.cohort-identity.v1.schema.json kenshou-core/test/fixtures/cohort-identity.golden.json
    check-jsonschema --schemafile schemas/kenshou.payload.v1.schema.json kenshou-remote/test/golden/payload.json
    check-jsonschema --schemafile schemas/kenshou.payload-identity.v1.schema.json kenshou-remote/test/golden/payload-identity.json
    for lock in nix/cohort-locks/*.lock.json; do check-jsonschema --schemafile schemas/kenshou.cohort-nix-lock.v1.schema.json "$lock" || exit; done
    check-jsonschema --schemafile schemas/kenshou.cell-run.v1.schema.json kenshou-remote/test/golden/cell-run.json
    check-jsonschema --schemafile schemas/kenshou.cell-session.v1.schema.json kenshou-remote/test/golden/cell-session.json
    check-jsonschema --schemafile schemas/kenshou.cell-capabilities.v1.schema.json kenshou-remote/test/golden/cell-capabilities.json
    check-jsonschema --schemafile schemas/kenshou.cell-route.v1.schema.json kenshou-remote/test/golden/cell-route.json
    check-jsonschema --schemafile schemas/kenshou.cell-routing.v1.schema.json policies/cell-routing.json
    check-jsonschema --schemafile schemas/kenshou.cell-session.v1.schema.json kenshou-remote/test/golden/cell-session.json
    check-jsonschema --schemafile schemas/component-graph.v1.schema.json kenshou-core/data/components.json
    check-jsonschema --schemafile schemas/run-plan.v1.schema.json kenshou-core/test/golden/run-plan.minimal.json
    check-jsonschema --schemafile schemas/plan-summary.v1.schema.json kenshou-core/test/golden/plan-summary.minimal.json
    check-jsonschema --schemafile schemas/suite.v1.schema.json suites/*.json
    check-jsonschema --schemafile schemas/run-spec-v1.schema.json kenshou-core/test/golden/run-spec.minimal.json kenshou-core/test/golden/run-spec.effective.json kenshou-core/test/golden/run-spec.external.json
    check-jsonschema --schemafile schemas/run-result-v1.schema.json kenshou-core/test/golden/run-result.passed.json kenshou-core/test/golden/run-result.known-defect.json
    check-jsonschema --schemafile schemas/artifact-manifest-v1.schema.json kenshou-core/test/golden/manifest.json
    check-jsonschema --schemafile schemas/comparison-policy-v1.schema.json policies/default.json policies/selftest.json
    check-jsonschema --schemafile schemas/overhead-policy-v1.schema.json policies/telemetry-overhead.json
    check-jsonschema --schemafile schemas/overhead-report-v1.schema.json kenshou-telemetry/test/golden/overhead-report.minimal.json
    check-jsonschema --schemafile schemas/health-notice-v1.schema.json kenshou-measure/test/fixtures/health-notice.json
    check-jsonschema --schemafile schemas/diagnosis.v1.schema.json kenshou-diagnose/test/golden/leak-diagnosis.json
    check-jsonschema --schemafile schemas/leak-policy.v1.schema.json policies/leak-default.json
    check-jsonschema --schemafile schemas/scenario-list-v1.schema.json kenshou-core/test/golden/scenario-list.json
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" evidence check --json > "$tmpdir/evidence-check.json"; check-jsonschema --schemafile schemas/evidence-check-v1.schema.json "$tmpdir/evidence-check.json"
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" history --scenario selftest/kernel/correctness/always-pass --json > "$tmpdir/evidence-history.json"; check-jsonschema --schemafile schemas/evidence-history-v1.schema.json "$tmpdir/evidence-history.json"
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" attest invalid --project fixture --json > "$tmpdir/attest-result.json" || test "$?" = 2; check-jsonschema --schemafile schemas/attest-result-v1.schema.json "$tmpdir/attest-result.json"
    jq -c . kenshou-core/test/golden/worker-messages.jsonl | while IFS= read -r line; do printf '%s\n' "$line" | check-jsonschema --schemafile schemas/worker-message-v1.schema.json -; done
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" list --json > "$tmpdir/scenario-list.json"; "$K" run selftest/kernel/correctness/always-pass --out "$tmpdir/runs" >/dev/null; rundir=$(find "$tmpdir/runs" -mindepth 1 -maxdepth 1 -type d | head -1); check-jsonschema --schemafile schemas/scenario-list-v1.schema.json "$tmpdir/scenario-list.json"; check-jsonschema --schemafile schemas/run-spec-v1.schema.json "$rundir/run-spec.json"; check-jsonschema --schemafile schemas/run-result-v1.schema.json "$rundir/run-result.json"; check-jsonschema --schemafile schemas/artifact-manifest-v1.schema.json "$rundir/manifest.json"
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" run selftest/check/correctness/ledger-detects-loss-dup-reorder --set ledger.facts=1000 --out "$tmpdir" >/dev/null; rundir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1); check-jsonschema --schemafile schemas/kenshou.verdict.v1.schema.json "$rundir"/verdicts/*.json; jq '{"$schema": .["$schema"], "type": "array", "items": .}' schemas/kenshou.ledger-fact.v1.schema.json > "$tmpdir/ledger-array.schema.json"; jq -s 'map(select(.schema == "kenshou.ledger-fact/v1"))' "$rundir"/verdicts/ledger/*.jsonl > "$tmpdir/ledger-facts.json"; check-jsonschema --schemafile "$tmpdir/ledger-array.schema.json" "$tmpdir/ledger-facts.json"

[group('verification')]
selftest:
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" run selftest/kernel/correctness/always-pass --out "$tmpdir"; "$K" run selftest/kernel/correctness/outcome --out "$tmpdir"; "$K" run selftest/kernel/correctness/known-defect --out "$tmpdir"; "$K" run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=fsync-off --out "$tmpdir"; "$K" run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=durable --out "$tmpdir"; "$K" run selftest/kernel/concurrency/worker-echo --out "$tmpdir"; set +e; "$K" run selftest/kernel/correctness/always-fail --out "$tmpdir"; fail=$?; "$K" run selftest/kernel/correctness/errors --out "$tmpdir"; errored=$?; set -e; test "$fail" = 1; test "$errored" = 4
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" run selftest/check/correctness/ledger-detects-loss-dup-reorder --set ledger.facts=1000 --out "$tmpdir"; "$K" run selftest/check/concurrency/kill-and-restart-worker --set kill.count=2 --out "$tmpdir"; "$K" run selftest/check/concurrency/postgres-backend-kill --dim pg.durability=fsync-off --out "$tmpdir"; "$K" run selftest/check/concurrency/postgres-backend-kill --dim pg.durability=durable --out "$tmpdir"; "$K" run selftest/check/concurrency/proxy-partition --out "$tmpdir"; "$K" run selftest/check/correctness/model-replays-counterexample --set model.tests=20 --out "$tmpdir"

[group('haskell')]
haskell-build:
    cabal build all

[group('haskell')]
haskell-test:
    cabal test kenshou-core:tests
    cabal test kenshou-remote:test:kenshou-remote-test
    cabal test kenshou-measure:test:kenshou-measure-test
    cabal test kenshou-check:test:kenshou-check-test
    cabal test kenshou-diagnose:test:kenshou-diagnose-test
    cabal test kenshou-cli:test:kenshou-cli-test
    cabal test kenshou-evidence:test:kenshou-evidence-test

[group('haskell')]
link-proof:
    cabal test kenshou-cli:test:kenshou-linkproof

[group('diagnostics')]
diagnose-build-info-table:
    cabal --project-file=cabal.diagnose-info-table.project --builddir=dist-diagnose/info-table build kenshou-cli:exe:kenshou

[group('diagnostics')]
diagnose-build-profiled:
    cabal --project-file=cabal.diagnose-profiled.project --builddir=dist-diagnose/profiled build kenshou-cli:exe:kenshou

[group('diagnostics')]
diagnose-tools:
    mkdir -p .dev/bin
    cabal install --ignore-project --installdir=.dev/bin --install-method=copy --overwrite-policy=always eventlog2html-0.12.0
    cabal install --ignore-project --installdir=.dev/bin --install-method=copy --overwrite-policy=always ghc-events-0.21.0.0

[group('format')]
fmt:
    nix fmt

[group('format')]
fmt-check:
    nix fmt -- --fail-on-change

[group('cohort')]
cohort-show:
    cabal run -v0 kenshou -- cohort show

[group('cohort')]
cohort-check:
    cabal run -v0 kenshou -- cohort check

[group('cohort')]
cohort-assert-released:
    test "$(cat cohort/active.project)" = "import: released.project"

[group('cohort')]
use-cohort name:
    test -f "cohort/{{name}}.project" && test -f "cohort/{{name}}.json"
    printf 'import: %s.project\n' "{{name}}" > cohort/active.project
    rm -f dist-newstyle/cache/config dist-newstyle/cache/plan.json
    @echo "active cohort: {{name}} (run cabal build all, then just cohort-check)"

[group('database')]
postgres-init:
    mkdir -p "{{pg_host}}" .dev
    if [ ! -d "{{pg_data}}" ]; then PGDATA="{{pg_data}}" initdb --auth=trust --no-locale --encoding=UTF8; fi

[group('database')]
postgres-start: postgres-init
    pg_ctl status -D "{{pg_data}}" >/dev/null || pg_ctl start -w -D "{{pg_data}}" -l "{{pg_log}}" -o "--unix_socket_directories='{{pg_host}}'" -o "-c listen_addresses=''"

[group('database')]
postgres-stop:
    pg_ctl stop -D "{{pg_data}}"

[group('database')]
process-compose:
    PGHOST="{{pg_host}}" PGDATA="{{pg_data}}" PGLOG="{{pg_log}}" PGUSER="{{pg_user}}" PGDATABASE="{{pg_database}}" process-compose up -f process-compose.yaml

[group('database')]
process-compose-check:
    PGHOST="{{pg_host}}" PGDATA="{{pg_data}}" PGLOG="{{pg_log}}" PGUSER="{{pg_user}}" PGDATABASE="{{pg_database}}" process-compose -f process-compose.yaml --dry-run

[group('database')]
create-database db=pg_database:
    PGHOST="{{pg_host}}" createdb "{{db}}" 2>/dev/null || PGHOST="{{pg_host}}" psql -d "{{db}}" -Atqc 'SELECT 1' >/dev/null

[group('database')]
db-create db=pg_database: postgres-start
    just create-database "{{db}}"
