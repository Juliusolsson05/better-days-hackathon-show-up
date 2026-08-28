-- Bring the applied OLTP schema up to the product contract in README.md. This is version 0003
-- because main's narrower after-meetup migration already owns 0002 in deployed environments.
--
-- This migration is intentionally more than the old draft copied into migrations. Two of
-- the product promises are confidentiality boundaries, and row-level security cannot make a
-- column private when the rest of its row is shared:
--
--   * `group_members` is visible to the whole group, so private questions cannot live there.
--   * `profiles` is visible to groupmates, so phone numbers cannot inherit the table-wide
--     SELECT grant and then rely on the Flutter client to hide them.
--
-- The tables and grants below make those promises true even for a hostile direct API client.

-- -----------------------------------------------------------------------------
-- Existing tables: name what is measured and close cross-group integrity holes
-- -----------------------------------------------------------------------------

alter table public.groups rename column cohesion to seed_distance;
comment on column public.groups.seed_distance is
    'Mean cosine distance from the seed member to the rest. This is a star metric, not the '
    'average pairwise distance within the group.';

-- `groups.venue` is the legacy one-venue answer produced by planGroup. It remains during the
-- venue-pipeline rollout so old groups still render, but new code reads typed venue_options.
-- Dropping NOT NULL lets group formation and venue retrieval fail independently.
alter table public.groups alter column venue drop not null;
comment on column public.groups.venue is
    'Legacy fallback only. New groups receive grounded choices in venue_options.';

alter table public.groups add column chosen_venue_id uuid;
alter table public.groups add column matching_run_key text;
alter table public.groups add column formation_key text;
alter table public.groups add column event_timezone text not null default 'America/Los_Angeles';
alter table public.groups add constraint groups_id_run_unique unique (id, matching_run_key);
create unique index groups_formation_key_unique
    on public.groups (formation_key) where formation_key is not null;
alter table public.groups add column venue_status text not null default 'pending'
    check (venue_status in ('pending', 'voting', 'chosen', 'failed', 'legacy'));
update public.groups set venue_status = 'legacy' where venue is not null;
comment on column public.groups.venue_status is
    'Durable handoff between matching, venue retrieval, voting, and finalization. A group '
    'must not infer pipeline state from whether one nullable row happened to arrive.';
alter table public.group_members
    add column joined_at timestamptz not null default now();
alter table public.group_members add column matching_run_key text;
alter table public.group_members add constraint group_members_run_matches_group
    foreign key (group_id, matching_run_key)
    references public.groups (id, matching_run_key) not valid;
create unique index group_members_one_group_per_run
    on public.group_members (matching_run_key, user_id)
    where matching_run_key is not null;

-- The emoji remains a useful low-bandwidth fallback when a signed photo URL expires or an
-- upload is unavailable. It is persisted because the real repository cannot reconstruct the
-- locally selected emoji after another group member loads the profile.
alter table public.profiles add column avatar text not null default '🙂';
-- 0002_after_meetup introduced phone first. IF NOT EXISTS is an upgrade requirement, not
-- permissiveness: clean installs and already-deployed 0002 databases must converge here.
alter table public.profiles add column if not exists phone text;
comment on column public.profiles.phone is
    'Private contact data. Direct SELECT is revoked below; mutual_contacts is the only '
    'groupmate disclosure path.';

-- The old client stored Supabase's public-object URL. Once the bucket becomes private that URL
-- stops working, and treating it as an object name would make signed-URL generation fail too.
-- Recover the owned object path when it is recognizable; quarantine unrelated HTTP URLs instead
-- of continuing to load an arbitrary tracking endpoint in every groupmate's app.
update public.profiles
set photo_url = substring(photo_url from '/storage/v1/object/public/photos/(.+)$')
where photo_url ~ '/storage/v1/object/public/photos/.+$';
update public.profiles
set photo_url = null
where photo_url ~ '^https?://';

-- NOT VALID preserves pre-product rows while still enforcing the rule for every future
-- insert/update. Once old demo profiles have photos, this can be validated without downtime.
alter table public.profiles add constraint profiles_photo_required
    check (photo_url is not null) not valid;
