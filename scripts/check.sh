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

echo "→ edge function type contracts"
deno check supabase/functions/_shared/*.ts supabase/functions/*/index.ts

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

echo "→ Postgres product contracts"
./scripts/check_schema.sh

echo "✓ all contracts agree"
