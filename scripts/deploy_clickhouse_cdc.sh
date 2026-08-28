#!/usr/bin/env bash
# One deployment entry point, with planning read-only by default. Applying mutates both hosted
# systems, so it is an explicit mode and performs source setup before provisioning the consumer.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-plan}"
if [[ "$mode" != "plan" && "$mode" != "apply" ]]; then
  echo "usage: $0 [plan|apply]" >&2
  exit 1
fi

: "${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF}"
: "${CLICKPIPES_POSTGRES_PASSWORD:?set CLICKPIPES_POSTGRES_PASSWORD}"
: "${CLICKHOUSE_CLOUD_ORGANIZATION_ID:?set CLICKHOUSE_CLOUD_ORGANIZATION_ID}"
: "${CLICKHOUSE_CLOUD_SERVICE_ID:?set CLICKHOUSE_CLOUD_SERVICE_ID}"
: "${CLICKHOUSE_CLOUD_API_KEY:?set CLICKHOUSE_CLOUD_API_KEY}"
: "${CLICKHOUSE_CLOUD_API_SECRET:?set CLICKHOUSE_CLOUD_API_SECRET}"

export TF_VAR_clickhouse_organization_id="$CLICKHOUSE_CLOUD_ORGANIZATION_ID"
export TF_VAR_clickhouse_service_id="$CLICKHOUSE_CLOUD_SERVICE_ID"
export TF_VAR_postgres_host="db.${SUPABASE_PROJECT_REF}.supabase.co"
export TF_VAR_postgres_password="$CLICKPIPES_POSTGRES_PASSWORD"

terraform -chdir=infra/clickhouse-cdc init

if [[ "$mode" == "plan" ]]; then
  terraform -chdir=infra/clickhouse-cdc plan
  exit 0
fi

: "${SUPABASE_DB_PASSWORD:?apply requires SUPABASE_DB_PASSWORD}"
: "${CLICKHOUSE_URL:?apply requires CLICKHOUSE_URL for semantic views}"
: "${CLICKHOUSE_USER:?apply requires CLICKHOUSE_USER for semantic views}"
: "${CLICKHOUSE_PASSWORD:?apply requires CLICKHOUSE_PASSWORD for semantic views}"

./scripts/configure_clickpipes_source.sh
terraform -chdir=infra/clickhouse-cdc apply
./scripts/apply_clickhouse_cdc_views.sh
./scripts/verify_clickhouse_cdc.sh
