-- Executed after 0002 inside a transaction by scripts/check_schema.sh.
-- Raise immediately when a product promise has become merely a client convention.

do $$
declare
    g1 uuid;
    g2 uuid;
    option_from_g1 uuid;
    option_from_g2 uuid;
    user_ids uuid[] := array[
        '00000000-0000-4000-8000-000000000001'::uuid,
        '00000000-0000-4000-8000-000000000002'::uuid,
        '00000000-0000-4000-8000-000000000003'::uuid,
        '00000000-0000-4000-8000-000000000004'::uuid,
        '00000000-0000-4000-8000-000000000005'::uuid,
        '00000000-0000-4000-8000-000000000006'::uuid,
        '00000000-0000-4000-8000-000000000007'::uuid,
        '00000000-0000-4000-8000-000000000008'::uuid
    ];
begin
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'group_members'
          and column_name in ('pair_with', 'question')
    ) then
        raise exception 'private assignment data still lives on group-visible rows';
    end if;

    if has_column_privilege('authenticated', 'public.profiles', 'phone', 'select')
       or not has_column_privilege(
           'authenticated', 'public.profiles', 'display_name', 'select'
       ) then
        raise exception 'profile column grants expose phone or hide public identity';
    end if;

    if exists (
        select 1 from storage.buckets where id = 'photos' and public
    ) or exists (
        select 1 from pg_policies
        where schemaname = 'storage' and tablename = 'objects'
          and policyname = 'photos are public'
    ) then
        raise exception 'legacy public photo access survived the product migration';
    end if;

    if exists (
        select 1 from public.profiles
        where id = '00000000-0000-4000-8000-000000000099'
          and photo_url <> '00000000-0000-4000-8000-000000000099/profile.jpg'
    ) then
        raise exception 'legacy Supabase public URL was not converted to an object path';
    end if;

    if has_function_privilege(
           'authenticated',
           'public.form_group(timestamptz,jsonb,text,real,jsonb,text,text)',
           'execute'
       )
       or has_function_privilege(
           'authenticated',
           'public.replace_venue_options(uuid,jsonb)',
           'execute'
       )
       or has_function_privilege(
           'authenticated',
           'public.finalize_venue_vote(uuid)',
           'execute'
       ) then
        raise exception 'system-only write protocols are executable by app users';
    end if;

    insert into auth.users (id)
    select unnest(user_ids);

    insert into public.profiles (
        id, display_name, passion, tags, city, availability,
        photo_url, phone, embedded_at
    )
    select
        id,
        'User ' || ordinality,
        'A sufficiently long test passion',
        array['test'],
        'SF',
        array['fri_eve'],
        id::text || '/profile.jpg',
        '+14155550' || lpad(ordinality::text, 3, '0'),
        now()
    from unnest(user_ids) with ordinality as u(id, ordinality);

    select public.form_group(
        now() + interval '3 days',
        '{"name":"Legacy One","address":"1 Test St"}'::jsonb,
        'talk',
        0.1,
        (select jsonb_agg(jsonb_build_object(
            'user_id', user_ids[i],
            'target_id', user_ids[(i % 4) + 1],
            'question', 'Question ' || i
        )) from generate_series(1, 4) i)
    ) into g1;

    select public.form_group(
        now() + interval '4 days',
        '{"name":"Legacy Two","address":"2 Test St"}'::jsonb,
        'walk',
        0.2,
        (select jsonb_agg(jsonb_build_object(
            'user_id', user_ids[i],
            'target_id', user_ids[5 + (i % 4)],
            'question', 'Question ' || i
        )) from generate_series(5, 8) i)
    ) into g2;

    perform set_config('showup.test.group_one', g1::text, true);
    perform set_config('showup.test.group_two', g2::text, true);

    if (select count(*) from public.member_assignments where group_id = g1) <> 4
       or (select count(distinct target_id)
           from public.member_assignments where group_id = g1) <> 4 then
        raise exception 'form_group did not persist a complete assignment derangement';
    end if;

    perform public.replace_venue_options(g1, '[
      {"position":1,"venue_id":"one-a","name":"One A","kind":"cafe",
       "address":"1 A St","locality":"SF","lat":37.7,"lng":-122.4,
       "pitch":"A","score":0.8,"per_member":[0.8,0.7]},
      {"position":2,"venue_id":"one-b","name":"One B","kind":"park",
       "address":"1 B St","locality":"SF","lat":37.8,"lng":-122.3,
       "pitch":"B","score":0.7,"per_member":[0.7,0.6]}
    ]'::jsonb);
    perform public.replace_venue_options(g2, '[
      {"position":1,"venue_id":"two-a","name":"Two A","kind":"bar",
       "address":"2 A St","locality":"SF","lat":37.7,"lng":-122.4,
       "pitch":"A","score":0.8,"per_member":[0.8,0.7]},
      {"position":2,"venue_id":"two-b","name":"Two B","kind":"museum",
       "address":"2 B St","locality":"SF","lat":37.8,"lng":-122.3,
       "pitch":"B","score":0.7,"per_member":[0.7,0.6]}
    ]'::jsonb);

    if (select venue_status from public.groups where id = g1) <> 'voting' then
        raise exception 'persisted venue options did not open the vote';
    end if;

    select id into option_from_g1
    from public.venue_options where group_id = g1 order by position limit 1;

    select id into option_from_g2
    from public.venue_options where group_id = g2 order by position limit 1;

    begin
        insert into public.venue_votes (group_id, user_id, option_id)
        values (g1, user_ids[1], option_from_g2);
        raise exception 'cross-group venue vote unexpectedly succeeded';
    exception when foreign_key_violation then
        null;
    end;

    begin
        insert into public.attendance_votes (group_id, voter_id, subject_id, showed_up)
        values (g1, user_ids[1], user_ids[5], true);
        raise exception 'cross-group attendance ballot unexpectedly succeeded';
    exception when foreign_key_violation then
        null;
    end;

    begin
        insert into public.contact_selections (group_id, selector_id, selected_id)
        values (g1, user_ids[1], user_ids[5]);
        raise exception 'cross-group contact selection unexpectedly succeeded';
    exception when foreign_key_violation then
        null;
    end;

    -- Once even one member has voted, a retrying venue job must not silently replace the
    -- candidates and cascade that ballot away.
    insert into public.venue_votes (group_id, user_id, option_id)
    values (g1, user_ids[1], option_from_g1);
    begin
        perform public.replace_venue_options(g1, '[
          {"position":1,"venue_id":"replacement-a","name":"Replacement A","kind":"cafe",
           "address":"3 A St","locality":"SF","lat":37.7,"lng":-122.4,
           "pitch":"A","score":0.8,"per_member":[0.8]},
          {"position":2,"venue_id":"replacement-b","name":"Replacement B","kind":"park",
           "address":"3 B St","locality":"SF","lat":37.8,"lng":-122.3,
           "pitch":"B","score":0.7,"per_member":[0.7]}
        ]'::jsonb);
        raise exception 'venue replacement unexpectedly erased an active ballot';
    exception when object_not_in_prerequisite_state then
        null;
    end;

    -- All-member participation is the MVP close rule. The trigger finalizes exactly once, and
    -- deterministic score/position ordering makes a tied count the same on every device.
    insert into public.venue_votes (group_id, user_id, option_id)
    select g1, user_ids[i], option_from_g1 from generate_series(2, 4) i;
    if (select chosen_venue_id from public.groups where id = g1) <> option_from_g1
       or (select venue_status from public.groups where id = g1) <> 'chosen' then
        raise exception 'complete venue ballot did not finalize an authoritative winner';
    end if;
    begin
        update public.venue_votes
        set option_id = (
            select id from public.venue_options
            where group_id = g1 and id <> option_from_g1 order by position limit 1
        )
        where group_id = g1 and user_id = user_ids[1];
        raise exception 'venue vote changed after finalization';
    exception when object_not_in_prerequisite_state then
        null;
    end;

    insert into public.contact_selections (group_id, selector_id, selected_id)
    values (g1, user_ids[1], user_ids[2]);

    insert into storage.objects (bucket_id, name, owner, owner_id)
    select 'photos', id::text || '/profile.jpg', id, id::text
    from unnest(user_ids) u(id);

    begin
        perform public.form_group(
            now(), null, 'invalid', 0,
            (select jsonb_agg(jsonb_build_object(
                'user_id', user_ids[i],
                'target_id', user_ids[(i % 3) + 1],
                'question', 'Question ' || i
            )) from generate_series(1, 3) i)
        );
        raise exception 'three-person group unexpectedly succeeded';
    exception when check_violation then
        null;
    end;

    -- A matching retry returns the same group, while a different formation in the same run may
    -- not reuse even one participant. This is the database boundary that makes cron overlap and
    -- ambiguous HTTP responses safe; an in-memory `unassigned` set cannot do that.
    declare
        retry_group uuid;
        first_retry_group uuid;
    begin
        select public.form_group(
            now() + interval '5 days', null, 'retry-safe', 0.3,
            (select jsonb_agg(jsonb_build_object(
                'user_id', user_ids[i],
                'target_id', user_ids[(i % 4) + 1],
                'question', 'Retry question ' || i
            )) from generate_series(1, 4) i),
            'sf:2026-09-04:fri_eve',
            'America/Los_Angeles'
        ) into first_retry_group;
        select public.form_group(
            now() + interval '5 days', null, 'retry-safe', 0.3,
            (select jsonb_agg(jsonb_build_object(
                'user_id', user_ids[i],
                'target_id', user_ids[(i % 4) + 1],
                'question', 'Retry question ' || i
            )) from generate_series(1, 4) i),
            'sf:2026-09-04:fri_eve',
            'America/Los_Angeles'
        ) into retry_group;
        if retry_group <> first_retry_group then
            raise exception 'identical matching retry created another group';
        end if;

        begin
            perform public.form_group(
                now() + interval '5 days', null, 'overlap', 0.3,
                jsonb_build_array(
                    jsonb_build_object('user_id', user_ids[1], 'target_id', user_ids[5], 'question', 'A'),
                    jsonb_build_object('user_id', user_ids[5], 'target_id', user_ids[6], 'question', 'B'),
                    jsonb_build_object('user_id', user_ids[6], 'target_id', user_ids[7], 'question', 'C'),
                    jsonb_build_object('user_id', user_ids[7], 'target_id', user_ids[1], 'question', 'D')
                ),
                'sf:2026-09-04:fri_eve',
                'America/Los_Angeles'
            );
            raise exception 'same participant entered two groups in one matching run';
        exception when unique_violation then
            null;
        end;
    end;
