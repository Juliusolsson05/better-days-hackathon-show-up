-- Real venue options and anonymous group voting.
--
-- ClickHouse chooses candidates; Postgres owns the decision. Keeping that boundary matters:
-- options, ballots, and the winner are user-visible transactional state, so they must remain
-- correct even if ClickHouse is asleep or an Edge Function retries halfway through a request.

-- The vote is rendered inside the chat. Server-authored cards have no human author, which is
-- why user_id becomes nullable. A client still cannot impersonate the server: the replacement
-- insert policy below permits authenticated users to create only ordinary messages as self.
alter table messages add column if not exists kind text not null default 'user'
    check (kind in ('user', 'venue_vote', 'system'));
alter table messages alter column user_id drop not null;

drop policy if exists "post as self" on messages;
create policy "post as self" on messages for insert
    with check (
        user_id = auth.uid()
        and kind = 'user'
        and group_id in (select my_group_ids())
    );

create table venue_options (
    id                uuid primary key default gen_random_uuid(),
    group_id          uuid not null references groups on delete cascade,
    position          smallint not null check (position between 1 and 3),
    source_venue_id   text not null,
    name              text not null,
    taxonomy_primary  text not null,
    address           text not null,
    locality          text not null,
    lat               double precision not null check (lat between -90 and 90),
    lng               double precision not null check (lng between -180 and 180),
    score             double precision not null,
    per_member_scores jsonb not null default '[]'::jsonb
        check (jsonb_typeof(per_member_scores) = 'array'),
    pitch             text not null,
    created_at        timestamptz not null default now(),
    unique (group_id, position),
    unique (group_id, source_venue_id),
    -- The redundant-looking pair is the target for composite foreign keys below. It is what
    -- lets Postgres prove that a ballot or winner belongs to the same group as its option;
    -- checking group_id and option_id independently would permit cross-group votes.
    unique (group_id, id)
);

create table venue_votes (
    group_id  uuid not null references groups on delete cascade,
    user_id   uuid not null references profiles on delete cascade,
    option_id uuid not null,
    voted_at  timestamptz not null default now(),
    primary key (group_id, user_id),
    foreign key (group_id, option_id)
        references venue_options (group_id, id) on delete cascade
);

-- A separate one-row relation avoids a circular groups -> option -> groups foreign-key
-- lifecycle. It also means old groups with only groups.venue remain valid during rollout.
create table venue_selections (
    group_id   uuid primary key references groups on delete cascade,
    option_id  uuid not null,
    selected_at timestamptz not null default now(),
    foreign key (group_id, option_id)
        references venue_options (group_id, id) on delete cascade
);

alter table venue_options    enable row level security;
alter table venue_votes      enable row level security;
alter table venue_selections enable row level security;

create policy "read own group venue options" on venue_options for select
    using (group_id in (select my_group_ids()));

-- Ballots stay private even from groupmates. The group sees only venue_tally(), whose result
-- contains option IDs and counts but never voter IDs.
create policy "read own venue vote" on venue_votes for select
    using (user_id = auth.uid() and group_id in (select my_group_ids()));

create policy "read own group venue selection" on venue_selections for select
    using (group_id in (select my_group_ids()));

create or replace function public.install_group_venue_options(grp uuid, options jsonb)
returns setof venue_options
language plpgsql
security definer
set search_path = public
as $$
begin
    -- A transaction-level lock makes concurrent function retries converge before either one
    -- spends a write. The second caller returns the already-installed ballot instead of
    -- producing a duplicate chat card. The Edge Function also checks before embedding, but
    -- only the database can close the race between two separate instances.
    perform pg_advisory_xact_lock(hashtextextended(grp::text, 0));

    if not exists (select 1 from groups where id = grp) then
        raise exception 'group % does not exist', grp using errcode = '23503';
    end if;

    if exists (select 1 from venue_options where group_id = grp) then
        return query
            select o.* from venue_options o where o.group_id = grp order by o.position;
        return;
    end if;

    if options is null
       or jsonb_typeof(options) <> 'array'
       or jsonb_array_length(options) not between 2 and 3 then
        raise exception 'venue options must be a JSON array containing two or three rows'
            using errcode = '22023';
    end if;

    -- Position comes from array order instead of trusting a caller-supplied number. That makes
    -- the displayed order, tie-break order, and stored order one deterministic contract.
    insert into venue_options (
        group_id, position, source_venue_id, name, taxonomy_primary, address, locality,
        lat, lng, score, per_member_scores, pitch
    )
    select
        grp,
        item.ordinality::smallint,
        item.value->>'venue_id',
        item.value->>'name',
        -- taxonomy_primary is the stable machine value used for diversification. `kind` is
        -- accepted as a rollout fallback for older callers that sent only display copy.
        coalesce(item.value->>'taxonomy_primary', item.value->>'kind'),
        item.value->>'address',
        item.value->>'locality',
        (item.value->>'lat')::double precision,
        (item.value->>'lng')::double precision,
        (item.value->>'score')::double precision,
        coalesce(item.value->'per_member', '[]'::jsonb),
        item.value->>'pitch'
    from jsonb_array_elements(options) with ordinality as item(value, ordinality);

    -- Option rows and the chat card commit together. A failure after either statement rolls
    -- both back, so a group cannot have an invisible ballot or a card with no options.
    insert into messages (group_id, user_id, body, kind)
    values (grp, null, '', 'venue_vote');

    return query
        select o.* from venue_options o where o.group_id = grp order by o.position;
