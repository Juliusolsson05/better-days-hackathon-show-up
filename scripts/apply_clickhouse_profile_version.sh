#!/usr/bin/env bash
# Install the profile-submission ordering columns before deploying the Edge Function that writes
# them. `CREATE TABLE IF NOT EXISTS` in 001_schema.sql is a bootstrap, not an upgrade: rerunning it
# against an existing service leaves the old table untouched and makes every new profile submission
# fail only after Postgres has deliberately cleared readiness.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CLICKHOUSE_URL:?set CLICKHOUSE_URL}"
: "${CLICKHOUSE_USER:?set CLICKHOUSE_USER}"
: "${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# curl config keeps the database password out of argv and therefore out of process listings. The
# migration is idempotent, so the same command is correct for both an upgraded and a fresh service.
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

clickhouse_request() {
  curl --silent --show-error --fail \
    --config <(curl_config) \
    --data-binary "$1" \
    "${CLICKHOUSE_URL%/}/?multiquery=1"
}

clickhouse_request "$(<clickhouse/005_profile_vector_version.sql)"

# The ALTER succeeding is not enough evidence when a command was accidentally pointed at another
# database/service. Read back the exact contract the Edge Function depends on before reporting a
# deployable backend.
contract="$(clickhouse_request "
  SELECT count()
  FROM system.columns
  WHERE database = currentDatabase()
    AND table = 'profile_vectors'
    AND ((name = 'submission_id' AND type = 'UUID')
      OR (name = 'updated_at' AND type = 'DateTime64(6)'))
  FORMAT TSVRaw
")"
if [[ "$contract" != "2" ]]; then
  echo "ClickHouse profile_vectors does not expose submission_id + DateTime64(6) updated_at" >&2
  exit 1
fi

echo "✓ ClickHouse profile submission version contract is installed"
