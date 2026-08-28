-- Serialize profile embedding submissions without holding a database transaction across Voyage,
-- Anthropic, and ClickHouse. The UUID is the compare-and-set token; the timestamp is a strictly
-- increasing per-profile version that ClickHouse can use even when an older request finishes last.

alter table public.profiles
    add column if not exists embedding_submission_id uuid,
    add column if not exists embedding_version timestamptz;

-- Ready rows predate this protocol. Giving them a version preserves their current readiness while
-- ensuring every future submission can supersede their ClickHouse row deterministically.
update public.profiles
set embedding_submission_id = coalesce(embedding_submission_id, gen_random_uuid()),
    embedding_version = coalesce(embedding_version, embedded_at)
where embedded_at is not null;

create or replace function public.begin_profile_submission(
    p_user_id uuid,
    p_submission_id uuid,
    p_display_name text,
    p_avatar text,
    p_passion text,
    p_tags text[],
    p_city text,
    p_availability text[],
    p_phone text,
    p_photo_url text
)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
    previous_version timestamptz;
    next_version timestamptz;
begin
    -- An advisory lock also covers first submission, where no profile row exists to lock. Advancing
    -- by one microsecond protects ordering on clocks whose observed resolution is coarser than the
    -- DateTime64(6) value persisted in ClickHouse.
    perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
    select embedding_version into previous_version
    from public.profiles where id = p_user_id;
    next_version := greatest(
        clock_timestamp(),
        coalesce(previous_version + interval '1 microsecond', '-infinity'::timestamptz)
    );

    insert into public.profiles (
        id, display_name, avatar, passion, tags, city, availability, phone, photo_url,
        embedded_at, embedding_submission_id, embedding_version
    ) values (
        p_user_id, p_display_name, p_avatar, p_passion, p_tags, p_city, p_availability,
        p_phone, p_photo_url, null, p_submission_id, next_version
    )
    on conflict (id) do update set
        display_name = excluded.display_name,
        avatar = excluded.avatar,
        passion = excluded.passion,
        tags = excluded.tags,
        city = excluded.city,
        availability = excluded.availability,
        phone = excluded.phone,
        photo_url = excluded.photo_url,
        embedded_at = null,
        embedding_submission_id = excluded.embedding_submission_id,
        embedding_version = excluded.embedding_version;

    return next_version;
end;
$$;

create or replace function public.complete_profile_submission(
    p_user_id uuid,
    p_submission_id uuid,
    p_submission_version timestamptz
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
    changed integer;
begin
    -- An older worker is allowed to finish its external calls, but it must never make the newer
    -- Postgres profile claim readiness for the older ClickHouse representation.
    update public.profiles
    set embedded_at = clock_timestamp()
    where id = p_user_id
      and embedding_submission_id = p_submission_id
      and embedding_version = p_submission_version;
    get diagnostics changed = row_count;
    return changed = 1;
end;
$$;

revoke all on function public.begin_profile_submission(
    uuid, uuid, text, text, text, text[], text, text[], text, text
) from public, anon, authenticated;
grant execute on function public.begin_profile_submission(
    uuid, uuid, text, text, text, text[], text, text[], text, text
) to service_role;
revoke all on function public.complete_profile_submission(uuid, uuid, timestamptz)
    from public, anon, authenticated;
grant execute on function public.complete_profile_submission(uuid, uuid, timestamptz)
    to service_role;
