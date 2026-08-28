#!/usr/bin/env bash
# Resets demo state so the run-through can be rehearsed as many times as needed.
#
# This exists because the usual failure at 5:05pm is not a broken feature -- it is a demo
# account that is already in a group from testing, and a team presenting around it. Being
# able to run the whole flow three times before demoing is worth more than any feature
# built in the same twenty minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

echo "→ clearing group-owned demo state"
psql "$SUPABASE_DB_URL" -q <<'SQL'
-- `groups` is the aggregate root. Every membership, RSVP, message, assignment, reflection,
-- attendance ballot, contact choice, venue option, and venue vote has an ON DELETE CASCADE path
-- from it. Naming leaves here drifted as parallel migrations added and retired tables, causing
-- the reset itself to fail before a rehearsal; deleting the root follows the schema contract.
delete from groups;
SQL

echo "→ clearing demo event stream (keeps the seeded synthetic history)"
curl -sS "$CLICKHOUSE_URL" \
  -H "X-ClickHouse-User: $CLICKHOUSE_USER" -H "X-ClickHouse-Key: $CLICKHOUSE_PASSWORD" \
  --data-binary "ALTER TABLE events DELETE WHERE name = 'group_formed' AND ts > now() - INTERVAL 1 DAY" >/dev/null

echo "→ re-running the matching sweep"
curl -sS -X POST "$SUPABASE_URL/functions/v1/run-matching" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"city":"SF","slot":"fri_eve"}' | tee /dev/stderr

echo
echo "✓ ready. reload the app."
