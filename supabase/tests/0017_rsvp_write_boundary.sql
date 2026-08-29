-- RSVP decisions must cross one authenticated, deadline-gated server boundary.

do $$
declare
    members jsonb := '[
      {"user_id":"00000000-0000-4000-8000-000000000001","target_id":"00000000-0000-4000-8000-000000000002","question":"One"},
      {"user_id":"00000000-0000-4000-8000-000000000002","target_id":"00000000-0000-4000-8000-000000000003","question":"Two"},
      {"user_id":"00000000-0000-4000-8000-000000000003","target_id":"00000000-0000-4000-8000-000000000004","question":"Three"},
      {"user_id":"00000000-0000-4000-8000-000000000004","target_id":"00000000-0000-4000-8000-000000000001","question":"Four"}
    ]'::jsonb;
    grp uuid;
begin
    grp := public.form_group(
        now() + interval '3 days', null, 'rsvp-boundary', 0.2, members
    );
    perform set_config('showup.test.rsvp_group', grp::text, true);

    if (select rsvp_closes_at <> event_at from public.groups where id = grp) then
        raise exception 'new group did not receive its server RSVP deadline';
    end if;
    if has_function_privilege('anon', 'public.set_rsvp(uuid,text)', 'execute')
       or not has_function_privilege(
           'authenticated', 'public.set_rsvp(uuid,text)', 'execute'
       ) then
        raise exception 'RSVP RPC is callable from the wrong API role';
    end if;
end;
$$;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000001',
    true
);

select public.set_rsvp(
    current_setting('showup.test.rsvp_group')::uuid,
    'confirmed'
);

do $$
declare
    grp uuid := current_setting('showup.test.rsvp_group')::uuid;
begin
    if (select status from public.rsvps
        where group_id = grp and user_id = auth.uid()) <> 'confirmed' then
        raise exception 'RPC did not persist confirmed RSVP';
    end if;

    begin
        update public.rsvps
        set status = 'declined'
        where group_id = grp and user_id = auth.uid();
        raise exception 'authenticated caller retained direct RSVP mutation';
    exception when insufficient_privilege then
        null;
    end;

    begin
        perform public.set_rsvp(grp, 'pending');
        raise exception 'RPC accepted pending as a user decision';
    exception when sqlstate '22023' then
        null;
    end;
end;
$$;

reset role;

update public.groups
set rsvp_closes_at = now() - interval '1 second'
where id = current_setting('showup.test.rsvp_group')::uuid;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000001',
    true
);

do $$
begin
    begin
        perform public.set_rsvp(
            current_setting('showup.test.rsvp_group')::uuid,
            'declined'
        );
        raise exception 'RPC accepted RSVP after deadline';
    exception when sqlstate '55000' then
        null;
    end;
end;
$$;

reset role;

update public.groups
set rsvp_closes_at = event_at
where id = current_setting('showup.test.rsvp_group')::uuid;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000002',
    true
);
select public.set_rsvp(
    current_setting('showup.test.rsvp_group')::uuid,
    'declined'
);

do $$
declare
    grp uuid := current_setting('showup.test.rsvp_group')::uuid;
begin
    if not (select needs_repair from public.groups where id = grp) then
        raise exception 'decline did not mark the assignment for repair';
    end if;
end;
$$;

reset role;
