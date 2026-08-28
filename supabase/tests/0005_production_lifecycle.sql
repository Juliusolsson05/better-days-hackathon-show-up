-- Production-lifecycle assertions run after the product fixture has formed two disjoint groups.
-- Owner checks prove constraints; authenticated checks prove the API boundary seen by PostgREST.

do $$
declare
    incomplete_user uuid := '00000000-0000-4000-8000-000000000009'::uuid;
    own_group uuid := current_setting('showup.test.group_one')::uuid;
begin
    if not has_function_privilege(
           'authenticated', 'public.profile_ready()', 'execute'
       ) or has_function_privilege('anon', 'public.profile_ready()', 'execute') then
        raise exception 'profile readiness is not restricted to authenticated callers';
    end if;

    if has_column_privilege('authenticated', 'public.profiles', 'phone', 'select') then
        raise exception 'profile readiness reopened direct phone access';
    end if;

    if not has_table_privilege(
           'authenticated', 'public.after_flow_completions', 'select'
       ) or has_table_privilege(
           'authenticated', 'public.after_flow_completions', 'insert'
       ) or has_table_privilege(
           'authenticated', 'public.after_flow_completions', 'update'
       ) or has_table_privilege(
           'authenticated', 'public.after_flow_completions', 'delete'
       ) then
        raise exception 'after-flow completion grants permit more than own-row reads';
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.profiles'::regclass
          and conname = 'profiles_phone_required'
          and not convalidated
    ) then
        raise exception 'required phone constraint was validated or omitted during legacy upgrade';
    end if;

    -- The product-contract fixture finishes user two with a non-empty contact choice. This
    -- owner-visible assertion proves the upgraded RPC records that pre-existing success path;
    -- the authenticated assertions below separately cover the easy-to-miss empty choice.
    if not exists (
        select 1 from public.after_flow_completions
        where group_id = own_group
          and user_id = '00000000-0000-4000-8000-000000000002'::uuid
    ) then
        raise exception 'non-empty final contact choice did not mark the flow complete';
    end if;

    insert into auth.users (id) values (incomplete_user);
    insert into public.profiles (
        id, display_name, passion, tags, city, availability,
        photo_url, phone, embedded_at
    ) values (
        incomplete_user,
        'Incomplete User',
        'A sufficiently long passion awaiting an embedding',
        array['test'],
        'SF',
        array['fri_eve'],
        incomplete_user::text || '/profile.jpg',
        '+14155550009',
        null
    );

    begin
        update public.profiles set phone = null where id = incomplete_user;
        raise exception 'a future profile update unexpectedly removed its required phone';
    exception when check_violation then
        null;
    end;

    begin
        insert into public.after_flow_completions (group_id, user_id)
        values (own_group, incomplete_user);
        raise exception 'cross-group lifecycle completion unexpectedly succeeded';
    exception when foreign_key_violation then
        null;
    end;
end;
$$;

set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000009',
    true
);
do $$
begin
    if public.profile_ready() then
        raise exception 'profile without a completed embedding was marked ready';
    end if;

    begin
        perform phone from public.profiles where id = auth.uid();
        raise exception 'authenticated caller unexpectedly selected its private phone directly';
    exception when insufficient_privilege then
        null;
    end;
end;
$$;

select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000001',
    true
);
do $$
declare
    own_group uuid := current_setting('showup.test.group_one')::uuid;
begin
    if not public.profile_ready() then
        raise exception 'complete profile was not marked ready';
    end if;

    -- Validation must happen before replacement and completion. Otherwise a malformed final
    -- request could erase the user's prior choice and falsely suppress the post-meetup prompt.
    begin
        perform public.set_contact_selections(
            own_group,
            array['00000000-0000-4000-8000-000000000005'::uuid]
        );
        raise exception 'cross-group contact replacement unexpectedly succeeded';
    exception when check_violation then
        null;
    end;

    if exists (
        select 1 from public.after_flow_completions where group_id = own_group
    ) or not exists (
        select 1 from public.contact_selections
        where group_id = own_group
          and selector_id = auth.uid()
          and selected_id = '00000000-0000-4000-8000-000000000002'::uuid
    ) then
        raise exception 'failed final contact request partially changed lifecycle state';
    end if;

    perform public.set_contact_selections(own_group, '{}'::uuid[]);

    if (select count(*) from public.after_flow_completions) <> 1
       or not exists (
           select 1 from public.after_flow_completions
           where group_id = own_group and user_id = auth.uid()
       )
       or exists (
           select 1 from public.contact_selections
           where group_id = own_group and selector_id = auth.uid()
       ) then
        raise exception 'empty final contact choice was not atomically marked complete';
    end if;

    begin
        insert into public.after_flow_completions (group_id, user_id)
        values (own_group, auth.uid());
        raise exception 'caller bypassed final-step RPC to write completion directly';
    exception when insufficient_privilege then
        null;
    end;
end;
$$;
reset role;
