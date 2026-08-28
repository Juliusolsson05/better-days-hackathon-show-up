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
     when exists (select 1 from pg_publication
                  where pubname='show_up_clickhouse') then '0007'
     when exists (select 1 from information_schema.tables
                  where table_schema='public' and table_name='waitlist') then '0006'
     when exists (select 1 from information_schema.tables
                  where table_schema='public' and table_name='after_flow_completions') then '0005'
     when exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='messages'
                    and column_name='client_msg_id') then '0004'
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
    -f supabase/migrations/0004_chat.sql \
    -f supabase/migrations/0005_production_lifecycle.sql \
    -f supabase/migrations/0006_waitlist.sql \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0002" ]]; then
  # This is the production upgrade path: 0002's after-meetup tables exist, but the wider
  # lifecycle contract does not. Prove 0003 strengthens that deployed shape in place.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0003_product_contracts.sql \
    -f supabase/migrations/0004_chat.sql \
    -f supabase/migrations/0005_production_lifecycle.sql \
    -f supabase/migrations/0006_waitlist.sql \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0003" ]]; then
  # Product contracts are present but optimistic chat delivery is not. This is the merge order
  # used when chat hardening follows the wider reconciliation on a deployed database.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0004_chat.sql \
    -f supabase/migrations/0005_production_lifecycle.sql \
    -f supabase/migrations/0006_waitlist.sql \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0004" ]]; then
  # Chat is installed but the durable lifecycle checkpoint is not. Prove the exact deployed
  # 0005/0006 history before adding CDC as 0007.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0005_production_lifecycle.sql \
    -f supabase/migrations/0006_waitlist.sql \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0005" ]]; then
  # Production lifecycle is present but the separately deployed waitlist is not.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0006_waitlist.sql \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0006" ]]; then
  # This is the live pre-CDC state discovered from Supabase migration history. It is the most
  # important upgrade path: only migration 0007 may run against production now.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/migrations/0007_clickhouse_cdc.sql \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
elif [[ "$SCHEMA_STATE" == "0007" ]]; then
  # After local db reset has applied every migration, reapplying forward-only DDL would be a
  # false failure. The behavioral assertions still run against the installed contract.
  psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c 'begin' \
    -f supabase/tests/0002_product_contracts.sql \
    -f supabase/tests/0004_chat.sql \
    -f supabase/tests/0005_production_lifecycle.sql \
    -f supabase/tests/0007_clickhouse_cdc.sql \
    -c 'rollback'
else
  echo "local database is not a recognized 0001 through 0007 Show Up schema"
  exit 1
fi
