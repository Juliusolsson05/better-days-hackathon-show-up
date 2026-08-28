-- The publication is a confidentiality boundary and an analytical contract. A green migration
-- is insufficient: PostgreSQL happily accepts a publication that accidentally includes phone,
-- message, or reflection content, and ClickPipes would then copy it exactly as requested.

do $$
begin
    if not exists (
        select 1
        from pg_publication
        where pubname = 'show_up_clickhouse'
          and pubinsert and pubupdate and pubdelete and not pubtruncate
          and not puballtables
    ) then
        raise exception 'show_up_clickhouse publication operations are not the reviewed contract';
    end if;

    if exists (
        with expected(tablename, attnames) as (
            values
                ('profiles', array[
                    'id', 'tags', 'city', 'availability', 'embedded_at', 'created_at'
                ]::text[]),
                ('groups', array[
                    'id', 'event_at', 'activity', 'seed_distance', 'created_at',
                    'chosen_venue_id', 'matching_run_key', 'event_timezone',
                    'venue_status', 'chat_opened_at'
                ]::text[]),
                ('group_members', array[
                    'group_id', 'user_id', 'joined_at', 'matching_run_key'
                ]::text[]),
                ('rsvps', array['group_id', 'user_id', 'status']::text[]),
                ('messages', array[
                    'id', 'group_id', 'user_id', 'created_at', 'kind'
                ]::text[]),
                ('venue_options', array[
                    'id', 'group_id', 'position', 'kind', 'locality', 'score'
                ]::text[]),
                ('venue_votes', array[
                    'group_id', 'user_id', 'option_id', 'voted_at'
                ]::text[]),
                ('reflections', array[
                    'group_id', 'user_id', 'about_user', 'was_fallback'
                ]::text[]),
                ('attendance_votes', array[
                    'group_id', 'voter_id', 'subject_id', 'showed_up'
                ]::text[]),
                ('contact_selections', array[
                    'group_id', 'selector_id', 'selected_id', 'created_at'
                ]::text[])
        ),
        actual as (
            select tablename, attnames::text[]
            from pg_publication_tables
            where pubname = 'show_up_clickhouse' and schemaname = 'public'
        )
        select 1
        from expected e
        full join actual a using (tablename)
        where e.tablename is null
           or a.tablename is null
           or (select array_agg(x order by x) from unnest(e.attnames) x)
              is distinct from
              (select array_agg(x order by x) from unnest(a.attnames) x)
    ) then
        raise exception 'show_up_clickhouse tables or columns drifted from the privacy allowlist';
    end if;

    -- ReplacingMergeTree reconciles versions by source identity. Losing even one composite-key
    -- column makes two users' ballots or memberships collapse into the same analytical row.
    if exists (
        select 1
        from pg_publication_tables publication
        join pg_class relation
          on relation.relname = publication.tablename
        join pg_namespace namespace
          on namespace.oid = relation.relnamespace
         and namespace.nspname = publication.schemaname
        where publication.pubname = 'show_up_clickhouse'
          and not exists (
              select 1
              from pg_index identity_index
              where identity_index.indrelid = relation.oid
                and identity_index.indisprimary
                and not exists (
                    select 1
                    from unnest(identity_index.indkey) key(attnum)
                    join pg_attribute attribute
                      on attribute.attrelid = relation.oid
                     and attribute.attnum = key.attnum
                    where not attribute.attname = any(publication.attnames)
                )
          )
    ) then
        raise exception 'a CDC table lacks a primary key fully represented in the publication';
    end if;

    if not exists (
        select 1 from pg_roles
        where rolname = 'clickpipes_user'
          and rolbypassrls
          and not rolsuper
          and not rolcreatedb
          and not rolcreaterole
          and not rolinherit
    ) then
        raise exception 'ClickPipes source role is missing or has authority beyond replication';
    end if;

    -- Spot-checking famous secrets is not enough: the source login is a second confidentiality
    -- boundary because ClickPipes snapshots with ordinary SELECT before CDC starts. Compare every
    -- granted column to the publication so a future private column is denied by default even if a
    -- Terraform exclusion is accidentally omitted.
    if exists (
        with published as (
            select tablename, unnest(attnames)::text as column_name
            from pg_publication_tables
            where pubname = 'show_up_clickhouse' and schemaname = 'public'
        ), granted as (
            select table_name as tablename, column_name
            from information_schema.column_privileges
            where grantee = 'clickpipes_user'
              and table_schema = 'public'
              and privilege_type = 'SELECT'
        )
        select 1
        from published
        full join granted using (tablename, column_name)
        where published.tablename is null or granted.tablename is null
    ) or has_column_privilege('clickpipes_user', 'public.venue_options', 'provider_id', 'select')
       or has_table_privilege('clickpipes_user', 'public.member_assignments', 'select') then
        raise exception 'ClickPipes source grants do not match the analytical privacy boundary';
    end if;
end
$$;
