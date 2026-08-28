-- Profile write-boundary assertions run after the product fixture has created complete users.

do $$
begin
    if has_table_privilege('authenticated', 'public.profiles', 'insert')
       or has_table_privilege('authenticated', 'public.profiles', 'update')
       or has_table_privilege('authenticated', 'public.profiles', 'delete')
       or has_table_privilege('authenticated', 'public.profiles', 'truncate')
       or has_table_privilege('authenticated', 'public.profiles', 'references')
       or has_table_privilege('authenticated', 'public.profiles', 'trigger') then
        raise exception 'authenticated callers retained a direct profile mutation path';
    end if;

    if not has_column_privilege(
        'authenticated', 'public.profiles', 'display_name', 'select'
    ) or has_column_privilege(
        'authenticated', 'public.profiles', 'phone', 'select'
    ) then
        raise exception 'profile write lockdown changed the reviewed public/private read boundary';
    end if;

    if not has_table_privilege('service_role', 'public.profiles', 'insert')
       or not has_table_privilege('service_role', 'public.profiles', 'update') then
        raise exception 'submit-profile service role cannot perform its draft/stamp protocol';
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
begin
    begin
        update public.profiles
        set embedded_at = now()
        where id = auth.uid();
        raise exception 'caller self-stamped embedding readiness through the direct table API';
    exception when insufficient_privilege then
        null;
    end;

    -- Read access must survive the write lockdown. RLS still owns row scope and the column grant
    -- still owns field scope; this query proves 0009 did not accidentally break group rendering.
    if not exists (
        select 1 from public.profiles
        where id = auth.uid() and display_name is not null
    ) then
        raise exception 'caller lost safe read access to their own public profile';
    end if;
end;
$$;
reset role;
