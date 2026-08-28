#!/usr/bin/env bash
# Parse the real semantic-view file against empty ClickPipes-shaped tables. A text linter cannot
# catch ClickHouse-specific JOIN, FINAL, aggregate, or UUID-comparison errors, while querying the
# live service would make CI depend on secrets and whatever deployment state happens to exist.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v clickhouse-local >/dev/null; then
  runner=(clickhouse-local --multiquery)
elif command -v docker >/dev/null; then
  # Pin the official image by digest: this validation executes third-party database code in CI,
  # so a mutable `latest` tag would turn an unchanged repository into an unreviewed supply-chain
  # update. 26.7 matches the production-era ClickHouse grammar this project targets.
  runner=(
    docker run --rm -i
    clickhouse/clickhouse-server:26.7@sha256:800e82865530eb2f1c4bc1b960e43b435fd9b2d83b4bd04a2564a5cfd88fdb6e
    clickhouse-local --multiquery
  )
else
  echo "clickhouse-local or Docker is required for the CDC semantic-view contract" >&2
  exit 1
fi

{
  # These are deliberately empty and contain only published columns plus PeerDB metadata. The
  # schema catches a view accidentally reaching back into excluded PII just as effectively as a
  # live table, without inventing fake user rows or coupling tests to fixture values.
  printf '%s\n' '
CREATE TABLE cdc_profiles (
  id UUID, tags Array(String), city String, availability Array(String),
  embedded_at Nullable(DateTime64(6)), created_at DateTime64(6),
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY id;
CREATE TABLE cdc_groups (
  id UUID, event_at DateTime64(6), activity String, seed_distance Nullable(Float32),
  created_at DateTime64(6), chosen_venue_id Nullable(UUID), matching_run_key Nullable(String),
  event_timezone String, venue_status String, chat_opened_at Nullable(DateTime64(6)),
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY id;
CREATE TABLE cdc_group_members (
  group_id UUID, user_id UUID, joined_at DateTime64(6), matching_run_key Nullable(String),
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, user_id);
CREATE TABLE cdc_rsvps (
  group_id UUID, user_id UUID, status String,
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, user_id);
CREATE TABLE cdc_messages (
  id Int64, group_id UUID, user_id Nullable(UUID), created_at DateTime64(6), kind String,
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY id;
CREATE TABLE cdc_venue_options (
  id UUID, group_id UUID, position Int16, provider_id String, kind String, locality String,
  score Nullable(Float32), _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY id;
CREATE TABLE cdc_venue_votes (
  group_id UUID, user_id UUID, option_id UUID, voted_at DateTime64(6),
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, user_id);
CREATE TABLE cdc_reflections (
  group_id UUID, user_id UUID, about_user Nullable(UUID), was_fallback Bool,
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, user_id);
CREATE TABLE cdc_attendance_votes (
  group_id UUID, voter_id UUID, subject_id UUID, showed_up Bool,
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, voter_id, subject_id);
CREATE TABLE cdc_contact_selections (
  group_id UUID, selector_id UUID, selected_id UUID, created_at DateTime64(6),
  _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE=ReplacingMergeTree(_peerdb_version) ORDER BY (group_id, selector_id, selected_id);
'
  sed -n '1,500p' clickhouse/004_cdc_views.sql
  printf '%s\n' 'SELECT throwIf(count() != 0) FROM analytics_group_lifecycle;'
} | "${runner[@]}"

echo "✓ ClickHouse CDC views parse against the managed-table contract"