alter table public.profiles add constraint profiles_photo_owned_path
    check (photo_url is null or photo_url = id::text || '/profile.jpg') not valid;
alter table public.profiles add constraint profiles_phone_e164
    check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$') not valid;
comment on column public.profiles.photo_url is
    'Object path inside the private photos bucket, despite the legacy column name.';

-- Membership is the parent fact for every group-scoped record. Composite foreign keys stop a
-- perfectly valid user UUID or option UUID from being attached to the wrong group, something
-- RLS alone does not catch when the caller is a member of one of the groups.
alter table public.rsvps add constraint rsvps_member_fkey
    foreign key (group_id, user_id)
    references public.group_members (group_id, user_id) on delete cascade not valid;
alter table public.messages add constraint messages_member_fkey
    foreign key (group_id, user_id)
    references public.group_members (group_id, user_id) on delete cascade not valid;
alter table public.reflections add constraint reflections_author_member_fkey
    foreign key (group_id, user_id)
    references public.group_members (group_id, user_id) on delete cascade not valid;

-- -----------------------------------------------------------------------------
-- Private assignments: split away from the group-visible membership rows
-- -----------------------------------------------------------------------------

create table public.member_assignments (
    group_id uuid not null,
    user_id uuid not null,
    target_id uuid not null,
    question text not null,
    primary key (group_id, user_id),
    foreign key (group_id, user_id)
        references public.group_members (group_id, user_id) on delete cascade,
    foreign key (group_id, target_id)
        references public.group_members (group_id, user_id) on delete cascade,
    check (user_id <> target_id)
);

-- Preserve groups formed under 0001 before removing the columns that leaked questions to the
-- whole group. Rows with incomplete assignments were never usable and remain absent rather
-- than being converted into invalid private records.
insert into public.member_assignments (group_id, user_id, target_id, question)
select author.group_id, author.user_id, author.pair_with, author.question
from public.group_members author
join public.group_members target
  on target.group_id = author.group_id and target.user_id = author.pair_with
where author.pair_with is not null and author.question is not null;

alter table public.group_members drop column pair_with;
alter table public.group_members drop column question;

alter table public.member_assignments enable row level security;
create policy "read own private assignment"
    on public.member_assignments for select to authenticated
    using (user_id = auth.uid() and group_id in (select public.my_group_ids()));

-- There is deliberately no client write policy. Assignments are generated during matching;
-- allowing a user to edit a target or question would make the derangement guarantee fiction.
grant select on public.member_assignments to authenticated;

-- Group formation used to be four independent HTTP writes (group, members, assignments,
-- RSVPs). A failure in write three left a visible group with no questions and no retry-safe way
-- to finish it. One database function gives the edge function a transaction and lets Postgres
-- enforce both 4-6 membership and the "everyone is exactly one person's target" derangement.
create or replace function public.form_group(
    p_event_at timestamptz,
    p_legacy_venue jsonb,
    p_activity text,
    p_seed_distance real,
    p_members jsonb,
    p_run_key text default null,
    p_event_timezone text default 'America/Los_Angeles'
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    new_group_id uuid;
    member_count integer;
    stable_formation_key text;
begin
    if p_members is null or jsonb_typeof(p_members) <> 'array' then
        raise exception 'members must be a JSON array' using errcode = '22023';
    end if;

    member_count := jsonb_array_length(p_members);
    if member_count not between 4 and 6 then
        raise exception 'groups require 4 to 6 members, got %', member_count
            using errcode = '23514';
    end if;

    if (select count(distinct x.user_id)
        from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text))
       <> member_count
       or (select count(distinct x.target_id)
           from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text))
          <> member_count
       or exists (
           select 1
           from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text)
           where x.user_id = x.target_id
              or nullif(btrim(x.question), '') is null
              or not exists (
                  select 1
                  from jsonb_to_recordset(p_members) y(user_id uuid, target_id uuid, question text)
                  where y.user_id = x.target_id
              )
       ) then
        raise exception 'members must contain unique users and a complete target derangement'
            using errcode = '23514';
    end if;

    if p_run_key is not null and nullif(btrim(p_run_key), '') is null then
        raise exception 'matching run key cannot be blank' using errcode = '22023';
    end if;
    if nullif(btrim(p_event_timezone), '') is null then
        raise exception 'event timezone cannot be blank' using errcode = '22023';
    end if;

    if p_run_key is not null then
        select p_run_key || ':' || md5(string_agg(x.user_id::text, ',' order by x.user_id))
        into stable_formation_key
        from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text);

        -- The lock closes the race between “does this exact formation already exist?” and the
        -- insert. A unique index alone would reject the retry, but the product needs an ambiguous
        -- edge timeout to return the already-committed group as success.
        perform pg_advisory_xact_lock(hashtextextended(stable_formation_key, 0));
        select id into new_group_id
        from public.groups where formation_key = stable_formation_key;
        if found then
            return new_group_id;
        end if;
    end if;

    insert into public.groups (
        event_at, venue, activity, seed_distance,
        matching_run_key, formation_key, event_timezone
    )
    values (
        p_event_at, p_legacy_venue, p_activity, p_seed_distance,
        p_run_key, stable_formation_key, p_event_timezone
    )
    returning id into new_group_id;

    insert into public.group_members (group_id, user_id, matching_run_key)
    select new_group_id, x.user_id, p_run_key
    from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text);

    insert into public.member_assignments (group_id, user_id, target_id, question)
    select new_group_id, x.user_id, x.target_id, x.question
    from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text);

    insert into public.rsvps (group_id, user_id, status)
    select new_group_id, x.user_id, 'pending'
    from jsonb_to_recordset(p_members) x(user_id uuid, target_id uuid, question text);

    return new_group_id;
