#!/usr/bin/env bash
# Type-check every edge function.
#
# This exists because nothing else in the repo does it. Supabase deploys by bundling, not by
# compiling, so a call to a method that does not exist on the SDK ships happily and fails at
# runtime inside a request -- which is how `client.messages.parse` (correct in a newer SDK,
# absent in the pinned 0.71.0) sat in submit-profile and run-matching without anyone noticing.
#
#   brew install deno && ./scripts/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v deno >/dev/null || { echo "deno not installed: brew install deno"; exit 1; }

# embedding_mean holds BOTH the profile and venue centroids. A global truncate here once
# erased the only state required to interpret the already-loaded venue vectors, so keep this
# cheap static tripwire beside the checks everyone runs before deploy. This deliberately
# checks the dangerous operation, not formatting around the safe keyed replacement.
if grep -Eiq 'TRUNCATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+EXISTS)?[[:space:]]+embedding_mean' \
    clickhouse/002_seed.sql; then
  echo 'clickhouse/002_seed.sql must never truncate the shared embedding_mean table'
  exit 1
fi

# _shared/* is checked transitively through the functions that import it, but list it anyway
# so a shared module with no importer yet still gets checked.
deno check \
  supabase/functions/_shared/*.ts \
  supabase/functions/*/index.ts

# --allow-env because clickhouse.ts reads its secrets at module load; the tests populate
# dummy values. Nothing here touches the network.
exec deno test --allow-env --quiet supabase/functions/_shared/
