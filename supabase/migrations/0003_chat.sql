-- Chat, beyond the plain text message.
--
-- 0001 gave the chat everything it needed to carry USER messages: a table, two policies,
-- and the realtime publication line. This adds the two things the PRD needs on top, and
-- nothing else.
--
-- Scoped deliberately narrowly. supabase/drafts/0002_product_model.sql.draft is a much
-- larger proposal (venue voting, attendance, contact exchange) that is still being settled
-- in issue #7, and the chat should not have to wait for it. Everything here is written
-- `if not exists` / `drop ... if exists` so that promoting the draft alongside this file
-- is a no-op rather than a conflict -- the draft's own `add column if not exists kind`
-- will simply find the column already present.

-- ---------------------------------------------------------------------------
-- 1. Message kinds
-- ---------------------------------------------------------------------------
--
-- The chat is the ONLY product surface, so the venue vote and the system framing are
-- messages rather than screens. GroupChatScreen._bubble already branches on all three
-- kinds; without this column SupabaseRepository can only ever emit 'user', so both of
-- those branches are dead code against the real backend and the vote is invisible.
--
-- Defaulting to 'user' is what makes this safe to apply to a live table: every existing
-- row is a user message, because until now there was no way to write anything else.

alter table messages add column if not exists kind text not null default 'user';

do $$ begin
    alter table messages add constraint messages_kind_known
        check (kind in ('user', 'venue_vote', 'system'));
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. System messages have no author
-- ---------------------------------------------------------------------------
--
-- run-matching posts the opening system line and the vote anchor as the group forms. It
-- runs as the service role, which bypasses RLS -- but NOT a NOT NULL constraint, so with
-- user_id still mandatory that insert fails outright.
--
-- Dropping NOT NULL would also let a USER message through with no author, which renders
-- as a nameless bubble. The check keeps the invariant that NOT NULL used to carry, but
-- only where it actually applies.
--
-- Note what stays true: the 'post as self' insert policy is `user_id = auth.uid()`, and
-- `null = auth.uid()` is NULL, not true. So a client still cannot forge a system message
-- even though the column now accepts null. The privilege boundary is unchanged.

alter table messages alter column user_id drop not null;

do $$ begin
    alter table messages add constraint user_messages_have_authors
        check (kind <> 'user' or user_id is not null);
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Client-generated id, for optimistic send and retry safety
-- ---------------------------------------------------------------------------
--
-- Two problems, one column.
--
-- The message is echoed back through the sender's own realtime subscription, so an
-- optimistic bubble and its echo are two renderings of one message with nothing to tie
-- them together -- `id` is a bigserial the client does not learn until the insert returns.
-- The client generates this uuid before sending, so it can reconcile the two.
--
-- It also makes the insert idempotent. A send that times out AFTER Postgres committed but
-- before the response arrived is indistinguishable, from the client, from one that never
-- landed. Without a stable key, the retry double-posts; with `on conflict do nothing` it
-- cannot. This matters on the demo network specifically.
--
-- Nullable because rows written server-side (system, venue_vote) have no client to
-- generate one. PostgreSQL unique constraints deliberately allow multiple NULLs, so an
-- ordinary constraint preserves that while also giving PostgREST a real conflict target.
-- A partial unique index looks attractive, but `upsert(onConflict: 'client_msg_id')`
-- generates `ON CONFLICT (client_msg_id)`, which cannot infer a partial index unless its
-- predicate is repeated -- and PostgREST has no API for supplying that predicate.

alter table messages add column if not exists client_msg_id uuid;

do $$ begin
    alter table messages add constraint messages_client_msg_id_key unique (client_msg_id);
exception when duplicate_object then null;
end $$;

-- No publication change: 0001 already ran `alter publication supabase_realtime add table
-- messages`, and that covers columns added later. Adding it twice raises.
