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
     when to_regprocedure('private.invoke_weekly_matching()') is not null then '0012'
     when to_regprocedure(
          'public.complete_profile_submission(uuid,uuid,timestamp with time zone)'
        ) is not null then '0011'
     when to_regprocedure('public.was_marked_no_show(uuid)') is not null then '0010'
     when to_regprocedure('public.submit_reflection(uuid,text,boolean)') is not null
          and not has_table_privilege('authenticated', 'public.profiles', 'update') then '0009'
     when to_regprocedure('public.submit_reflection(uuid,text,boolean)') is not null then '0008'
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

# Build one ordered replay instead of maintaining nine almost-identical psql commands. The rank is
# explicit rather than parsed as a number because Bash treats leading-zero values as octal, making
# 0008 and 0009 invalid arithmetic exactly when those release migrations need testing most.
case "$SCHEMA_STATE" in
  0001) SCHEMA_RANK=1 ;;
  0002) SCHEMA_RANK=2 ;;
  0003) SCHEMA_RANK=3 ;;
  0004) SCHEMA_RANK=4 ;;
  0005) SCHEMA_RANK=5 ;;
  0006) SCHEMA_RANK=6 ;;
  0007) SCHEMA_RANK=7 ;;
  0008) SCHEMA_RANK=8 ;;
  0009) SCHEMA_RANK=9 ;;
  0010) SCHEMA_RANK=10 ;;
  0011) SCHEMA_RANK=11 ;;
  0012) SCHEMA_RANK=12 ;;
  *)
    echo "local database is not a recognized 0001 through 0012 Show Up schema"
    exit 1
    ;;
esac

PSQL_FILES=()

if (( SCHEMA_RANK == 1 )); then
  # A clean 0001 schema omits the public Storage policy operators historically created by hand.
  # Reproducing it before the upgrade proves later privacy migrations remove the dangerous live
  # shape, not merely that their desired state works on a pristine reset.
  PSQL_FILES+=(-f supabase/tests/0001_documented_upgrade_fixture.sql)
fi
if (( SCHEMA_RANK < 2 )); then PSQL_FILES+=(-f supabase/migrations/0002_after_meetup.sql); fi
if (( SCHEMA_RANK < 3 )); then PSQL_FILES+=(-f supabase/migrations/0003_product_contracts.sql); fi
if (( SCHEMA_RANK < 4 )); then PSQL_FILES+=(-f supabase/migrations/0004_chat.sql); fi
if (( SCHEMA_RANK < 5 )); then PSQL_FILES+=(-f supabase/migrations/0005_production_lifecycle.sql); fi
if (( SCHEMA_RANK < 6 )); then PSQL_FILES+=(-f supabase/migrations/0006_waitlist.sql); fi

# origin/main owns CDC as 0007 after the migration-history reconciliation. This worktree may be
# inspected before those upstream files are merged, so include the CDC migration and its contract
# whenever present without replacing or re-expressing their behavior here. Once present, omitting
# them from an earlier-state replay would falsely certify a schema that cannot match production.
if [[ -f supabase/migrations/0007_clickhouse_cdc.sql ]] && (( SCHEMA_RANK < 7 )); then
  PSQL_FILES+=(-f supabase/migrations/0007_clickhouse_cdc.sql)
fi
if (( SCHEMA_RANK < 8 )); then PSQL_FILES+=(-f supabase/migrations/0008_reflection_submission.sql); fi
if (( SCHEMA_RANK < 9 )); then PSQL_FILES+=(-f supabase/migrations/0009_profile_write_boundary.sql); fi
if (( SCHEMA_RANK < 10 )); then PSQL_FILES+=(-f supabase/migrations/0010_post_meetup_write_boundary.sql); fi
if (( SCHEMA_RANK < 11 )); then PSQL_FILES+=(-f supabase/migrations/0011_profile_submission_version.sql); fi
if (( SCHEMA_RANK < 12 )); then PSQL_FILES+=(-f supabase/migrations/0012_weekly_matching_cron.sql); fi

# Every suite runs against the final in-transaction shape. Older tests protect invariants shared by
# later migrations, while 0008/0009 specifically exercise the two write doors that moved behind
# server-owned RPC/service-role boundaries.
PSQL_FILES+=(
  -f supabase/tests/0002_product_contracts.sql
  -f supabase/tests/0004_chat.sql
  -f supabase/tests/0005_production_lifecycle.sql
)
if [[ -f supabase/tests/0007_clickhouse_cdc.sql ]]; then
  PSQL_FILES+=(-f supabase/tests/0007_clickhouse_cdc.sql)
fi
PSQL_FILES+=(
  -f supabase/tests/0008_reflection_submission.sql
  -f supabase/tests/0009_profile_write_boundary.sql
  -f supabase/tests/0010_post_meetup_write_boundary.sql
  -f supabase/tests/0011_profile_submission_version.sql
  -f supabase/tests/0012_weekly_matching_cron.sql
)

psql "$SCHEMA_TEST_DB_URL" -X -q -v ON_ERROR_STOP=1 \
  -c 'begin' \
  "${PSQL_FILES[@]}" \
  -c 'rollback'
