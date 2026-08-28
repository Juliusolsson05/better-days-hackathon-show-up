-- Message mutation is RPC-only and derives every authoritative field from the session.

do $$
begin
    if has_table_privilege('authenticated', 'public.messages', 'insert')
       or has_table_privilege('authenticated', 'public.messages', 'update')
       or has_table_privilege('authenticated', 'public.messages', 'delete') then
        raise exception 'authenticated callers retained a direct message mutation path';
    end if;
    if not has_function_privilege(
        'authenticated', 'public.send_message(uuid,uuid,text)', 'execute'
    ) then
        raise exception 'authenticated callers cannot use the reviewed message RPC';
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
    stable_id uuid := '13000000-0000-4000-8000-000000000001'::uuid;
    returned_id bigint;
begin
    returned_id := public.send_message(grp, stable_id, 'Hello from the RPC');
    if returned_id is null then
        raise exception 'message RPC did not return the inserted row';
    end if;
    if public.send_message(grp, stable_id, 'Hello from the RPC') <> returned_id then
        raise exception 'an exact retry was not idempotent';
    end if;
    if (select count(*) from public.messages where client_msg_id = stable_id) <> 1 then
        raise exception 'an exact retry duplicated the message';
    end if;

    begin
        perform public.send_message(grp, stable_id, 'Changed retry body');
        raise exception 'client id reuse with a changed body unexpectedly succeeded';
    exception when unique_violation then
        null;
    end;
    begin
        perform public.send_message(other_grp, gen_random_uuid(), 'Cross-group write');
        raise exception 'non-member message unexpectedly succeeded';
    exception when insufficient_privilege then
        null;
    end;
    begin
        perform public.send_message(grp, gen_random_uuid(), '   ');
        raise exception 'blank message unexpectedly succeeded';
    exception when invalid_parameter_value then
        null;
    end;

    for i in 1..9 loop
        perform public.send_message(grp, gen_random_uuid(), 'Rate sample ' || i);
    end loop;
    begin
        perform public.send_message(grp, gen_random_uuid(), 'One too many');
        raise exception 'eleventh message inside one minute unexpectedly succeeded';
    exception when raise_exception then
        if sqlerrm <> 'message rate limit exceeded' then raise; end if;
    end;
end;
$$;

reset role;
