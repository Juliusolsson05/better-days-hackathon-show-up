-- Safety decisions stay private, reject cross-group targets, and revoke room access immediately.

do $$
begin
    if has_table_privilege('authenticated', 'public.safety_reports', 'select')
       or has_table_privilege('authenticated', 'public.blocked_users', 'select') then
        raise exception 'private reports or one-way blocks are readable by app users';
    end if;
    if not has_function_privilege(
        'authenticated', 'public.report_user(uuid,uuid,text,text)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.block_user(uuid)', 'execute'
    ) or not has_function_privilege(
        'authenticated', 'public.leave_group(uuid)', 'execute'
    ) then
        raise exception 'an authenticated safety action is unavailable';
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
    grp uuid := current_setting('showup.test.group_one')::uuid;
    other_grp uuid := current_setting('showup.test.group_two')::uuid;
    report_id uuid;
begin
    report_id := public.report_user(
        grp,
        '00000000-0000-4000-8000-000000000002',
        'harassment',
        'Repeated unwanted contact.'
    );
    if report_id is null then raise exception 'report was not recorded'; end if;

    perform public.block_user('00000000-0000-4000-8000-000000000002');
    -- An exact retry is intentionally harmless and reveals no block state to the caller.
    perform public.block_user('00000000-0000-4000-8000-000000000002');

    begin
        perform public.report_user(
            other_grp,
            '00000000-0000-4000-8000-000000000005',
            'other',
            null
        );
        raise exception 'cross-group report unexpectedly succeeded';
    exception when insufficient_privilege then
        null;
    end;

    perform public.leave_group(grp);
    perform public.leave_group(grp);
    if exists (
        select 1 from public.group_members where group_id = grp and user_id = auth.uid()
    ) then
        raise exception 'leave did not revoke membership';
    end if;
end;
$$;

reset role;

do $$
declare
    grp uuid := current_setting('showup.test.group_one')::uuid;
begin
    if not exists (
        select 1 from public.blocked_users
        where blocker_id = '00000000-0000-4000-8000-000000000001'
          and blocked_id = '00000000-0000-4000-8000-000000000002'
    ) then
        raise exception 'block was not persisted';
    end if;
    if not (select needs_repair from public.groups where id = grp) then
        raise exception 'leave did not mark the group for repair';
    end if;
end;
$$;
