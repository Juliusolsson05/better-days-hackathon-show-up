-- Make "after the meetup" a server-owned fact and seal the final contact decision.
--
-- The app already waits until groups.event_at before showing the after-flow, but Flutter is not an
-- authorization boundary: every authenticated user can call PostgREST and RPCs directly. Without
-- the checks below, a modified client can submit attendance and reflections for a future event, or
-- temporarily select each groupmate, inspect mutual_contacts(), and then erase the choices used to
-- discover who had selected them. That makes both the lifecycle and one-way-choice privacy depend
-- on polite client behavior.

-- One predicate owns the time and membership rule used by direct attendance writes and RPCs. It is
-- SECURITY DEFINER for the same reason as my_group_ids(): using group_members from a policy on a
-- group-scoped table must not accidentally recurse through that table's RLS. Returning one boolean
-- also avoids distinguishing "unknown group", "not a member", and "not started yet" to callers.
create or replace function public.has_post_meetup_access(grp uuid)
returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from public.groups g
        join public.group_members m on m.group_id = g.id
        where g.id = grp
          and m.user_id = auth.uid()
          and g.event_at <= now()
    );
$$;

revoke all on function public.has_post_meetup_access(uuid)
    from public, anon, authenticated;
grant execute on function public.has_post_meetup_access(uuid) to authenticated;

-- Attendance remains a directly upserted relation because a submission is one row per groupmate.
-- Replace both policies rather than adding a second permissive policy: PostgreSQL ORs permissive
-- policies, so leaving the old membership-only policy in place would silently bypass the time gate.
drop policy if exists "cast own attendance votes" on public.attendance_votes;
drop policy if exists "change own attendance votes" on public.attendance_votes;

create policy "cast own post-meetup attendance votes"
    on public.attendance_votes for insert to authenticated
    with check (
        voter_id = auth.uid()
        and public.has_post_meetup_access(group_id)
    );
create policy "change own post-meetup attendance votes"
    on public.attendance_votes for update to authenticated
    using (
        voter_id = auth.uid()
        and public.has_post_meetup_access(group_id)
    )
    with check (
        voter_id = auth.uid()
        and public.has_post_meetup_access(group_id)
    );

-- Reflection submission already derives author and recipient inside Postgres. Preserve that narrow
-- boundary while adding the lifecycle check before any private prose is written. The generic error
-- deliberately does not reveal whether an arbitrary group UUID exists or merely has not happened.
create or replace function public.submit_reflection(
    grp uuid,
    reflection_text text,
    fallback boolean default false
)
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    assigned_target uuid;
begin
    if caller is null or not public.has_post_meetup_access(grp) then
        raise exception 'post-meetup access is unavailable' using errcode = '42501';
    end if;

    if nullif(btrim(reflection_text), '') is null then
        raise exception 'reflection cannot be blank' using errcode = '22023';
    end if;

    if fallback then
        assigned_target := null;
    else
        select target_id into assigned_target
        from public.member_assignments
        where group_id = grp and user_id = caller;

        if not found then
            -- Guessing a recipient would disclose private prose to the wrong person. A group with
            -- an incomplete assignment needs repair, not a client-side fallback identity.
            raise exception 'private assignment missing for group %', grp using errcode = '55000';
        end if;
    end if;

    insert into public.reflections (
        group_id, user_id, about_user, what_stuck, was_fallback
    ) values (
        grp, caller, assigned_target, btrim(reflection_text), fallback
    )
    on conflict (group_id, user_id) do update
    set about_user = excluded.about_user,
        what_stuck = excluded.what_stuck,
        was_fallback = excluded.was_fallback;
end;
$$;

revoke all on function public.submit_reflection(uuid, text, boolean)
    from public, anon, authenticated;
grant execute on function public.submit_reflection(uuid, text, boolean) to authenticated;

-- The contact step is a set replacement only until its first successful completion. The membership
-- row is the per-user/per-group serialization point: two requests that arrive together cannot both
-- pass the "not completed" check, delete independently, and leave the union of two intended sets.
-- Once complete, an exact replay is still success because a client may lose the HTTP response after
-- commit. A different set is rejected, closing the select/read/deselect probing channel without
-- turning an ambiguous network retry into a user-visible failure. An empty first set is normalized
-- to {} and persisted through after_flow_completions even though it creates no selection rows.
create or replace function public.set_contact_selections(grp uuid, selected uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    requested uuid[];
    persisted uuid[];
begin
    select coalesce(array_agg(candidate.id order by candidate.id), '{}'::uuid[])
    into requested
    from (
        select distinct choice.id
        from unnest(coalesce(selected, '{}'::uuid[])) choice(id)
    ) candidate;

    -- Locking the caller's durable membership scopes contention to one person's submission. A
    -- group-wide lock would serialize unrelated members and is unnecessary for the invariant.
    perform 1
    from public.group_members m
    join public.groups g on g.id = m.group_id
    where m.group_id = grp
      and m.user_id = caller
      and g.event_at <= now()
    for update of m;
    if caller is null or not found then
        raise exception 'post-meetup access is unavailable' using errcode = '42501';
    end if;

    if caller = any(requested)
       or exists (
           select 1 from unnest(requested) choice(id)
           where choice.id is null
              or not exists (
                  select 1 from public.group_members member
                  where member.group_id = grp and member.user_id = choice.id
              )
       ) then
        raise exception 'every selected contact must be another member of the group'
            using errcode = '23514';
    end if;

    if exists (
        select 1 from public.after_flow_completions
        where group_id = grp and user_id = caller
    ) then
        select coalesce(array_agg(existing.selected_id order by existing.selected_id), '{}'::uuid[])
        into persisted
        from public.contact_selections existing
        where existing.group_id = grp and existing.selector_id = caller;

        if persisted = requested then
            return;
        end if;
        raise exception 'contact selections are already completed' using errcode = '55000';
    end if;

    delete from public.contact_selections
    where group_id = grp and selector_id = caller;

    insert into public.contact_selections (group_id, selector_id, selected_id)
    select grp, caller, choice.id
    from unnest(requested) choice(id);

    insert into public.after_flow_completions (group_id, user_id)
    values (grp, caller);
end;
$$;

revoke all on function public.set_contact_selections(uuid, uuid[])
    from public, anon, authenticated;
grant execute on function public.set_contact_selections(uuid, uuid[]) to authenticated;

-- The UI needs only the caller's private no-show verdict. attendance_result() exposed aggregate
-- rows for every group member, forcing the device to receive social data it immediately discarded.
-- Keep the threshold beside the ballots and return false for unavailable groups so the boolean RPC
-- cannot be used as a group-existence oracle.
create or replace function public.was_marked_no_show(grp uuid)
returns boolean
language sql stable security definer set search_path = public as $$
    select case
        when not public.has_post_meetup_access(grp) then false
        else (
            select count(*) >= 2
               and count(*) filter (where a.showed_up) * 2 < count(*)
            from public.attendance_votes a
            where a.group_id = grp and a.subject_id = auth.uid()
        )
    end;
$$;

revoke all on function public.was_marked_no_show(uuid)
    from public, anon, authenticated;
grant execute on function public.was_marked_no_show(uuid) to authenticated;

-- Retiring the broad RPC is part of adding the narrow one. Leaving it executable would preserve
-- the old data surface and make caller-only reads a client convention rather than an API boundary.
revoke execute on function public.attendance_result(uuid) from authenticated;