end;
$$;

revoke all on function public.form_group(timestamptz, jsonb, text, real, jsonb, text, text)
    from public, anon, authenticated;
grant execute on function public.form_group(timestamptz, jsonb, text, real, jsonb, text, text)
    to service_role;

-- -----------------------------------------------------------------------------
-- Chat kinds and grounded venue options
-- -----------------------------------------------------------------------------

-- Product contracts own the shared kind/author invariant. Chat hardening follows as 0004 and
-- may add delivery metadata such as client_msg_id, but it must not redefine which messages are
-- allowed to impersonate a user. Keeping that ownership here prevents edge-generated system
-- rows and app-authored rows from drifting into incompatible shapes.
alter table public.messages add column if not exists kind text not null default 'user';
alter table public.messages alter column user_id drop not null;
do $$ begin
    alter table public.messages add constraint messages_kind_known
        check (kind in ('user', 'venue_vote', 'system'));
exception when duplicate_object then null;
end $$;
do $$ begin
    alter table public.messages add constraint messages_author_matches_kind check (
        (kind = 'user' and user_id is not null)
        or (kind <> 'user' and user_id is null)
    );
exception when duplicate_object then null;
end $$;

create table public.venue_options (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.groups on delete cascade,
    position smallint not null check (position between 1 and 3),
    provider_id text not null,
    name text not null,
    kind text not null,
    address text not null,
    locality text not null default '',
    lat double precision not null check (lat between -90 and 90),
    lng double precision not null check (lng between -180 and 180),
    pitch text not null,
    score real,
    member_scores jsonb not null default '[]'::jsonb
        check (jsonb_typeof(member_scores) = 'array'),
    unique (group_id, position),
    unique (group_id, id),
    unique (group_id, provider_id)
);

alter table public.groups add constraint groups_chosen_venue_fkey
    foreign key (id, chosen_venue_id)
    references public.venue_options (group_id, id);

create table public.venue_votes (
    group_id uuid not null,
    user_id uuid not null,
    option_id uuid not null,
    voted_at timestamptz not null default now(),
    primary key (group_id, user_id),
    foreign key (group_id, user_id)
        references public.group_members (group_id, user_id) on delete cascade,
    foreign key (group_id, option_id)
        references public.venue_options (group_id, id) on delete cascade
);

alter table public.venue_options enable row level security;
alter table public.venue_votes enable row level security;

create policy "read own group venue options"
    on public.venue_options for select to authenticated
    using (group_id in (select public.my_group_ids()));

-- A caller can inspect only their own ballot. Counts come from venue_tally(), whose return
-- type contains no user id, so anonymity is enforced at the API boundary.
create policy "read own venue vote"
    on public.venue_votes for select to authenticated
    using (user_id = auth.uid());
