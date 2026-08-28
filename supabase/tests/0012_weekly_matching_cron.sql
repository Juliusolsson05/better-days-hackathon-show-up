-- Prove that the only automatic matching entry point is installed, credential-free at rest, and
-- unavailable to app roles. A function existing without its cron row leaves users waiting forever;
-- a cron row containing the service key fixes reachability by creating a larger secret exposure.

do $$
declare
    installed_job cron.job%rowtype;
begin
    if to_regprocedure('private.invoke_weekly_matching()') is null then
        raise exception 'weekly matching invocation function is missing';
    end if;
    if has_schema_privilege('authenticated', 'private', 'usage')
       or has_schema_privilege('anon', 'private', 'usage')
       or has_function_privilege(
           'authenticated', 'private.invoke_weekly_matching()', 'execute'
       )
       or has_function_privilege('anon', 'private.invoke_weekly_matching()', 'execute')
       or not has_function_privilege(
           'service_role', 'private.invoke_weekly_matching()', 'execute'
       ) then
        raise exception 'weekly matching hook is callable from the wrong API role';
    end if;

    select job.* into installed_job
    from cron.job job
    where job.jobname = 'showup-weekly-matching';

    if not found
       or installed_job.schedule <> '0 12 * * 1'
       or installed_job.command <> 'select private.invoke_weekly_matching();'
       or not installed_job.active then
        raise exception 'weekly matching cron job is absent, disabled, or drifted';
    end if;

    if installed_job.command ~* '(bearer|service.role|https?://)' then
        raise exception 'weekly matching cron command contains credential or endpoint material';
    end if;
end;
$$;

-- Missing Vault configuration must stop before net.http_post. Deleting only the two scoped test
-- names inside check_schema's rollback transaction avoids depending on a developer's local Vault
-- while proving the hook never falls back to an anonymous request.
delete from vault.secrets
where name in ('showup_supabase_url', 'showup_service_role_key');

do $$
begin
    begin
        perform private.invoke_weekly_matching();
        raise exception 'unconfigured weekly matching hook unexpectedly queued a request';
    exception when object_not_in_prerequisite_state then
        null;
    end;
end;
$$;
