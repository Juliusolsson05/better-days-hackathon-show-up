#!/usr/bin/env bash
# Install the semantic layer only after ClickPipes has created its managed cdc_* tables. Keeping
# views outside the base ClickHouse schema is deliberate: 001_schema.sql must still bootstrap an
# empty service before a remote Postgres source or replication slot exists.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CLICKHOUSE_URL:?set CLICKHOUSE_URL}"
: "${CLICKHOUSE_USER:?set CLICKHOUSE_USER}"
: "${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD}"

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

curl --silent --show-error --fail \
  --config <(curl_config) \
  --data-binary @clickhouse/004_cdc_views.sql \
  "${CLICKHOUSE_URL%/}/?multiquery=1"

echo "✓ ClickHouse CDC current-state views are installed"
