-- Restoration follows server timestamps and durable completion, never the client clock.

do $$
declare
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
begin
    update public.group_members
    set joined_at = now() + interval '1 day'
    where group_id = grp;
    update public.groups set event_at = now() + interval '1 day', needs_repair = false where id = grp;
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
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
    restored record;
begin
    select * into restored from public.current_experience();
    if restored.group_id <> grp or restored.lifecycle_state <> 'pre_meetup' then
        raise exception 'upcoming membership did not restore as pre_meetup';
    end if;
    if has_function_privilege('anon', 'public.current_experience()', 'execute') then
        raise exception 'anonymous caller can inspect lifecycle state';
    end if;
end;
$$;

reset role;

do $$
declare
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
begin
    update public.groups set event_at = now() - interval '1 hour' where id = grp;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$
begin
    if (select lifecycle_state from public.current_experience()) <> 'during' then
        raise exception 'active meetup did not restore as during';
    end if;
end;
$$;
reset role;

do $$
declare
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
begin
    update public.groups set event_at = now() - interval '3 hours' where id = grp;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$
declare
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
begin
    if (select lifecycle_state from public.current_experience()) <> 'after'
       or not public.has_post_meetup_access(grp) then
        raise exception 'open recap window did not restore or authorize as after';
    end if;
end;
$$;
reset role;

do $$
declare
    grp uuid := current_setting('showup.test.lifecycle_group')::uuid;
begin
    insert into public.after_flow_completions (group_id, user_id)
    values (grp, '00000000-0000-4000-8000-000000000001')
    on conflict (group_id, user_id) do nothing;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$
begin
    if (select lifecycle_state from public.current_experience()) <> 'completed' then
        raise exception 'durable recap completion did not seal lifecycle restoration';
    end if;
end;
$$;
reset role;
