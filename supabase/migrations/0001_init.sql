-- Postgres (OLTP) side. Everything here is read one row at a time and must be correct
-- right now. The vectors and the event stream live in ClickHouse instead -- see
-- clickhouse/001_schema.sql.
--
-- Flutter talks to these tables DIRECTLY with the public anon key. That is safe only
-- because every table below has RLS on; if you add a table, add its policies in the
-- same migration or it is readable by the whole internet.

create extension if not exists "pgcrypto";

create table profiles (
    id           uuid primary key references auth.users on delete cascade,
    display_name text not null,
    passion      text not null,          -- the free-text field the embedding is built from
    tags         text[] not null default '{}',
    city         text not null,
    availability text[] not null default '{}',
    photo_url    text,                   -- non-face photos only, enforced in the client
    embedded_at  timestamptz,            -- null until submit-profile has pushed to ClickHouse
    created_at   timestamptz not null default now()
);

create table groups (
    id       uuid primary key default gen_random_uuid(),
    event_at timestamptz not null,
    venue    jsonb not null,             -- {name, address, lat, lng} chosen by Claude
    activity text not null,
    cohesion real,                       -- avg pairwise distance, feeds cohesion.sql
    created_at timestamptz not null default now()
);

create table group_members (
    group_id  uuid not null references groups on delete cascade,
    user_id   uuid not null references profiles on delete cascade,
    pair_with uuid references profiles,  -- the one person you are pointed at during the event
    question  text,                      -- generated from YOUR pair's passion, not yours
    primary key (group_id, user_id)
);

create table rsvps (
    group_id uuid not null references groups on delete cascade,
    user_id  uuid not null references profiles on delete cascade,
    status   text not null check (status in ('pending', 'confirmed', 'declined')),
    primary key (group_id, user_id)
);

create table messages (
    id         bigserial primary key,
    group_id   uuid not null references groups on delete cascade,
    user_id    uuid not null references profiles on delete cascade,
    body       text not null,
    created_at timestamptz not null default now()
);
create index on messages (group_id, created_at);

create table reflections (
    group_id   uuid not null references groups on delete cascade,
    user_id    uuid not null references profiles on delete cascade,
    about_user uuid not null references profiles on delete cascade,
    what_stuck text not null,
    primary key (group_id, user_id)
);

create table number_shares (
    group_id uuid not null references groups on delete cascade,
    user_id  uuid not null references profiles on delete cascade,
    phone    text not null,
    shared_at timestamptz not null default now(),
    primary key (group_id, user_id)
);

alter table profiles       enable row level security;
alter table groups         enable row level security;
alter table group_members  enable row level security;
alter table rsvps          enable row level security;
alter table messages       enable row level security;
alter table reflections    enable row level security;
alter table number_shares  enable row level security;

-- RLS helpers.
--
-- These exist because a policy on group_members whose USING clause selects from
-- group_members makes Postgres re-enter the same policy and raise 42P17
-- "infinite recursion detected in policy". security definer breaks the loop: the
-- function body runs as the owner, so the inner read is not itself RLS-filtered.
--
-- Every policy that needs "which groups am I in" goes through my_group_ids().
create or replace function public.my_group_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
    select group_id from group_members where user_id = auth.uid();
$$;

create or replace function public.shares_any_group_with(target uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from group_members a
        join group_members b using (group_id)
        where a.user_id = auth.uid() and b.user_id = target
    );
$$;

create or replace function public.has_shared_number(grp uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from number_shares where group_id = grp and user_id = auth.uid()
    );
$$;

create or replace function public.wrote_reflection_in(grp uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from reflections where group_id = grp and user_id = auth.uid()
    );
$$;

create policy "read own profile" on profiles for select
    using (id = auth.uid());
-- You can see a groupmate's profile, but nothing about anyone you were not matched
-- with. There is no browse in this product, so there is deliberately no policy
-- anywhere that lets a user list people.
create policy "read groupmate profiles" on profiles for select
    using (shares_any_group_with(profiles.id));
create policy "write own profile" on profiles for all
    using (id = auth.uid()) with check (id = auth.uid());

create policy "read own groups" on groups for select
    using (id in (select my_group_ids()));

create policy "read own membership" on group_members for select
    using (user_id = auth.uid() or group_id in (select my_group_ids()));

create policy "read group rsvps" on rsvps for select
    using (group_id in (select my_group_ids()));
-- Membership check on write as well: without it any authenticated user could insert
-- an RSVP into a group they were never assigned to.
create policy "set own rsvp" on rsvps for all
    using (user_id = auth.uid())
    with check (user_id = auth.uid() and group_id in (select my_group_ids()));

create policy "read group messages" on messages for select
    using (group_id in (select my_group_ids()));
create policy "post as self" on messages for insert
    with check (user_id = auth.uid() and group_id in (select my_group_ids()));

-- Reflections are mutual and disclosed: you see what your pair wrote about you only
-- once you have written yours.
create policy "read reflections after writing own" on reflections for select
    using (about_user = auth.uid() and wrote_reflection_in(reflections.group_id));
create policy "write own reflection" on reflections for insert
    with check (user_id = auth.uid() and group_id in (select my_group_ids()));

-- THE reciprocity gate. Share your number and you see everyone else who shared; don't
-- and you see nothing. This has to live here rather than in Dart -- if the client
-- decides, the numbers have already been sent to the device and the gate is decorative.
create policy "reciprocal disclosure only" on number_shares for select
    using (has_shared_number(number_shares.group_id));
create policy "share own number" on number_shares for insert
    with check (user_id = auth.uid() and group_id in (select my_group_ids()));

-- Realtime for the group chat. Without this the Flutter .stream() call silently
-- returns the initial rows and then never updates again.
alter publication supabase_realtime add table messages;
