# Harden the live group chat

Refs #15.

## Outcome

Make the Supabase-backed group chat reliable on a real phone: one lifecycle-bound
Realtime subscription, database-enforced system/user message shapes, optimistic sends
with idempotent retry, and an opening message created with every matched group.

## Plan

1. Add a forward-only chat migration for message kinds, nullable system authors, and a
   client-generated message id whose uniqueness is a valid PostgREST conflict target.
2. Retain the message stream for the mounted screen, hydrate all message kinds at the
   repository boundary, and merge socket rows with visible local send state.
3. Open each new group with a grounded system line without making an opening-message
   failure abort the remaining matching sweep; provide an idempotent service-role backfill.
4. Add an authenticated, allowlisted edge boundary for client-originated ClickHouse funnel
   events so no ClickHouse credential or arbitrary event name reaches the app.
5. Add focused SQL, Deno, and Flutter tests for the safety boundaries and failure states,
   then run the full applicable checks and review for overlap with issues #7 and PR #5.

## Deliberate boundaries

- Keep venue-vote persistence and live aggregate tallies with issue #7 and PR #5. Do not
  post the vote anchor before `venue_options` and repository vote methods exist.
- Keep the existing Postgres Changes transport. At groups of four to six, inheriting table
  RLS is more valuable than moving authorization into a second Broadcast policy layer.
- Do not add read receipts; they conflict with the product's no-guilt interaction rule.
- Do not apply migrations or deploy functions to the shared remote project from this branch.
