#!/usr/bin/env bash
# Compare only counts, never row content. This is a deployment smoke test rather than an audit:
# source commits may race the two reads, so a short bounded retry distinguishes normal CDC lag
# from a stopped/broken pipe without pretending the databases share a transaction.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF}"
: "${SUPABASE_DB_PASSWORD:?set SUPABASE_DB_PASSWORD}"
: "${CLICKHOUSE_URL:?set CLICKHOUSE_URL}"
: "${CLICKHOUSE_USER:?set CLICKHOUSE_USER}"
: "${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD}"

command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

export PGHOST="db.${SUPABASE_PROJECT_REF}.supabase.co"
export PGPORT=5432
export PGDATABASE=postgres
export PGUSER=postgres
export PGPASSWORD="$SUPABASE_DB_PASSWORD"

escape_curl_config() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

curl_config() {
  printf 'user = "%s:%s"\n' \
    "$(escape_curl_config "$CLICKHOUSE_USER")" \
    "$(escape_curl_config "$CLICKHOUSE_PASSWORD")"
}

clickhouse_scalar() {
  local sql="$1"
  curl --silent --show-error --fail \
    --config <(curl_config) \
    --data-binary "$sql FORMAT TSVRaw" \
    "${CLICKHOUSE_URL%/}/"
}

tables=(
  profiles groups group_members rsvps messages venue_options venue_votes reflections
  attendance_votes contact_selections
)
attempts="${CDC_VERIFY_ATTEMPTS:-10}"
interval="${CDC_VERIFY_INTERVAL_SECONDS:-3}"

for ((attempt = 1; attempt <= attempts; attempt++)); do
  mismatches=()
  for table in "${tables[@]}"; do
    pg_count="$(psql -X -Atc "select count(*) from public.${table}")"
    ch_count="$(clickhouse_scalar \
      "select count() from cdc_${table} final where _peerdb_is_deleted = 0")"
    if [[ "$pg_count" != "$ch_count" ]]; then
      mismatches+=("${table}:postgres=${pg_count},clickhouse=${ch_count}")
    fi
  done

  if (( ${#mismatches[@]} == 0 )); then
    echo "✓ all ten CDC tables match Postgres current-state counts"
    exit 0
  fi

  if (( attempt < attempts )); then
    sleep "$interval"
  fi
done

printf 'CDC did not converge within %s attempts:\n' "$attempts" >&2
printf '  %s\n' "${mismatches[@]}" >&2
exit 1
