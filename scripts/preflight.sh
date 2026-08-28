#!/usr/bin/env bash
# Read-only proof that the linked hosted backend is capable of serving the real app.
#
# The ordinary contract suite is intentionally hermetic: CI starts a disposable Supabase stack
# and must never need production credentials. That makes it possible for every local test to pass
# while the deployed functions have empty upstream secrets or the checked-out migrations lag the
# database. Both failures happened without a type/schema error; they appear only when a user
# reaches signup or matching. Keep this as an explicit operator gate before a rehearsal instead
# of teaching CI or `flutter run` to depend on one shared hosted project.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v supabase >/dev/null || { printf 'supabase CLI is required\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'python3 is required\n' >&2; exit 1; }

# Supabase prints SHA-256 digests, never secret values. The digest of the empty byte string is
# stable, so it lets this gate distinguish "a secret record exists" from "the function can
# authenticate upstream" without reading or echoing credentials. URL and username are included
# because a password alone does not identify a ClickHouse service.
readonly EMPTY_SHA256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
readonly REQUIRED_SECRETS=(
  ANTHROPIC_API_KEY
  CLICKHOUSE_PASSWORD
  CLICKHOUSE_URL
  CLICKHOUSE_USER
  VOYAGE_API_KEY
)

failed=0

printf '→ hosted function secrets\n'
secrets_json="$(supabase secrets list --output json)"
secret_failures="$({
  printf '%s' "$secrets_json" | python3 -c '
import json
import sys

empty = sys.argv[1]
required = sys.argv[2:]
digests = {entry["name"]: entry["value"] for entry in json.load(sys.stdin)}
for name in required:
    if name not in digests:
        print(f"missing hosted secret: {name}")
    elif digests[name] == empty:
        print(f"empty hosted secret: {name}")
' "$EMPTY_SHA256" "${REQUIRED_SECRETS[@]}"
})"
if [[ -n "$secret_failures" ]]; then
  printf '%s\n' "$secret_failures" >&2
  failed=1
else
  printf '✓ required hosted secrets are non-empty\n'
fi

printf '→ migration history\n'
migrations="$(supabase migration list)"
migration_failures="$({
  # The CLI has no machine-readable migration-list output today. Parse only rows whose local or
  # remote column is numeric, ignoring headers and update notices. A version on just one side is
  # actionable drift: pushing from an older checkout can fail, or worse, invite someone to repair
  # production from a schema that does not describe it.
  printf '%s\n' "$migrations" | awk -F'|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    {
      local_version = trim($1)
      remote_version = trim($2)
      if (local_version !~ /^[0-9]+$/ && remote_version !~ /^[0-9]+$/) next
      if (local_version == remote_version) next
      if (local_version == "") local_version = "<missing>"
      if (remote_version == "") remote_version = "<missing>"
      printf "migration history diverged: local=%s remote=%s\n", local_version, remote_version
    }
  '
})"
if [[ -n "$migration_failures" ]]; then
  printf '%s\n' "$migration_failures" >&2
  failed=1
else
  printf '✓ local and hosted migration versions agree\n'
fi

printf '→ deployed function manifest\n'
functions_json="$(supabase functions list --output json)"
function_failures="$({
  # A directory on disk is not a deployed endpoint, and analytics' verify_jwt exception used to
  # live only in a one-off CLI command. Compare the complete hosted manifest so a generic deploy,
  # stale function, or omitted system-to-system dependency fails before a device reaches it.
  printf '%s' "$functions_json" | python3 -c '
import json
import sys

expected = {
    "analytics": False,
    "open-chat": True,
    "pick-venues": True,
    "run-matching": True,
    "submit-profile": True,
    "track": True,
}
actual = {entry["slug"]: entry for entry in json.load(sys.stdin)}
for slug, verify_jwt in expected.items():
    entry = actual.get(slug)
    if entry is None:
        print(f"missing deployed function: {slug}")
        continue
    if entry.get("status") != "ACTIVE":
        print(f"deployed function is not active: {slug}")
    if entry.get("verify_jwt") is not verify_jwt:
        print(f"verify_jwt drift for {slug}: expected {str(verify_jwt).lower()}")
'
})"
if [[ -n "$function_failures" ]]; then
  printf '%s\n' "$function_failures" >&2
  failed=1
else
  printf '✓ all six functions are active with the reviewed JWT policy\n'
fi

if (( failed )); then
  printf 'hosted preflight failed; repair the items above before exercising the real API\n' >&2
  exit 1
fi

printf '✓ hosted preflight passed\n'
