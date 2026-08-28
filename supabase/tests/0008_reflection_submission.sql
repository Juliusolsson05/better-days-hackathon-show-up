-- Reflection-specific assertions run after the product fixture has formed two disjoint groups.

do $$
begin
    if has_table_privilege('authenticated', 'public.reflections', 'insert')
       or has_table_privilege('authenticated', 'public.reflections', 'update')
       or has_table_privilege('authenticated', 'public.reflections', 'delete') then
        raise exception 'authenticated callers retained a direct reflection write path';
    end if;

    if not has_function_privilege(
        'authenticated', 'public.submit_reflection(uuid,text,boolean)', 'execute'
    ) or has_function_privilege(
        'anon', 'public.submit_reflection(uuid,text,boolean)', 'execute'
    ) then
        raise exception 'reflection submission RPC has the wrong execution boundary';
    end if;
end;
$$;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000001',
    true
);
do $$
declare
    own_group uuid := current_setting('showup.test.group_one')::uuid;
    other_group uuid := current_setting('showup.test.group_two')::uuid;
begin
    -- The earlier suite already wrote this caller's response. Repeating the call is the exact app
    -- retry path that failed under table upsert plus the received-only SELECT policy.
    perform public.submit_reflection(own_group, 'A retry-safe edited answer.', false);
    perform public.submit_reflection(own_group, 'A second retry-safe answer.', false);

    if exists (
        select 1 from public.reflections
        where group_id = own_group and user_id = auth.uid()
    ) then
        raise exception 'outbound reflection became selectable to its author';
    end if;

    begin
        perform public.submit_reflection(other_group, 'Not my group.', false);
        raise exception 'reflection RPC accepted an unrelated group';
    exception when insufficient_privilege then
        null;
    end;

    begin
        perform public.submit_reflection(own_group, '   ', false);
        raise exception 'reflection RPC accepted blank content';
    exception when invalid_parameter_value then
        null;
    end;
end;
$$;
reset role;

do $$
declare
    own_group uuid := current_setting('showup.test.group_one')::uuid;
    expected_target uuid;
begin
    select target_id into expected_target
    from public.member_assignments
    where group_id = own_group
      and user_id = '00000000-0000-4000-8000-000000000001'::uuid;

    if not exists (
        select 1 from public.reflections
        where group_id = own_group
          and user_id = '00000000-0000-4000-8000-000000000001'::uuid
          and about_user = expected_target
          and what_stuck = 'A second retry-safe answer.'
          and not was_fallback
    ) then
        raise exception 'reflection retry did not retain the assigned target and latest text';
    end if;
end;
$$;
