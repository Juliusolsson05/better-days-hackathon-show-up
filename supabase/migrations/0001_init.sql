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

-- Helper: are these two users in the same group? Used by nearly every policy.
-- security definer so the function can read group_members without recursing through
-- group_members' own RLS policy.
create or replace function shares_group_with(target uuid, grp uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from group_members a
        join group_members b on a.group_id = b.group_id
        where a.user_id = auth.uid() and b.user_id = target and a.group_id = grp
    );
$$;

create policy "read own profile" on profiles for select
    using (id = auth.uid());
-- You can see a groupmate's profile, but nothing about anyone you were not matched with.
-- There is no browse in this product, so there is no policy that lets you list people.
create policy "read groupmate profiles" on profiles for select
    using (exists (
        select 1 from group_members a
        join group_members b on a.group_id = b.group_id
        where a.user_id = auth.uid() and b.user_id = profiles.id
    ));
create policy "write own profile" on profiles for all
    using (id = auth.uid()) with check (id = auth.uid());

create policy "read own groups" on groups for select
    using (exists (select 1 from group_members m
                   where m.group_id = groups.id and m.user_id = auth.uid()));

create policy "read own membership" on group_members for select
    using (exists (select 1 from group_members m
                   where m.group_id = group_members.group_id and m.user_id = auth.uid()));

create policy "read group rsvps" on rsvps for select
    using (exists (select 1 from group_members m
                   where m.group_id = rsvps.group_id and m.user_id = auth.uid()));
create policy "set own rsvp" on rsvps for all
    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "read group messages" on messages for select
    using (exists (select 1 from group_members m
                   where m.group_id = messages.group_id and m.user_id = auth.uid()));
create policy "post as self" on messages for insert
    with check (user_id = auth.uid() and exists (
        select 1 from group_members m
        where m.group_id = messages.group_id and m.user_id = auth.uid()));

-- Reflections are mutual and disclosed: you see what your pair wrote about you only
-- once you have written yours.
create policy "read reflections after writing own" on reflections for select
    using (
        about_user = auth.uid()
        and exists (select 1 from reflections mine
                    where mine.group_id = reflections.group_id and mine.user_id = auth.uid())
    );
create policy "write own reflection" on reflections for insert
    with check (user_id = auth.uid());

-- THE reciprocity gate. Share your number and you see everyone else who shared; don't
-- and you see nothing. This has to live here rather than in Dart -- if the client
-- decides, the numbers have already been sent to the device and the gate is decorative.
create policy "reciprocal disclosure only" on number_shares for select
    using (exists (
        select 1 from number_shares mine
        where mine.group_id = number_shares.group_id and mine.user_id = auth.uid()
    ));
create policy "share own number" on number_shares for insert
    with check (user_id = auth.uid() and exists (
        select 1 from group_members m
        where m.group_id = number_shares.group_id and m.user_id = auth.uid()));

-- Realtime for the group chat. Without this the Flutter .stream() call silently
-- returns the initial rows and then never updates again.
alter publication supabase_realtime add table messages;
