#!/usr/bin/env bash
# One gate for the three runtimes that make up Show Up.
#
# Supabase deploy bundles TypeScript without proving SDK method signatures, Flutter cannot see
# SQL/RLS drift, and Postgres cannot see Dart row decoders. Running only the nearest tool is how
# the repository reached a state where every subsystem looked healthy in isolation while the real
# backend stopped after signup.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v deno >/dev/null || { echo "deno is required"; exit 1; }
command -v flutter >/dev/null || { echo "flutter is required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

# Supabase records the numeric filename prefix as the migration identity. A merge can look clean
# to Git while placing two independently authored files under the same version; one then shadows
# or blocks the other during reset/push, so every runtime check after it is testing a schema that
# cannot actually be deployed. Keep this check before any expensive toolchain work and derive the
# list from disk rather than maintaining another migration manifest that can drift the same way.
DUPLICATE_MIGRATION_VERSIONS="$(
  rg --files supabase/migrations \
    | sed -E 's#^.*/([0-9]+)_.*#\1#' \
    | sort \
    | uniq -d
)"
if [[ -n "$DUPLICATE_MIGRATION_VERSIONS" ]]; then
  echo "duplicate Supabase migration version(s): $DUPLICATE_MIGRATION_VERSIONS"
  exit 1
fi

# embedding_mean holds BOTH the profile and venue centroids. A global truncate here once
# erased the only state required to interpret the already-loaded venue vectors, so keep this
# cheap static tripwire beside the checks everyone runs before deploy. This deliberately
# checks the dangerous operation, not formatting around the safe keyed replacement.
if grep -Eiq 'TRUNCATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+EXISTS)?[[:space:]]+embedding_mean' \
    clickhouse/002_seed.sql; then
  echo 'clickhouse/002_seed.sql must never truncate the shared embedding_mean table'
  exit 1
fi

echo "→ edge function type contracts"
# _shared/* is checked transitively through the functions that import it, but list it anyway
# so a shared module with no importer yet still gets checked.
deno check \
  supabase/functions/_shared/*.ts \
  supabase/functions/*/index.ts

EDGE_TESTS="$(rg --files supabase/functions | rg '_test\.ts$' || true)"
if [[ -n "$EDGE_TESTS" ]]; then
  echo "→ edge function behavior"
  # Current pure tests need environment access because the ClickHouse module validates its
  # configuration while loading. Network access stays disabled, so a unit test cannot quietly
  # become an integration call against the real venue/profile stores.
  deno test --allow-env --quiet $EDGE_TESTS
fi

echo "→ Flutter protocol and widget contracts"
(
  cd app
  flutter pub get
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze --no-pub
  flutter test --no-pub
)

echo "→ script and release-manifest contracts"
for script in scripts/*.sh; do bash -n "$script"; done
for script in $(rg --files scripts | rg '\.py$' || true); do
  python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$script"
done
rg -q '<uses-permission android:name="android.permission.INTERNET"' \
  app/android/app/src/main/AndroidManifest.xml

# Production composition must stay structurally incapable of constructing fixtures. A runtime
# boolean is not a release boundary: one stale CI define can otherwise ship a convincing fake room.
if rg -n 'mock_repository|features/product|reference_app|main_reference' \
    app/lib/main.dart app/lib/app.dart; then
  echo 'production entrypoint/router imports reference-only code'
  exit 1
fi
if rg -n 'USE_SUPABASE|SHOW_REFERENCE_UI|SHOW_DEMO_CONTROLS' \
    app/lib/main.dart app/lib/app.dart scripts/run_device.sh; then
  echo 'production composition regained a runtime fixture/demo selector'
  exit 1
fi
rg -q "import 'reference_app.dart';" app/lib/main_reference.dart

echo "→ ClickPipes infrastructure contract"
command -v terraform >/dev/null || { echo "terraform is required"; exit 1; }
terraform -chdir=infra/clickhouse-cdc fmt -check
# Validation needs the provider schema but must never initialize or inspect a deployment state.
# -backend=false preserves that boundary while still detecting renamed ClickPipes attributes.
terraform -chdir=infra/clickhouse-cdc init -backend=false -input=false >/dev/null
terraform -chdir=infra/clickhouse-cdc validate
terraform -chdir=infra/clickhouse-cdc test
./scripts/check_clickhouse_cdc.sh

echo "→ Postgres product contracts"
./scripts/check_schema.sh

echo "✓ all contracts agree"
