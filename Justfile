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
verify: process-compose-check fmt-check haskell-build haskell-test link-proof cohort-assert-released cohort-check graph-check adr-validate schemas-check selftest

[group('verification')]
graph-check:
    cabal run -v0 kenshou -- plan --graph-check

[group('docs')]
adr-validate:
    okf validate docs/adr --strict \
      --profile docs/adr/profile.dhall \
      --profile-enforce \
      --log-enforce

[group('verification')]
schemas-check:
    check-jsonschema --schemafile schemas/component-graph.v1.schema.json kenshou-core/data/components.json
    check-jsonschema --schemafile schemas/run-plan.v1.schema.json kenshou-core/test/golden/run-plan.minimal.json
    check-jsonschema --schemafile schemas/plan-summary.v1.schema.json kenshou-core/test/golden/plan-summary.minimal.json
    check-jsonschema --schemafile schemas/suite.v1.schema.json suites/*.json
    check-jsonschema --schemafile schemas/run-spec-v1.schema.json kenshou-core/test/golden/run-spec.minimal.json kenshou-core/test/golden/run-spec.effective.json kenshou-core/test/golden/run-spec.external.json
    check-jsonschema --schemafile schemas/run-result-v1.schema.json kenshou-core/test/golden/run-result.passed.json kenshou-core/test/golden/run-result.known-defect.json
    check-jsonschema --schemafile schemas/artifact-manifest-v1.schema.json kenshou-core/test/golden/manifest.json
    check-jsonschema --schemafile schemas/comparison-policy-v1.schema.json policies/*.json
    check-jsonschema --schemafile schemas/scenario-list-v1.schema.json kenshou-core/test/golden/scenario-list.json
    jq -c . kenshou-core/test/golden/worker-messages.jsonl | while IFS= read -r line; do printf '%s\n' "$line" | check-jsonschema --schemafile schemas/worker-message-v1.schema.json -; done
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" list --json > "$tmpdir/scenario-list.json"; "$K" run selftest/kernel/correctness/always-pass --out "$tmpdir/runs" >/dev/null; rundir=$(find "$tmpdir/runs" -mindepth 1 -maxdepth 1 -type d | head -1); check-jsonschema --schemafile schemas/scenario-list-v1.schema.json "$tmpdir/scenario-list.json"; check-jsonschema --schemafile schemas/run-spec-v1.schema.json "$rundir/run-spec.json"; check-jsonschema --schemafile schemas/run-result-v1.schema.json "$rundir/run-result.json"; check-jsonschema --schemafile schemas/artifact-manifest-v1.schema.json "$rundir/manifest.json"

[group('verification')]
selftest:
    tmpdir=$(mktemp -d); trap 'rm -rf -- "$tmpdir"' EXIT; K=$(cabal list-bin kenshou); "$K" run selftest/kernel/correctness/always-pass --out "$tmpdir"; "$K" run selftest/kernel/correctness/outcome --out "$tmpdir"; "$K" run selftest/kernel/correctness/known-defect --out "$tmpdir"; "$K" run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=fsync-off --out "$tmpdir"; "$K" run selftest/kernel/correctness/postgres-roundtrip --dim pg.durability=durable --out "$tmpdir"; "$K" run selftest/kernel/concurrency/worker-echo --out "$tmpdir"; set +e; "$K" run selftest/kernel/correctness/always-fail --out "$tmpdir"; fail=$?; "$K" run selftest/kernel/correctness/errors --out "$tmpdir"; errored=$?; set -e; test "$fail" = 1; test "$errored" = 4

[group('haskell')]
haskell-build:
    cabal build all

[group('haskell')]
haskell-test:
    cabal test kenshou-core:tests
    cabal test kenshou-cli:test:kenshou-cli-test

[group('haskell')]
link-proof:
    cabal test kenshou-cli:test:kenshou-linkproof

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
