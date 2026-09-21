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
verify: process-compose-check fmt-check haskell-build haskell-test

[group('haskell')]
haskell-build:
    cabal build all

[group('haskell')]
haskell-test:
    cabal test kenshou-core:tests
    if cabal list --simple-output kenshou-cli 2>/dev/null | rg -q '^kenshou-cli '; then cabal test kenshou-cli:test:kenshou-cli-test; fi

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
