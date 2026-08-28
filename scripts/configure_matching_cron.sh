#!/usr/bin/env bash
# Install the real weekly trigger without hard-coding a privileged key in Git or cron.job. Vault
# keeps the stored value encrypted; the scheduled SQL reads it only when pg_net builds the request.
# The operator dashboard remains the explicit manual trigger and uses the same POST contract.
set -euo pipefail
cd "$(dirname "$0")/.."

# The ordinary project .env already owns the linked Supabase coordinates. Loading it here keeps
# the release command one-step while still allowing CI/operators to provide environment variables
# directly. Values are never printed or written back to disk.
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY}"

command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }

# Keep database credentials out of argv. A caller may provide one direct URI, while the checked-in
# project ref/password pair can derive Supabase's canonical direct host without copying another
# secret-bearing connection string into .env.
if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
  export PGDATABASE="$SUPABASE_DB_URL"
else
  : "${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF when SUPABASE_DB_URL is absent}"
  : "${SUPABASE_DB_PASSWORD:?set SUPABASE_DB_PASSWORD when SUPABASE_DB_URL is absent}"
  export PGHOST="db.${SUPABASE_PROJECT_REF}.supabase.co"
  export PGPORT=5432
  export PGDATABASE=postgres
  export PGUSER=postgres
  export PGPASSWORD="$SUPABASE_DB_PASSWORD"
  export PGSSLMODE=require
fi

# This Mac's psql predates \getenv. Custom session settings carry the two values through the
# process environment (not argv or SQL text), and current_setting reads them only inside the
# encrypted Vault writes below. The values contain no spaces, so libpq's PGOPTIONS tokenization is
# unambiguous.
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c showup.matching_supabase_url=$SUPABASE_URL -c showup.matching_service_key=$SUPABASE_SERVICE_ROLE_KEY"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault;

-- Use update-then-create so rotation is idempotent without deleting a Vault row.
select vault.update_secret(
    id,
    current_setting('showup.matching_supabase_url'),
    'showup_supabase_url',
    'Supabase project origin used by the weekly run-matching pg_net job'
)
from vault.secrets
where name = 'showup_supabase_url';

select vault.create_secret(
    current_setting('showup.matching_supabase_url'),
    'showup_supabase_url',
    'Supabase project origin used by the weekly run-matching pg_net job'
)
where not exists (
    select 1 from vault.secrets where name = 'showup_supabase_url'
);

select vault.update_secret(
    id,
    current_setting('showup.matching_service_key'),
    'showup_service_role_key',
    'Service-role bearer used only by the weekly run-matching pg_net job'
)
from vault.secrets
where name = 'showup_service_role_key';

select vault.create_secret(
    current_setting('showup.matching_service_key'),
    'showup_service_role_key',
    'Service-role bearer used only by the weekly run-matching pg_net job'
)
where not exists (
    select 1 from vault.secrets where name = 'showup_service_role_key'
);

-- Migration 0012 owns the reviewed schedule and credential-free command. Refuse to report success
-- if it was not deployed first; silently creating an ad-hoc second job would reintroduce drift.
do $$
begin
    if not exists (
        select 1 from cron.job
        where jobname = 'showup-weekly-matching'
          and schedule = '0 12 * * 1'
          and command = 'select private.invoke_weekly_matching();'
          and active
    ) then
        raise exception 'migration 0012 weekly matching schedule is not installed';
    end if;
end
$$;
SQL

echo "✓ showup-weekly-matching Vault credentials are installed (Mondays 12:00 UTC)"
