-- Chat-specific assertions run after the wider product suite has created realistic groups.

do $$
declare
    grp uuid;
    author uuid;
    client_id uuid := '10000000-0000-4000-8000-000000000001'::uuid;
begin
    select id into grp from public.groups where activity = 'retry-safe' limit 1;
    select user_id into author from public.group_members where group_id = grp limit 1;
    if grp is null or author is null then
        raise exception 'product fixture did not leave a group for chat assertions';
    end if;

    if not public.open_group_chat(grp, 'Welcome') then
        raise exception 'fresh group did not open';
    end if;
    if public.open_group_chat(grp, 'Duplicate welcome') then
        raise exception 'opening the same group twice was not idempotent';
    end if;
    if (select count(*) from public.messages where group_id = grp and kind = 'system') <> 1 then
        raise exception 'group has anything other than one opening system message';
    end if;

    insert into public.messages (group_id, user_id, body, kind, client_msg_id)
    values (grp, author, 'Hello', 'user', client_id);
    begin
        insert into public.messages (group_id, user_id, body, kind, client_msg_id)
        values (grp, author, 'Duplicate', 'user', client_id);
        raise exception 'duplicate optimistic-send id unexpectedly succeeded';
    exception when unique_violation then
        null;
    end;

    if has_function_privilege(
        'authenticated', 'public.open_group_chat(uuid,text)', 'execute'
    ) then
        raise exception 'app user can forge a chat opening';
    end if;
end;
$$;
