-- Make submit-profile the only path that can change a profile's matching inputs or readiness.
--
-- The previous RLS policy limited a write to `id = auth.uid()`, but did not limit which columns
-- that user could write. A direct PostgREST caller could therefore set embedded_at without a
-- ClickHouse vector, or edit passion/tags/city while preserving the timestamp for an older vector.
-- In both cases profile_ready() and run-matching trusted a Postgres/ClickHouse agreement that had
-- never been established.
--
-- submit-profile now verifies the JWT with an anon+caller client, derives the uid only from that
-- verified identity, and performs the clear/embed/stamp protocol with the service role. Revoking
-- table writes here is what makes that code path a security boundary rather than a convention.

drop policy if exists "write own profile" on public.profiles;
drop policy if exists "insert own profile" on public.profiles;
drop policy if exists "update own profile" on public.profiles;

-- Keep SELECT exactly as granted by 0003: authenticated users may read the reviewed public-profile
-- columns under RLS, while phone remains column-revoked and available only through mutual_contacts.
-- The extra privileges are included because Supabase's public-schema defaults have varied across
-- project generations; relying on PostgREST not exposing TRUNCATE/TRIGGER is not least privilege.
revoke insert, update, delete, truncate, references, trigger
    on public.profiles from anon, authenticated;