create policy "cast own venue vote"
    on public.venue_votes for insert to authenticated
    with check (user_id = auth.uid() and group_id in (select public.my_group_ids()));
create policy "change own venue vote"
    on public.venue_votes for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid() and group_id in (select public.my_group_ids()));

grant select on public.venue_options to authenticated;
grant select, insert, update on public.venue_votes to authenticated;

create or replace function public.venue_tally(grp uuid)
returns table (option_id uuid, votes bigint)
language sql stable security definer set search_path = public as $$
    select o.id, count(v.user_id)
    from public.venue_options o
    left join public.venue_votes v
      on v.group_id = o.group_id and v.option_id = o.id
    where o.group_id = grp
      and exists (
          select 1 from public.group_members m
          where m.group_id = grp and m.user_id = auth.uid()
      )
    group by o.position, o.id
    order by o.position;
$$;

-- This is the persistence protocol for the independent venue pipeline. It accepts that edge
-- function's JSON response verbatim, validates the 2-3 option invariant, and owns the chat
-- message that makes the vote visible. Retrieval code therefore never needs to know Flutter's
-- row-decoding choices.
create or replace function public.replace_venue_options(grp uuid, options jsonb)
returns setof public.venue_options
language plpgsql security definer set search_path = public as $$
begin
    if options is null
       or jsonb_typeof(options) <> 'array'
       or jsonb_array_length(options) not between 2 and 3 then
        raise exception 'venue options must be a JSON array with 2 or 3 entries'
            using errcode = '22023';
    end if;

    -- Lock the group row before checking votes. Without one serialization point, two venue jobs
    -- can both observe an empty ballot, replace different option sets, and leave the last writer
    -- as an accidental source of truth.
    perform 1 from public.groups where id = grp for update;
    if not found then
        raise exception 'unknown group %', grp using errcode = '23503';
    end if;

    if exists (select 1 from public.venue_votes where group_id = grp)
       or exists (
           select 1 from public.groups where id = grp and chosen_venue_id is not null
       ) then
        raise exception 'venue options cannot be replaced after voting starts'
            using errcode = '55000';
    end if;

    -- A second worker can finish expensive retrieval while the first one commits. Once the lock
    -- is acquired, the committed ballot wins unchanged; deleting it here made a retry silently
    -- swap choices that a member could already be reading. The edge function has a cache fast
    -- path, but this lock-protected branch is the actual race-safety boundary.
    if exists (select 1 from public.venue_options where group_id = grp) then
        return query
            select * from public.venue_options where group_id = grp order by position;
        return;
    end if;

    insert into public.venue_options (
        group_id, position, provider_id, name, kind, address, locality,
        lat, lng, pitch, score, member_scores
    )
    select
        grp, x.position, x.venue_id, x.name, x.kind, x.address,
        coalesce(x.locality, ''), x.lat, x.lng, x.pitch, x.score,
        coalesce(x.per_member, '[]'::jsonb)
    from jsonb_to_recordset(options) as x(
        position smallint,
        venue_id text,
        name text,
        kind text,
        address text,
        locality text,
        lat double precision,
        lng double precision,
        pitch text,
        score real,
        per_member jsonb
    );

    if (select count(*) from public.venue_options where group_id = grp)
       <> jsonb_array_length(options) then
        raise exception 'venue options were not persisted completely'
            using errcode = '23514';
    end if;

    insert into public.messages (group_id, user_id, body, kind)
    select grp, null, '', 'venue_vote'
    where not exists (
        select 1 from public.messages where group_id = grp and kind = 'venue_vote'
    );

    update public.groups set venue_status = 'voting' where id = grp;

    return query
        select * from public.venue_options where group_id = grp order by position;
end;
$$;

