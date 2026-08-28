-- ClickHouse is the system of analysis, but Postgres remains the source of truth. This
-- publication is the durable seam between them: ClickPipes receives committed row changes
-- without asking every client mutation to perform a second, failure-prone HTTP write.
--
-- WHY a table-and-column allowlist instead of FOR TABLES IN SCHEMA public: this schema contains
-- private prose, phone numbers, photo paths, assignment questions, and interpersonal ballots.
-- Analytics needs stable join keys and lifecycle facts, not a shadow copy of every secret. A
-- future table or column therefore stays out until a migration deliberately adds it here and the
-- CDC contract test is updated in the same diff.
--
-- WHY there is no replication slot in this migration: an inactive logical slot retains WAL. A
-- schema deployment can happen hours or days before ClickPipes is provisioned, so creating its
-- slot here could grow the primary disk for a consumer that does not exist. ClickPipes creates
-- and continuously owns the slot when Terraform provisions the live pipe.

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'show_up_clickhouse') then
        execute 'create publication show_up_clickhouse';
    end if;
end
$$;

-- TRUNCATE is intentionally absent. Production lifecycle rows are deleted through ordinary
-- DELETEs, which produce tombstones. Replicating an operator's accidental/reset TRUNCATE could
-- erase the analytical copy immediately and, unlike a row delete, gives us no useful history to
-- inspect. ClickPipes current-state tables still converge for all application write paths.
alter publication show_up_clickhouse
    set (publish = 'insert, update, delete');

-- SET TABLE makes the migration converge an accidentally broadened pre-production publication
-- back to the reviewed boundary. It is safe before the first pipe is created; after deployment,
-- changing this list is an operational schema change and must be paired with the Terraform table
-- mappings and a ClickPipes resync when required.
alter publication show_up_clickhouse set table
    public.profiles (
        id, tags, city, availability, embedded_at, created_at
    ),
    public.groups (
        id, event_at, activity, seed_distance, created_at, chosen_venue_id,
        matching_run_key, event_timezone, venue_status, chat_opened_at
    ),
    public.group_members (
        group_id, user_id, joined_at, matching_run_key
    ),
    public.rsvps (
        group_id, user_id, status
    ),
    public.messages (
        id, group_id, user_id, created_at, kind
    ),
    public.venue_options (
        id, group_id, position, provider_id, kind, locality, score
    ),
    public.venue_votes (
        group_id, user_id, option_id, voted_at
    ),
    public.reflections (
        group_id, user_id, about_user, was_fallback
    ),
    public.attendance_votes (
        group_id, voter_id, subject_id, showed_up
    ),
    public.contact_selections (
        group_id, selector_id, selected_id, created_at
    );

comment on publication show_up_clickhouse is
    'PII-minimized OLTP projection for the managed ClickHouse Postgres CDC ClickPipe. '
    'The exact table and column contract is tested in supabase/tests/0005_clickhouse_cdc.sql.';

-- Create the identity without a login or replication capability. The migration can safely land
-- before the pipe because nobody can connect as this role yet; the deployment script supplies a
-- secret and activates it immediately before Terraform creates the consumer. Existing live roles
-- are never disabled by a migration re-run.
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'clickpipes_user') then
        create role clickpipes_user with nologin noreplication bypassrls;
    else
        alter role clickpipes_user with bypassrls;
    end if;
end
$$;

grant connect on database postgres to clickpipes_user;
grant usage on schema public to clickpipes_user;

-- BYPASSRLS is required for CDC to observe every committed user's rows. It does not bypass SQL
-- privileges, so column grants are the compensating control for both the snapshot and ordinary
-- SELECTs: private content remains unreadable even if a remote table mapping is misconfigured.
revoke all privileges on all tables in schema public from clickpipes_user;

-- A table-level REVOKE does not remove older column-level grants in PostgreSQL. Clear SELECT on
-- every current public column before rebuilding the allowlist, otherwise removing a column from
-- this migration would look correct in review while the previously granted privilege survived.
do $$
declare
    target record;
begin
    for target in
        select namespace.nspname,
               relation.relname,
               string_agg(quote_ident(attribute.attname), ', ' order by attribute.attnum) columns
        from pg_class relation
        join pg_namespace namespace on namespace.oid = relation.relnamespace
        join pg_attribute attribute on attribute.attrelid = relation.oid
        where namespace.nspname = 'public'
          and relation.relkind in ('r', 'p')
          and attribute.attnum > 0
          and not attribute.attisdropped
        group by namespace.nspname, relation.relname
    loop
        execute format(
            'revoke select (%s) on %I.%I from clickpipes_user',
            target.columns, target.nspname, target.relname
        );
    end loop;
end
$$;

grant select (id, tags, city, availability, embedded_at, created_at)
    on public.profiles to clickpipes_user;
grant select (
    id, event_at, activity, seed_distance, created_at, chosen_venue_id,
    matching_run_key, event_timezone, venue_status, chat_opened_at
) on public.groups to clickpipes_user;
grant select (group_id, user_id, joined_at, matching_run_key)
    on public.group_members to clickpipes_user;
grant select (group_id, user_id, status)
    on public.rsvps to clickpipes_user;
grant select (id, group_id, user_id, created_at, kind)
    on public.messages to clickpipes_user;
grant select (id, group_id, position, provider_id, kind, locality, score)
    on public.venue_options to clickpipes_user;
grant select (group_id, user_id, option_id, voted_at)
    on public.venue_votes to clickpipes_user;
grant select (group_id, user_id, about_user, was_fallback)
    on public.reflections to clickpipes_user;
grant select (group_id, voter_id, subject_id, showed_up)
    on public.attendance_votes to clickpipes_user;
grant select (group_id, selector_id, selected_id, created_at)
    on public.contact_selections to clickpipes_user;

comment on role clickpipes_user is
    'Dedicated ClickPipes snapshot/replication login. Column grants mirror show_up_clickhouse.';
