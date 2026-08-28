-- The two external pipelines may finish in either order. Only the latest database-issued token
-- may certify readiness, and its version must remain strictly newer for ClickHouse deduplication.
do $$
declare
    uid uuid := '00000000-0000-4000-8000-000000000001'::uuid;
    first_id uuid := '10000000-0000-4000-8000-000000000001'::uuid;
    second_id uuid := '20000000-0000-4000-8000-000000000002'::uuid;
    first_version timestamptz;
    second_version timestamptz;
begin
    if has_function_privilege(
           'authenticated',
           'public.begin_profile_submission(uuid,uuid,text,text,text,text[],text,text[],text,text)',
           'execute'
       ) or has_function_privilege(
           'authenticated',
           'public.complete_profile_submission(uuid,uuid,timestamp with time zone)',
           'execute'
       ) or not has_function_privilege(
           'service_role',
           'public.begin_profile_submission(uuid,uuid,text,text,text,text[],text,text[],text,text)',
           'execute'
       ) or not has_function_privilege(
           'service_role',
           'public.complete_profile_submission(uuid,uuid,timestamp with time zone)',
           'execute'
       ) then
        raise exception 'profile submission RPCs are not service-role-only';
    end if;

    insert into auth.users (id) values (uid) on conflict (id) do nothing;

    first_version := public.begin_profile_submission(
        uid, first_id, 'First', '🙂', 'A sufficiently long first passion', array['music'],
        'SF', array['fri_eve'], '+14155550101', uid::text || '/profile.jpg'
    );
    second_version := public.begin_profile_submission(
        uid, second_id, 'Second', '🙂', 'A sufficiently long second passion', array['climbing'],
        'SF', array['fri_eve'], '+14155550102', uid::text || '/profile.jpg'
    );

    if second_version <= first_version then
        raise exception 'submission versions did not advance monotonically';
    end if;
    if public.complete_profile_submission(uid, first_id, first_version) then
        raise exception 'stale profile submission stamped readiness';
    end if;
    if not public.complete_profile_submission(uid, second_id, second_version) then
        raise exception 'current profile submission failed to stamp readiness';
    end if;
    if not exists (
        select 1 from public.profiles
        where id = uid and display_name = 'Second' and embedded_at is not null
          and embedding_submission_id = second_id and embedding_version = second_version
    ) then
        raise exception 'newest profile data and readiness diverged';
    end if;
end;
$$;