revoke all on function public.replace_venue_options(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.replace_venue_options(uuid, jsonb) to service_role;
revoke all on function public.venue_tally(uuid) from public, anon;
grant execute on function public.venue_tally(uuid) to authenticated;

-- A tally is not a decision. Finalization lives in Postgres so every device observes one winner,
-- ties resolve deterministically, and notifications never invent a destination by choosing the
-- first option. The last ballot triggers it only when all current members have voted; before that
-- point votes remain editable and no destination is authoritative.
create or replace function public.finalize_venue_vote(grp uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    winner uuid;
    member_count integer;
    vote_count integer;
begin
    perform 1 from public.groups where id = grp for update;
    if not found then
        raise exception 'unknown group %', grp using errcode = '23503';
    end if;

    select count(*) into member_count
    from public.group_members where group_id = grp;
    select count(*) into vote_count
    from public.venue_votes where group_id = grp;

    if vote_count <> member_count or member_count = 0 then
        return null;
    end if;

    select o.id into winner
    from public.venue_options o
    left join public.venue_votes v
      on v.group_id = o.group_id and v.option_id = o.id
    where o.group_id = grp
    group by o.id, o.position, o.score
    order by count(v.user_id) desc, o.score desc nulls last, o.position
    limit 1;

    update public.groups
    set chosen_venue_id = winner, venue_status = 'chosen'
    where id = grp and chosen_venue_id is null;

    insert into public.messages (group_id, user_id, body, kind)
    select grp, null, 'The group picked a venue.', 'system'
    where winner is not null
      and not exists (
          select 1 from public.messages
          where group_id = grp and kind = 'system' and body = 'The group picked a venue.'
      );

    return winner;
end;
$$;

create or replace function public.finalize_venue_vote_after_ballot()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    perform public.finalize_venue_vote(new.group_id);
    return new;
end;
$$;

create trigger finalize_venue_vote_after_ballot
after insert or update of option_id on public.venue_votes
for each row execute function public.finalize_venue_vote_after_ballot();

create or replace function public.reject_vote_after_venue_finalized()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    -- Serialize the ballot write before reading the winner. Locking only in the AFTER trigger
    -- leaves a race where a revote passes this check, waits behind the final ballot, then commits
    -- after the destination is already announced. The same transaction can safely acquire this
    -- row again inside finalize_venue_vote().
    perform 1 from public.groups where id = new.group_id for update;
    if not found then
        raise exception 'unknown group %', new.group_id using errcode = '23503';
    end if;
    if exists (
        select 1 from public.groups
        where id = new.group_id and chosen_venue_id is not null
    ) then
        raise exception 'venue voting is already finalized' using errcode = '55000';
    end if;
    return new;
end;
$$;

create trigger reject_vote_after_venue_finalized
before insert or update of option_id on public.venue_votes
for each row execute function public.reject_vote_after_venue_finalized();

revoke all on function public.finalize_venue_vote(uuid) from public, anon, authenticated;
revoke all on function public.finalize_venue_vote_after_ballot() from public, anon, authenticated;
revoke all on function public.reject_vote_after_venue_finalized() from public, anon, authenticated;
grant execute on function public.finalize_venue_vote(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- Post-meetup ballots and mutual contact exchange
-- -----------------------------------------------------------------------------

-- 0002 created these tables with profile-only foreign keys. That proves the UUID exists but
-- not that it belongs to this group, allowing a hostile client to submit attendance/contact
-- rows about outsiders. Upgrade the deployed tables to the composite membership invariant.
alter table public.attendance_votes
    drop constraint if exists attendance_votes_group_id_fkey,
    drop constraint if exists attendance_votes_voter_id_fkey,
    drop constraint if exists attendance_votes_subject_id_fkey,
    add constraint attendance_voter_member_fkey
        foreign key (group_id, voter_id)
        references public.group_members (group_id, user_id) on delete cascade,
    add constraint attendance_subject_member_fkey
        foreign key (group_id, subject_id)
        references public.group_members (group_id, user_id) on delete cascade;

alter table public.contact_selections
    drop constraint if exists contact_selections_group_id_fkey,
    drop constraint if exists contact_selections_selector_id_fkey,
    drop constraint if exists contact_selections_selected_id_fkey,
    add constraint contact_selector_member_fkey
        foreign key (group_id, selector_id)
        references public.group_members (group_id, user_id) on delete cascade,
    add constraint contact_selected_member_fkey
        foreign key (group_id, selected_id)
        references public.group_members (group_id, user_id) on delete cascade;

alter table public.attendance_votes enable row level security;
alter table public.contact_selections enable row level security;

-- Replace 0002's FOR ALL policies. Their USING clauses constrained the author but did not
-- validate that the subject belonged to the same group; named drops make the privilege delta
-- visible and keep old broad policies from remaining active alongside the stricter ones.
drop policy if exists "read own attendance votes" on public.attendance_votes;
drop policy if exists "cast own attendance votes" on public.attendance_votes;
drop policy if exists "change own attendance votes" on public.attendance_votes;
drop policy if exists "read own selections" on public.contact_selections;
drop policy if exists "make own selections" on public.contact_selections;
drop policy if exists "read own contact selections" on public.contact_selections;

create policy "read own attendance votes"
    on public.attendance_votes for select to authenticated
    using (voter_id = auth.uid());
create policy "cast own attendance votes"
    on public.attendance_votes for insert to authenticated
    with check (voter_id = auth.uid() and group_id in (select public.my_group_ids()));
create policy "change own attendance votes"
    on public.attendance_votes for update to authenticated
    using (voter_id = auth.uid())
    with check (voter_id = auth.uid() and group_id in (select public.my_group_ids()));

-- One-way choices are readable only by their author. In particular there is no policy for
-- selected_id = auth.uid(); that seemingly helpful policy would make rejection observable.
create policy "read own contact selections"
    on public.contact_selections for select to authenticated
    using (selector_id = auth.uid());

grant select, insert, update on public.attendance_votes to authenticated;
grant select on public.contact_selections to authenticated;
revoke delete on public.attendance_votes from authenticated;
revoke insert, update, delete on public.contact_selections from authenticated;

create or replace function public.attendance_result(grp uuid)
returns table (subject_id uuid, showed_up bigint, total bigint)
language sql stable security definer set search_path = public as $$
    select a.subject_id, count(*) filter (where a.showed_up), count(*)
    from public.attendance_votes a
    where a.group_id = grp
      and exists (
          select 1 from public.group_members m
          where m.group_id = grp and m.user_id = auth.uid()
      )
    group by a.subject_id;
$$;

-- Replacement, including deselection, must be one transaction. A sequence of client deletes
-- and inserts can leave stale one-way choices when the app is backgrounded between requests.
create or replace function public.set_contact_selections(grp uuid, selected uuid[])
returns void
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is null or not exists (
        select 1 from public.group_members
        where group_id = grp and user_id = auth.uid()
    ) then
        raise exception 'not a member of group %', grp using errcode = '42501';
    end if;

    if auth.uid() = any(coalesce(selected, '{}'::uuid[]))
       or exists (
           select 1 from unnest(coalesce(selected, '{}'::uuid[])) s(id)
           where not exists (
               select 1 from public.group_members m
               where m.group_id = grp and m.user_id = s.id
           )
       ) then
        raise exception 'every selected contact must be another member of the group'
            using errcode = '23514';
    end if;

    delete from public.contact_selections
    where group_id = grp and selector_id = auth.uid();

    insert into public.contact_selections (group_id, selector_id, selected_id)
    select grp, auth.uid(), id
    from unnest(coalesce(selected, '{}'::uuid[])) s(id);
end;
$$;

-- 0002's function omitted avatar from its return row. PostgreSQL cannot replace a function
-- while changing its return type, so the signature must be deliberately retired first.
drop function if exists public.mutual_contacts(uuid);
create function public.mutual_contacts(grp uuid)
returns table (
    user_id uuid,
    display_name text,
    avatar text,
    photo_url text,
    phone text
)
language sql stable security definer set search_path = public as $$
    select p.id, p.display_name, p.avatar, p.photo_url, p.phone
    from public.contact_selections mine
    join public.contact_selections theirs
      on theirs.group_id = mine.group_id
     and theirs.selector_id = mine.selected_id
     and theirs.selected_id = mine.selector_id
    join public.profiles p on p.id = mine.selected_id
    where mine.group_id = grp
      and mine.selector_id = auth.uid()
      and p.phone is not null;
$$;

revoke all on function public.attendance_result(uuid) from public, anon;
revoke all on function public.set_contact_selections(uuid, uuid[]) from public, anon;
revoke all on function public.mutual_contacts(uuid) from public, anon;
grant execute on function public.attendance_result(uuid) to authenticated;
grant execute on function public.set_contact_selections(uuid, uuid[]) to authenticated;
grant execute on function public.mutual_contacts(uuid) to authenticated;

-- Retire the old "share once, see everyone who shared" model. Policies and helper functions
-- depend on the table, so they must be removed first; the draft had the order backwards and
-- could not be applied by Postgres.
do $$
begin
    if to_regclass('public.number_shares') is not null then
        execute 'drop policy if exists "reciprocal disclosure only" on public.number_shares';
        execute 'drop policy if exists "share own number" on public.number_shares';
    end if;
end;
$$;
drop function if exists public.has_shared_number(uuid);
drop table if exists public.number_shares;

-- A fallback reflection has no assigned target because that person did not attend. Keeping a
-- fabricated about_user would disclose the note to the wrong person, so null is meaningful.
alter table public.reflections add column if not exists was_fallback boolean not null default false;
alter table public.reflections alter column about_user drop not null;
alter table public.reflections add constraint reflections_target_shape check (
    (was_fallback and about_user is null)
    or (not was_fallback and about_user is not null)
);
alter table public.reflections add constraint reflections_target_member_fkey
    foreign key (group_id, about_user)
    references public.group_members (group_id, user_id) on delete cascade not valid;

drop policy if exists "write own reflection" on public.reflections;
drop policy if exists "edit own reflection" on public.reflections;
drop policy if exists "change own reflection" on public.reflections;
create policy "write own reflection"
    on public.reflections for insert to authenticated
    with check (user_id = auth.uid() and group_id in (select public.my_group_ids()));
create policy "change own reflection"
    on public.reflections for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid() and group_id in (select public.my_group_ids()));

-- `profiles` must remain group-readable, but a table-level SELECT grant includes `phone` even
-- when every app query politely omits it. Replace that grant with an explicit public-profile
-- column list; security-definer mutual_contacts can still read the private column.
revoke select on public.profiles from anon, authenticated;
grant select (
    id, display_name, passion, tags, city, availability, photo_url,
    embedded_at, created_at, avatar
) on public.profiles to authenticated;

-- `FOR ALL` included DELETE, which let a direct PostgREST caller erase their profile and cascade
-- an active group below its 4-person invariant without deleting the auth identity or Storage
-- object. Account erasure needs one coordinated server protocol, so ordinary clients may create
-- and edit a profile but cannot perform a partial deletion.
drop policy "write own profile" on public.profiles;
create policy "insert own profile" on public.profiles for insert to authenticated
    with check (id = auth.uid());
create policy "update own profile" on public.profiles for update to authenticated
    using (id = auth.uid()) with check (id = auth.uid());

-- -----------------------------------------------------------------------------
-- Private profile-photo storage
-- -----------------------------------------------------------------------------

-- These exact policies came from the repository's old manual setup. Changing the bucket flag
-- alone is not an upgrade: a pre-existing unrestricted SELECT policy would keep public objects
-- readable after this migration and make fresh/reset databases safer than the real project.
drop policy if exists "photos are public" on storage.objects;
drop policy if exists "own photo upload" on storage.objects;
drop policy if exists "own photo update" on storage.objects;

insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do update set public = excluded.public;

create policy "upload own profile photo"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );
create policy "update own profile photo"
    on storage.objects for update to authenticated
    using (
        bucket_id = 'photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
        bucket_id = 'photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );
create policy "delete own profile photo"
    on storage.objects for delete to authenticated
    using (
        bucket_id = 'photos'
        and (storage.foldername(name))[1] = auth.uid()::text
    );
create policy "read own or groupmate profile photo"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'photos'
        and case
            when (storage.foldername(name))[1]
                 ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (storage.foldername(name))[1] = auth.uid()::text
                 or public.shares_any_group_with((storage.foldername(name))[1]::uuid)
            else false
        end
    );

-- Realtime still applies each subscriber's RLS policy. Manual environments sometimes add a
-- table before migrations reach them, so guard membership rather than making recovery fail with
-- "relation is already member of publication".
do $$ begin
    if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'venue_votes'
    ) then
        alter publication supabase_realtime add table public.venue_votes;
    end if;
end $$;
