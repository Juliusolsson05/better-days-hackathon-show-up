# Align product contracts

Refs #7

## Outcome

Make Postgres, the edge functions, and Flutter's `Repository` describe the same product
without absorbing the notification, map, or venue-retrieval implementations that other
branches currently own.

## Plan

1. Turn the reviewed parts of the product-model draft into a forward-only migration.
   Preserve existing rows, remove the retired disclosure policy before its table, and make
   cross-group ballots impossible with composite membership foreign keys.
2. Implement the existing real-repository methods against that schema. Keep database row
   decoding at the repository boundary so widgets never learn PostgREST response shapes.
3. Give server-side venue retrieval an RPC-shaped persistence boundary that can be consumed
   after the venue branch merges, without copying that branch's retrieval code.
4. Update the reset path and add contract checks for the invariants that ordinary type
   checking cannot see across SQL and Dart.
5. Run Flutter analysis/tests, Deno checks, shell syntax checks, and review the final diff
   against the active feature branches before opening a PR.

## Non-goals

- Do not integrate or rewrite the notification ladder, venue map, or venue retrieval logic.
- Do not apply migrations to the shared remote Supabase project from this branch.
- Do not merge the branch without explicit confirmation.
