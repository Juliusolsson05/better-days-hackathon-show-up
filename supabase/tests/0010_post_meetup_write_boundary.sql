-- Prove the post-meetup lifecycle against the authenticated API role. Owner-only integrity tests
-- bypass RLS by design, so they cannot establish that a caller is denied before event_at or that a
-- completed contact set cannot be changed through the public RPC.

do $$
begin
    if not has_function_privilege(
        'authenticated', 'public.has_post_meetup_access(uuid)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.has_post_meetup_access(uuid)', 'execute'
    ) then
        raise exception 'post-meetup access predicate has the wrong execution boundary';
    end if;

    if not has_function_privilege(
        'authenticated', 'public.was_marked_no_show(uuid)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.was_marked_no_show(uuid)', 'execute'
    ) or has_function_privilege(
        'authenticated', 'public.attendance_result(uuid)', 'execute'
    ) then
        raise exception 'attendance reads still expose more than the caller-only verdict';
    end if;
end;
$$;

-- The shared fixture is intentionally moved back into the future only for the denial cases below.
-- Its other contract tests need a completed meetup now that writes are server-gated.
update public.groups
set event_at = now() + interval '1 day'
where id = current_setting('showup.test.group_two')::uuid;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000005',
    true
);
do $$
declare
    future_group uuid := current_setting('showup.test.group_two')::uuid;
begin
    if public.has_post_meetup_access(future_group)
       or public.was_marked_no_show(future_group) then
        raise exception 'future meetup exposed post-meetup access or a no-show verdict';
    end if;

    begin
        perform public.submit_reflection(future_group, 'This event has not happened.', false);
        raise exception 'future reflection unexpectedly succeeded';
    exception when insufficient_privilege then
        null;
    end;

    begin
        perform public.set_contact_selections(future_group, '{}'::uuid[]);
        raise exception 'future contact completion unexpectedly succeeded';
    exception when insufficient_privilege then
        null;
    end;

    begin
        insert into public.attendance_votes (group_id, voter_id, subject_id, showed_up)
        values (
            future_group,
            auth.uid(),
            '00000000-0000-4000-8000-000000000006'::uuid,
            true
        );
        raise exception 'future attendance vote unexpectedly succeeded';
    exception when insufficient_privilege then
        null;
    end;

    if exists (
        select 1 from public.after_flow_completions
        where group_id = future_group and user_id = auth.uid()
    ) then
        raise exception 'denied future contact request left a completion row';
    end if;
end;
$$;
reset role;

-- Seed two private ballots as the owner so the caller-only RPC can prove its exact verdict without
-- granting the caller visibility into either source row or any other member's aggregate.
insert into public.attendance_votes (group_id, voter_id, subject_id, showed_up)
values
    (
        current_setting('showup.test.group_one')::uuid,
        '00000000-0000-4000-8000-000000000001'::uuid,
        '00000000-0000-4000-8000-000000000003'::uuid,
        false
    ),
    (
        current_setting('showup.test.group_one')::uuid,
        '00000000-0000-4000-8000-000000000002'::uuid,
        '00000000-0000-4000-8000-000000000003'::uuid,
        false
    )
on conflict (group_id, voter_id, subject_id) do update
set showed_up = excluded.showed_up;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000003',
    true
);
do $$
declare
    past_group uuid := current_setting('showup.test.group_one')::uuid;
begin
    if not public.has_post_meetup_access(past_group) then
        raise exception 'past meetup did not grant post-meetup access';
    end if;
    if not public.was_marked_no_show(past_group) then
        raise exception 'caller-only no-show RPC lost the existing two-vote threshold';
    end if;

    -- A zero-selection answer is still a real first submission. It must create the durable phase
    -- checkpoint even though there is deliberately no contact_selections row to count.
    perform public.set_contact_selections(past_group, '{}'::uuid[]);
    if not exists (
        select 1 from public.after_flow_completions
        where group_id = past_group and user_id = auth.uid()
    ) or exists (
        select 1 from public.contact_selections
        where group_id = past_group and selector_id = auth.uid()
    ) then
        raise exception 'empty first contact answer did not complete without selections';
    end if;

    -- An ambiguous HTTP response may make the app replay the same request. Sealing must preserve
    -- that idempotency while rejecting a different answer used to probe mutual choices.
    perform public.set_contact_selections(past_group, '{}'::uuid[]);
    begin
        perform public.set_contact_selections(
            past_group,
            array['00000000-0000-4000-8000-000000000004'::uuid]
        );
        raise exception 'completed contact answer was changed after sealing';
    exception when object_not_in_prerequisite_state then
        null;
    end;

    -- The same time-gated policy that denied a future ballot must still allow normal attendance
    -- upserts after the event; a deny-only test could pass with a completely unusable API.
    insert into public.attendance_votes (group_id, voter_id, subject_id, showed_up)
    values (
        past_group,
        auth.uid(),
        '00000000-0000-4000-8000-000000000004'::uuid,
        true
    );
end;
$$;
reset role;
