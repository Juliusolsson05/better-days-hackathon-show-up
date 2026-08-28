-- Make a formed group one transactional database fact.
--
-- The matching algorithm and LLM live outside Postgres, but their accepted result spans
-- groups, group_members, and rsvps. Writing those tables in separate HTTP requests permits a
-- network failure to leave a group that is visible but incomplete. This RPC is deliberately
-- narrow: it does not perform matching, it only commits one already-decided result atomically.

create or replace function public.create_matched_group(
    meetup_at timestamptz,
    fallback_venue jsonb,
    group_activity text,
    distance real,
    member_rows jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    new_group_id uuid;
    requested_count integer;
    unique_count integer;
begin
    if jsonb_typeof(member_rows) <> 'array' then
        raise exception 'member_rows must be a JSON array' using errcode = '22023';
    end if;

    requested_count := jsonb_array_length(member_rows);
    if requested_count not between 4 and 6 then
        raise exception 'a group must contain between four and six members'
            using errcode = '22023';
    end if;

    select count(distinct x.user_id) into unique_count
    from jsonb_to_recordset(member_rows)
      as x(user_id uuid, pair_with uuid, question text);
    if unique_count <> requested_count then
        raise exception 'group members must be unique' using errcode = '22023';
    end if;

    if exists (
        select 1
        from jsonb_to_recordset(member_rows)
          as x(user_id uuid, pair_with uuid, question text)
        where x.pair_with is null
           or x.pair_with = x.user_id
           or x.question is null
           or btrim(x.question) = ''
           or not exists (
               select 1
               from jsonb_to_recordset(member_rows)
                 as peer(user_id uuid, pair_with uuid, question text)
               where peer.user_id = x.pair_with
           )
    ) then
        raise exception 'every member needs a different in-group pair and a question'
            using errcode = '22023';
    end if;

    -- Lock profiles in UUID order so concurrent sweeps cannot both pass the availability
    -- check and assign the same person. The application-side pool filter is only an
    -- optimisation; this lock plus the membership check is the correctness boundary.
    perform p.id
    from profiles p
    join jsonb_to_recordset(member_rows)
      as x(user_id uuid, pair_with uuid, question text) on x.user_id = p.id
    order by p.id
    for update;

    if (select count(*)
        from profiles p
        join jsonb_to_recordset(member_rows)
          as x(user_id uuid, pair_with uuid, question text) on x.user_id = p.id
       ) <> requested_count then
        raise exception 'one or more group members do not exist' using errcode = '23503';
    end if;

    -- There is no meetup-history/current-group distinction in the schema yet, and the app's
    -- currentGroup() intentionally expects one membership. Until reshuffling introduces that
    -- lifecycle, refusing a second assignment is safer than returning an arbitrary group.
    if exists (
        select 1 from group_members gm
        join jsonb_to_recordset(member_rows)
          as x(user_id uuid, pair_with uuid, question text) on x.user_id = gm.user_id
    ) then
        raise exception 'one or more profiles already belong to a group'
            using errcode = '23505';
    end if;

    insert into groups (event_at, venue, activity, cohesion)
    values (meetup_at, fallback_venue, group_activity, distance)
    returning id into new_group_id;

    insert into group_members (group_id, user_id, pair_with, question)
    select new_group_id, x.user_id, x.pair_with, x.question
    from jsonb_to_recordset(member_rows)
      as x(user_id uuid, pair_with uuid, question text);

    insert into rsvps (group_id, user_id, status)
    select new_group_id, x.user_id, 'pending'
    from jsonb_to_recordset(member_rows)
      as x(user_id uuid, pair_with uuid, question text);

    return new_group_id;
end;
$$;

-- This function assigns other users and therefore must never be executable with the anon or
-- authenticated role embedded in the app. Only the trusted matching function carries the
-- service role needed to call it.
revoke all on function public.create_matched_group(timestamptz, jsonb, text, real, jsonb)
    from public;
revoke all on function public.create_matched_group(timestamptz, jsonb, text, real, jsonb)
    from anon;
revoke all on function public.create_matched_group(timestamptz, jsonb, text, real, jsonb)
    from authenticated;
grant execute on function public.create_matched_group(timestamptz, jsonb, text, real, jsonb)
    to service_role;
