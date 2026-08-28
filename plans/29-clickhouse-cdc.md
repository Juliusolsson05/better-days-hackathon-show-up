# Replicate operational product data into ClickHouse

Issue: #29

## Product boundary

Postgres remains the only transactional source of truth. ClickHouse receives an
analytical projection through managed Postgres CDC; the app and edge functions never read
the replica to decide whether a user may see or change something. That separation matters
because ClickHouse update/delete reconciliation is eventually consistent, while RSVP,
privacy, voting, and membership decisions must be correct at the instant they are made.

CDC complements rather than replaces the existing ClickHouse paths:

- `events` remains the append-only behavioral stream for facts such as opening a chat or
  notification that do not exist as durable Postgres rows.
- `profile_vectors` and `venue_vectors` remain derived, ClickHouse-native search indexes.
- `cdc_*` tables become versioned analytical replicas of committed Postgres product state.

## Replication contract

1. Publish only application tables needed to measure the lifecycle: profiles, groups,
   memberships, RSVPs, message metadata, venue options and ballots, reflections without
   their prose, attendance ballots, and contact selections.
2. Keep direct identifiers and private content out of the replica: phone numbers, photo
   paths, names, passions, message bodies, reflection prose, assignment questions, venue
   addresses, and per-member venue score arrays are not analytical inputs.
3. Every replicated table keeps its immutable Postgres primary key as the ClickPipes
   ordering key. We do not invent a time-based sorting key because that would stop
   ReplacingMergeTree from reconciling later versions of the same row.
4. Destination tables are explicitly named `cdc_<source>` and use
   `ReplacingMergeTree`. Correct current-state queries must deduplicate versions and
   remove `_peerdb_is_deleted` tombstones.
5. The replication login is dedicated, read-only for the published application tables,
   and created from an operator-supplied secret. No database or ClickHouse Cloud
   credential enters Git, Terraform defaults, a process argument, or command output.

## Implementation sequence

1. Add the Postgres publication and schema assertions. Prove that required tables and
   identity columns are present and that sensitive columns cannot drift into the
   publication unnoticed.
2. Add a dormant migration-owned role with the minimum column grants, plus an idempotent
   source bootstrap that supplies its secret and activates replication immediately before
   apply. Let the managed pipe create its logical slot only when the consumer is provisioned;
   an inactive slot must never come from an ordinary migration because it retains WAL.
3. Declare the managed Postgres CDC ClickPipe with the official ClickHouse Terraform
   provider. Mirror the publication allowlist in table mappings and column exclusions so
   a configuration review shows the whole data boundary.
4. Add post-provision ClickHouse views and verification queries that expose deduplicated
   current state and fail if replication is stale or a tombstone is accidentally counted.
5. Integrate SQL, shell, and Terraform validation into the repository gate; run all
   existing Deno, Flutter, and Postgres contracts; then open a reviewed PR linked to #29.

## Deployment and rollback

- Apply the Postgres migration before creating the pipe, then bootstrap the source login
  and apply Terraform with environment-provided secrets.
- Run a Terraform plan before apply so the table mappings and exclusions are reviewed.
  ClickHouse currently requires a new CDC pipe to start running when created, so the source
  role and publication must already be complete before apply.
- Pausing or deleting the ClickPipe does not affect the application. Drop a replication
  slot only after confirming no subscriber uses it; otherwise the safe rollback is to
  pause the pipe while preserving its resume position.
- Monitor replication lag and retained WAL. A stopped consumer is an operational incident,
  not a harmless idle resource, because its slot can grow the source database storage.

## Verification

- Postgres tests inspect `pg_publication_tables`, primary keys, operation settings, and
  the exact set of published columns.
- Terraform format and validation prove the provider contract and sensitive variables.
- Static checks compare the publication, Terraform mappings, and analytical views so a
  later migration cannot update one boundary while silently forgetting the others.
- A live smoke check compares per-table source and deduplicated destination counts after
  Terraform apply without printing row content or credentials.
