-- Connect the durable waiting state to the service-owned matching sweep.
--
-- run-matching is intentionally impossible to invoke with the Flutter anon key: it spends provider
-- tokens and writes groups for users other than the caller. That leaves exactly one production
-- owner for the transition from "profile ready" to "matched": a scheduled service-role request.
-- Keeping the schedule only in operator documentation meant a fully deployed app could accept
-- profiles forever while no group was ever formed.
--
-- The URL and service-role key are NOT migration literals and are NOT embedded in cron.job, whose
-- command is visible to database operators. Provision these two Vault names through a privileged
-- SQL session before the first Monday run:
--
--   select vault.create_secret('https://<project-ref>.supabase.co',
--                              'showup_supabase_url');
--   select vault.create_secret('<service-role-key>',
--                              'showup_service_role_key');
--
-- The job is installed even before those secrets exist. Its function fails closed with one generic
-- configuration error until both arrive; adding the secrets later activates the already-versioned
-- schedule without editing a cron command or pushing another migration.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

create or replace function private.invoke_weekly_matching()
returns bigint
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    project_url text;
    service_role_key text;
    request_id bigint;
begin
    -- Names, rather than Vault UUIDs, survive secret rotation. Selecting the newest row also makes a
    -- rotation recoverable if an operator adds the replacement before deleting the old value.
    select decrypted.decrypted_secret
    into project_url
    from vault.decrypted_secrets decrypted
    where decrypted.name = 'showup_supabase_url'
    order by decrypted.updated_at desc
    limit 1;

    select decrypted.decrypted_secret
    into service_role_key
    from vault.decrypted_secrets decrypted
    where decrypted.name = 'showup_service_role_key'
    order by decrypted.updated_at desc
    limit 1;

    if nullif(btrim(project_url), '') is null
       or project_url !~ '^https://[^/]+$'
       or nullif(btrim(service_role_key), '') is null then
        -- Do not say which credential is absent: cron errors are operational evidence, and a generic
        -- failure proves no unauthenticated fallback request can leave the database.
        raise exception 'weekly matching credentials are not configured'
            using errcode = '55000';
    end if;

    select net.http_post(
        url := rtrim(project_url, '/') || '/functions/v1/run-matching',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || service_role_key,
            -- Hosted gateways accept Authorization for the current function, while apikey keeps the
            -- hook compatible with gateway configurations that require both headers.
            'apikey', service_role_key,
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('city', 'SF', 'slot', 'fri_eve'),
        -- Matching may embed, query ClickHouse, call Claude, and prepare venues for several groups.
        -- pg_net's five-second default makes a healthy sweep look failed and can close the only
        -- observable request before the Edge Function returns its repair summary.
        timeout_milliseconds := 300000
    ) into request_id;

    return request_id;
end;
$$;

revoke all on function private.invoke_weekly_matching()
    from public, anon, authenticated;
grant execute on function private.invoke_weekly_matching() to service_role;

-- A stable name lets this migration repair a manually-created draft instead of adding a second
-- weekly sweep. cron.schedule(name, ...) updates the named job in pg_cron, so the reviewed schedule
-- and credential-free command become authoritative without exposing Vault contents.
select cron.schedule(
    'showup-weekly-matching',
    '0 12 * * 1',
    'select private.invoke_weekly_matching();'
);
