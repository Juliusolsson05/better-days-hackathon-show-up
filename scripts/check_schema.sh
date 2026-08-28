#!/usr/bin/env bash
# Prove the product migration on top of the currently applied local baseline, then roll it back.
#
# `supabase db lint` can catch malformed SQL but not cross-table product rules. These assertions
# deliberately try the dangerous writes: a venue option, attendance subject, or selected contact
# from another group must fail even when the writer bypasses RLS as the database owner.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMA_TEST_DB_URL="${SHOWUP_SCHEMA_TEST_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

# The check runs DDL and test rows inside a rollback, but refusing an accidental remote target is
# still worth the guard: a dropped connection after BEGIN is safe, while operator confusion about
# which project is under test is not.
if [[ "$SCHEMA_TEST_DB_URL" != *"127.0.0.1"* && "$SCHEMA_TEST_DB_URL" != *"localhost"* ]]; then
  echo "refusing non-local schema test database: set SHOWUP_SCHEMA_TEST_DB_URL to a local clone"
  exit 1
fi

command -v psql >/dev/null || { echo "psql is required"; exit 1; }

SCHEMA_STATE="$(psql "$SCHEMA_TEST_DB_URL" -X -Atc \
  "select case
     when exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='groups'
                    and column_name='seed_distance') then '0003'
     when exists (select 1 from information_schema.tables
                  where table_schema='public' and table_name='attendance_votes') then '0002'
     when exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='groups'
                    and column_name='cohesion') then '0001'
     else 'unknown'
   end")"

if [[ "$SCHEMA_STATE" == "0001" ]]; then
  # Before the migration is applied locally, reproduce the repository's old documented manual
  # Storage setup. This catches policies and legacy URL rows that a pristine schema never had.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/tests/0001_documented_upgrade_fixture.sql \
    -f supabase/migrations/0002_after_meetup.sql \
    -f supabase/migrations/0003_product_contracts.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0002" ]]; then
  # This is the production upgrade path: 0002's after-meetup tables exist, but the wider
  # lifecycle contract does not. Prove 0003 strengthens that deployed shape in place.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0003_product_contracts.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0003" ]]; then
  # After local db reset has applied every migration, reapplying forward-only DDL would be a
  # false failure. The behavioral assertions still run against the installed contract.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/tests/0002_product_contracts.sql \
    -c 'rollback'
else
  echo "local database is not a recognized 0001, 0002, or 0003 Show Up schema"
  exit 1
fi