end;
$$;

-- Table-owner tests prove integrity but bypass RLS. Exercise the confidentiality promises as
-- actual API roles with distinct JWT subjects so a permissive policy cannot hide behind a green
-- foreign-key suite.
set local role authenticated;
select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000001',
    true
);
do $$
declare
    own_group uuid;
    other_group uuid;
begin
    own_group := current_setting('showup.test.group_one')::uuid;
    other_group := current_setting('showup.test.group_two')::uuid;

    if (select count(*) from public.member_assignments where group_id = own_group) <> 1 then
        raise exception 'authenticated member can read more than their own assignment';
    end if;
    if (select count(*) from public.venue_votes where group_id = own_group) <> 1 then
        raise exception 'authenticated member can read another member venue ballot';
    end if;
    if exists (
        select 1 from public.contact_selections
        where group_id = own_group and selector_id <> auth.uid()
    ) then
        raise exception 'one-way contact decisions are observable by the selected user';
    end if;
    if (select count(*) from storage.objects where bucket_id = 'photos') <> 4 then
        raise exception 'photo policy does not match owner plus current groupmates';
    end if;
    if exists (select 1 from public.venue_tally(other_group)) then
        raise exception 'venue tally leaked another group';
    end if;
    if exists (select 1 from public.mutual_contacts(own_group)) then
        raise exception 'one-way contact selection disclosed a phone number';
    end if;
end;
$$;

select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000002',
    true
);
do $$
declare
    own_group uuid;
begin
    own_group := current_setting('showup.test.group_one')::uuid;
    perform public.set_contact_selections(
        own_group,
        array['00000000-0000-4000-8000-000000000001'::uuid]
    );
    if (select count(*) from public.mutual_contacts(own_group)) <> 1 then
        raise exception 'mutual contact did not disclose exactly one reciprocal phone';
    end if;
end;
$$;

select set_config(
    'request.jwt.claim.sub',
    '00000000-0000-4000-8000-000000000005',
    true
);
do $$
begin
    if exists (select 1 from public.groups where activity = 'talk')
       or exists (
           select 1 from storage.objects
           where bucket_id = 'photos'
             and name like '00000000-0000-4000-8000-000000000001/%'
       ) then
        raise exception 'unrelated group identity or photo leaked through RLS';
    end if;
end;
$$;
reset role;

set local role anon;
do $$
begin
    if exists (select 1 from storage.objects where bucket_id = 'photos') then
        raise exception 'anonymous caller can read a private profile photo';
    end if;
end;
$$;
reset role;
