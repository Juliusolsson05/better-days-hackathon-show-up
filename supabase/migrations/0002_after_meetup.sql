-- ============================================================================
-- After-meetup slice of the 0002 draft, promoted to a real migration.
--
-- WHY only a slice: supabase/drafts/0002_product_model.sql.draft also carries the
-- venue-voting tables and the cohesion->seed_distance rename. Those are being reworked
-- on feat/venue-pipeline (real venue retrieval, a venue corpus in ClickHouse) and the
-- rename means editing run-matching -- both belong with that work, not here. This file
-- takes ONLY what the post-meetup flow (after_flow.dart, contacts_screen.dart) needs:
-- attendance, contact exchange, and the reflection fallback flag.
--
-- >>> The venue migration that follows MUST be 0003, not 0002. Two files with version
-- >>> 0002 make `supabase db push` reject the whole set as a duplicate version. <<<
--
-- Open questions from the draft that this slice commits to a position on:
--   * Phone number lives on `profiles`, not per-group. Simpler, and nobody in the PRD
--     wants a different number per meetup. Revisit only if that turns out wrong.
--   * Attendance is a group vote (attendance_votes), not a doorway check-in. The vote is
--     the PRD's model and it is what feeds a truthful `attended` signal to the funnel.
--
-- The two product rules below are enforced by the database, not the client, because if
-- the client decided them the data would already be on the device:
--   1. Contact exchange is mutual: a number appears only when both people chose each other.
--   2. Being unselected is invisible: nobody can tell who did or did not pick them.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Attendance: the group's account of who showed up
-- ---------------------------------------------------------------------------

-- Per the PRD a no-show carries no penalty; this table exists so the funnel has a
-- truthful `attended` signal, and so the reflection step can offer its fallback.
create table attendance_votes (
    group_id   uuid not null references groups on delete cascade,
    voter_id   uuid not null references profiles on delete cascade,
    subject_id uuid not null references profiles on delete cascade,
    showed_up  boolean not null,
    primary key (group_id, voter_id, subject_id),
    check (voter_id <> subject_id)
);

-- ---------------------------------------------------------------------------
-- Contact exchange: mutual selection, replacing number_shares
-- ---------------------------------------------------------------------------

-- The old model was "share your number and see everyone else who shared" -- which
-- revealed you to people who had not chosen you. The PRD moved to mutual selection:
-- a number surfaces only when the choice went both ways. Different privacy model, so
-- a different table.
create table contact_selections (
    group_id    uuid not null references groups on delete cascade,
    selector_id uuid not null references profiles on delete cascade,
    selected_id uuid not null references profiles on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (group_id, selector_id, selected_id),
    check (selector_id <> selected_id)
);

-- number_shares and its reciprocal-disclosure policy are now dead. Dropping the table
-- takes the policy with it; the helper function has to go by hand or it lingers as a
-- security-definer function selecting from a table that no longer exists.
drop table if exists number_shares;
drop function if exists public.has_shared_number(uuid);

-- The number lives on the profile and is never selectable by another user directly --
-- it is only ever returned through mutual_contacts() below, and only for reciprocated
-- picks.
alter table profiles add column if not exists phone text;

-- The reflection step's fallback: if your assigned target did not show, you answer about
-- someone else instead. about_user stays NOT NULL (the client still records the assigned
-- pair there); this flag marks that the content is really about the group.
alter table reflections add column if not exists was_fallback boolean not null default false;

-- 0001 gave reflections INSERT + SELECT but no UPDATE, so an upsert that hit the existing
-- row failed under RLS. The after-flow upserts (you can edit before moving to the next
-- step), so let the owner update their own row.
drop policy if exists "edit own reflection" on reflections;
create policy "edit own reflection" on reflections for update
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table attendance_votes   enable row level security;
alter table contact_selections enable row level security;

-- Your own ballots only. The tally is read through attendance_result(), which is
-- security definer and returns counts, never a voter.
create policy "read own attendance votes" on attendance_votes for select
    using (voter_id = auth.uid());
create policy "cast own attendance votes" on attendance_votes for all
    using (voter_id = auth.uid())
    with check (voter_id = auth.uid() and group_id in (select my_group_ids()));

-- THE invisibility rule. You can see who you picked; you can never see who picked you,
-- because that would make "was not picked" inferable by elimination.
create policy "read own selections" on contact_selections for select
    using (selector_id = auth.uid());
create policy "make own selections" on contact_selections for all
    using (selector_id = auth.uid())
    with check (selector_id = auth.uid() and group_id in (select my_group_ids()));

-- ---------------------------------------------------------------------------
-- The functions that expose aggregates without exposing ballots
-- ---------------------------------------------------------------------------

-- security definer so it can count rows the caller cannot select. The membership check
-- keeps it scoped to your own groups. In a group of 4-6 a unanimous vote still reveals
-- how everyone voted -- that is inherent to small-group voting, not a policy bug.
create or replace function public.attendance_result(grp uuid)
returns table (subject_id uuid, showed_up bigint, total bigint)
language sql stable security definer set search_path = public as $$
    select a.subject_id, count(*) filter (where a.showed_up), count(*)
    from attendance_votes a
    where a.group_id = grp
      and exists (select 1 from group_members m
                  where m.group_id = grp and m.user_id = auth.uid())
    group by a.subject_id;
$$;

-- The payoff. Returns a row only where the selection went both ways. Nothing in the
-- result distinguishes "did not pick me" from "was not in the group" -- the caller
-- learns only about reciprocated choices, which is exactly the PRD rule.
create or replace function public.mutual_contacts(grp uuid)
returns table (user_id uuid, display_name text, photo_url text, phone text)
language sql stable security definer set search_path = public as $$
    select p.id, p.display_name, p.photo_url, p.phone
    from contact_selections mine
    join contact_selections theirs
      on theirs.group_id   = mine.group_id
     and theirs.selector_id = mine.selected_id
     and theirs.selected_id = mine.selector_id
    join profiles p on p.id = mine.selected_id
    where mine.group_id = grp
      and mine.selector_id = auth.uid();
$$;