end;
$$;

-- Installation is an internal orchestration primitive, not a client API. The Edge Function
-- carries the service role; authenticated phones never receive permission to manufacture or
-- replace the retrieved options.
revoke all on function public.install_group_venue_options(uuid, jsonb) from public;
revoke all on function public.install_group_venue_options(uuid, jsonb) from anon;
revoke all on function public.install_group_venue_options(uuid, jsonb) from authenticated;
grant execute on function public.install_group_venue_options(uuid, jsonb) to service_role;

create or replace function public.cast_venue_vote(grp uuid, chosen uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    caller uuid := auth.uid();
    member_count integer;
    ballot_count integer;
    winner uuid;
begin
    if caller is null or not exists (
        select 1 from group_members where group_id = grp and user_id = caller
    ) then
        raise exception 'not a member of group %', grp using errcode = '42501';
    end if;

    if not exists (
        select 1 from venue_options where group_id = grp and id = chosen
    ) then
        raise exception 'option % does not belong to group %', chosen, grp
            using errcode = '22023';
    end if;

    -- Serialize votes for the same group so two final ballots cannot compute different
    -- winners. One ballot per member is still changeable: the latest choice wins.
    perform pg_advisory_xact_lock(hashtextextended(grp::text, 0));
    insert into venue_votes (group_id, user_id, option_id)
    values (grp, caller, chosen)
    on conflict (group_id, user_id) do update
        set option_id = excluded.option_id, voted_at = now();

    select count(*) into member_count from group_members where group_id = grp;
    select count(*) into ballot_count from venue_votes where group_id = grp;

    -- A partial tally is not a result. Once everyone has voted, highest count wins; displayed
    -- position breaks ties. Re-voting after completion recomputes the same deterministic rule.
    if member_count > 0 and ballot_count = member_count then
        select o.id into winner
        from venue_options o
        left join venue_votes v
          on v.group_id = o.group_id and v.option_id = o.id
        where o.group_id = grp
        group by o.id, o.position
        order by count(v.user_id) desc, o.position asc
        limit 1;

        insert into venue_selections (group_id, option_id)
        values (grp, winner)
        on conflict (group_id) do update
            set option_id = excluded.option_id, selected_at = now();
    end if;

    return winner;
end;
$$;

revoke all on function public.cast_venue_vote(uuid, uuid) from public;
revoke all on function public.cast_venue_vote(uuid, uuid) from anon;
grant execute on function public.cast_venue_vote(uuid, uuid) to authenticated;
grant execute on function public.cast_venue_vote(uuid, uuid) to service_role;

create or replace function public.venue_tally(grp uuid)
returns table (option_id uuid, votes bigint)
language sql
stable
security definer
set search_path = public
as $$
    select o.id, count(v.user_id)
    from venue_options o
    left join venue_votes v
      on v.group_id = o.group_id and v.option_id = o.id
    where o.group_id = grp
      and exists (
          select 1 from group_members m
          where m.group_id = grp and m.user_id = auth.uid()
      )
    group by o.id, o.position
    order by o.position;
$$;

revoke all on function public.venue_tally(uuid) from public;
revoke all on function public.venue_tally(uuid) from anon;
grant execute on function public.venue_tally(uuid) to authenticated;
grant execute on function public.venue_tally(uuid) to service_role;
