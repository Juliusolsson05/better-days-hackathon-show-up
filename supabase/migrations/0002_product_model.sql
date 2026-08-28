-- Brings the schema in line with the PRD in README.md. Three product rules here are not
-- access control dressed up as policy -- they are the product, and each one is only real
-- if the database enforces it.
--
--   1. Venue voting is anonymous: the tally is public to the group, the ballots are not.
--   2. Contact exchange is mutual: a number appears only when both people chose each other.
--   3. Being unselected is invisible: nobody can tell who did or did not pick them.
--
-- If the client decides any of these, the data has already reached the device.

-- ---------------------------------------------------------------------------
-- Groups are 4 to 6, and the distance metric is named for what it measures
-- ---------------------------------------------------------------------------

alter table groups rename column cohesion to seed_distance;
comment on column groups.seed_distance is
    'Mean cosine distance from the seed member to the rest. A star metric, not a clique '
    'metric -- it is not the average pairwise distance within the group.';

alter table group_members add column if not exists joined_at timestamptz not null default now();

-- ---------------------------------------------------------------------------
-- Venue voting, posted into the chat
-- ---------------------------------------------------------------------------

-- The chat is the product surface, so the vote is a message rather than a separate screen.
alter table messages add column if not exists kind text not null default 'user'
    check (kind in ('user', 'venue_vote', 'system'));

create table venue_options (
    id       uuid primary key default gen_random_uuid(),
    group_id uuid not null references groups on delete cascade,
    position smallint not null check (position between 1 and 3),
    venue    jsonb not null,          -- {yelp_id, name, address, lat, lng, categories}
    pitch    text not null,           -- one line, written for this group
    unique (group_id, position)
);

create table venue_votes (
    group_id  uuid not null references groups on delete cascade,
    user_id   uuid not null references profiles on delete cascade,
    option_id uuid not null references venue_options on delete cascade,
    voted_at  timestamptz not null default now(),
    primary key (group_id, user_id)   -- one vote each, changeable by upsert
);

-- ---------------------------------------------------------------------------
-- Post-meetup: attendance, reflection, contact exchange
-- ---------------------------------------------------------------------------

-- Attendance is the group's account of who showed up, not a check-in. Per the PRD a
-- no-show carries no penalty; this exists so the funnel has a truthful 'attended' signal.
create table attendance_votes (
    group_id   uuid not null references groups on delete cascade,
    voter_id   uuid not null references profiles on delete cascade,
    subject_id uuid not null references profiles on delete cascade,
    showed_up  boolean not null,
    primary key (group_id, voter_id, subject_id),
    check (voter_id <> subject_id)
);

-- Replaces number_shares. The PRD moved from "share and see everyone who shared" to
-- mutual selection, which is a different privacy model: under the old rule, sharing
-- revealed you to people who had not chosen you.
create table contact_selections (
    group_id    uuid not null references groups on delete cascade,
    selector_id uuid not null references profiles on delete cascade,
    selected_id uuid not null references profiles on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (group_id, selector_id, selected_id),
    check (selector_id <> selected_id)
);

drop table if exists number_shares;

-- The number lives on the profile and is never selectable by another user directly --
-- it is only ever returned through mutual_contacts() below.
alter table profiles add column if not exists phone text;
-- PRD: photo is required. Existing rows predate the rule, so this is not NOT NULL yet.
comment on column profiles.photo_url is 'Required at signup per the PRD; enforced in onboarding.';

-- Reflection now records the fallback case the PRD describes: if your assigned target did
-- not show, you answer about someone else instead.
alter table reflections add column if not exists was_fallback boolean not null default false;

alter table venue_options      enable row level security;
alter table venue_votes        enable row level security;
alter table attendance_votes   enable row level security;
alter table contact_selections enable row level security;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

create policy "read own group venue options" on venue_options for select
    using (group_id in (select my_group_ids()));

-- Deliberately narrow: you can read your OWN ballot and nobody else's. The tally comes
-- from venue_tally() below, which returns counts without ever exposing a voter.
create policy "read own vote" on venue_votes for select
    using (user_id = auth.uid());
create policy "cast own vote" on venue_votes for all
    using (user_id = auth.uid())
    with check (user_id = auth.uid() and group_id in (select my_group_ids()));

-- Same shape: your own ballots only. The result is read through attendance_result().
create policy "read own attendance votes" on attendance_votes for select
    using (voter_id = auth.uid());
create policy "cast own attendance votes" on attendance_votes for all
    using (voter_id = auth.uid())
    with check (voter_id = auth.uid() and group_id in (select my_group_ids()));

-- THE invisibility rule. You can see who you picked. You can never see who picked you,
-- because that would make being unselected inferable by elimination.
create policy "read own selections" on contact_selections for select
    using (selector_id = auth.uid());
create policy "make own selections" on contact_selections for all
    using (selector_id = auth.uid())
    with check (selector_id = auth.uid() and group_id in (select my_group_ids()));

-- ---------------------------------------------------------------------------
-- The three functions that expose aggregates without exposing ballots
-- ---------------------------------------------------------------------------

-- Anonymous tally. security definer so it can count rows the caller cannot select.
-- Returns only counts, so no ballot is recoverable from the result -- with one caveat:
-- in a group of 4-6 a unanimous tally does reveal how everyone voted. That is inherent
-- to small-group voting and not something a policy can fix.
create or replace function public.venue_tally(grp uuid)
returns table (option_id uuid, votes bigint)
language sql stable security definer set search_path = public as $$
    select o.id, count(v.user_id)
    from venue_options o
    left join venue_votes v on v.option_id = o.id
    where o.group_id = grp
      and exists (select 1 from group_members m
                  where m.group_id = grp and m.user_id = auth.uid())
    group by o.id;
$$;

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

-- The payoff. Returns a number only where the selection went both ways. Nothing in this
-- result set distinguishes "did not pick me" from "was not in the group" -- the caller
-- learns only about reciprocated choices, which is exactly the PRD rule.
create or replace function public.mutual_contacts(grp uuid)
returns table (user_id uuid, display_name text, photo_url text, phone text)
language sql stable security definer set search_path = public as $$
    select p.id, p.display_name, p.photo_url, p.phone
    from contact_selections mine
    join contact_selections theirs
      on theirs.group_id  = mine.group_id
     and theirs.selector_id = mine.selected_id
     and theirs.selected_id = mine.selector_id
    join profiles p on p.id = mine.selected_id
    where mine.group_id = grp
      and mine.selector_id = auth.uid();
$$;

alter publication supabase_realtime add table venue_votes;
