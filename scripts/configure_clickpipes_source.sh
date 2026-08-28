#!/usr/bin/env bash
# Create the least-privileged Supabase login that ClickPipes uses for its initial snapshot and
# logical stream. The password arrives only through the environment and psql receives both
# credentials as environment variables, so neither secret appears in the process argument list.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SUPABASE_DB_PASSWORD:?set SUPABASE_DB_PASSWORD for the hosted postgres admin}"
: "${CLICKPIPES_POSTGRES_PASSWORD:?set a dedicated ClickPipes database password}"

if [[ -z "${CLICKPIPES_SOURCE_HOST:-}" ]]; then
  : "${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF or CLICKPIPES_SOURCE_HOST}"
  CLICKPIPES_SOURCE_HOST="db.${SUPABASE_PROJECT_REF}.supabase.co"
fi
CLICKPIPES_SOURCE_PORT="${CLICKPIPES_SOURCE_PORT:-5432}"
if [[ "${CLICKPIPES_SOURCE_HOST,,}" == *pooler* || "$CLICKPIPES_SOURCE_PORT" != "5432" ]]; then
  echo "ClickPipes requires the direct Postgres host on port 5432, never the Supabase pooler" >&2
  exit 1
fi

if (( ${#CLICKPIPES_POSTGRES_PASSWORD} < 24 )); then
  echo "CLICKPIPES_POSTGRES_PASSWORD must contain at least 24 characters" >&2
  exit 1
fi

command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }

# The Supabase pooler speaks ordinary SQL but cannot expose the replication protocol. Deriving the
# direct host from the project ref removes a dangerous operator choice from the deployment path.
export PGHOST="$CLICKPIPES_SOURCE_HOST"
export PGPORT="$CLICKPIPES_SOURCE_PORT"
export PGDATABASE=postgres
export PGUSER=postgres
export PGPASSWORD="$SUPABASE_DB_PASSWORD"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'clickpipes_user') then
        raise exception 'run migration 0005_clickhouse_cdc before configuring ClickPipes';
    end if;
end
$$;

alter role clickpipes_user with login replication bypassrls;

-- \getenv keeps the password out of this SQL file and \gexec quotes it as a SQL literal instead
-- of treating punctuation from a generated secret as executable syntax.
\getenv clickpipes_password CLICKPIPES_POSTGRES_PASSWORD
select format('alter role clickpipes_user password %L', :'clickpipes_password') \gexec

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'show_up_clickhouse') then
        raise exception 'run migration 0005_clickhouse_cdc before configuring ClickPipes';
    end if;
end
$$;
SQL

echo "✓ dedicated ClickPipes source login is configured on the direct Supabase database"
