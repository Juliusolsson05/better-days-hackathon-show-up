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

# _shared/* is checked transitively through the functions that import it, but list it anyway
# so a shared module with no importer yet still gets checked.
exec deno check \
  supabase/functions/_shared/*.ts \
  supabase/functions/*/index.ts
