-- Make chat authorship, validation, idempotency, and rate limits one database operation.
--
-- RLS protected the old direct insert from cross-group writes, but the device still supplied the
-- author, kind, and retry behavior. It also left a public room vulnerable to an accidental tight
-- send loop. The RPC derives identity from auth.uid(), serializes a sender's writes, and treats an
-- exact client-id replay as success so an ambiguous network timeout cannot duplicate a message.

create or replace function public.send_message(
    grp uuid,
    client_id uuid,
    message_body text
)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    existing public.messages%rowtype;
    inserted_id bigint;
begin
    if caller is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if client_id is null then
        raise exception 'client message id is required' using errcode = '22023';
    end if;
    if nullif(btrim(message_body), '') is null then
        raise exception 'message cannot be blank' using errcode = '22023';
    end if;
    if char_length(message_body) > 2000 then
        raise exception 'message exceeds 2000 characters' using errcode = '22001';
    end if;
    if not exists (
        select 1 from public.group_members member
        where member.group_id = grp and member.user_id = caller
    ) then
        -- Deliberately does not distinguish an unknown group from a room the caller cannot enter.
        raise exception 'chat access is unavailable' using errcode = '42501';
    end if;

    -- Serialize one person's sends in one room. A count-only limiter lets concurrent requests all
    -- observe the same pre-insert count; this lock makes the ten-per-minute ceiling deterministic.
    perform pg_advisory_xact_lock(
        hashtextextended(caller::text || ':' || grp::text, 0)
    );

    select * into existing
    from public.messages message
    where message.client_msg_id = client_id;
    if found then
        if existing.group_id = grp
           and existing.user_id = caller
           and existing.kind = 'user'
           and existing.body = message_body then
            return existing.id;
        end if;
        raise exception 'client message id is already in use' using errcode = '23505';
    end if;

    if (
        select count(*)
        from public.messages message
        where message.group_id = grp
          and message.user_id = caller
          and message.kind = 'user'
          and message.created_at > now() - interval '1 minute'
    ) >= 10 then
        raise exception 'message rate limit exceeded' using errcode = 'P0001';
    end if;

    insert into public.messages (group_id, user_id, kind, body, client_msg_id)
    values (grp, caller, 'user', message_body, client_id)
    returning id into inserted_id;
    return inserted_id;
end;
$$;

revoke all on function public.send_message(uuid, uuid, text)
    from public, anon, authenticated;
grant execute on function public.send_message(uuid, uuid, text) to authenticated;

-- The RPC above is now the only authenticated mutation door. Dropping the permissive policy and
-- table privilege matters because PostgreSQL ORs policies; adding a safer policy beside the old one
-- would leave the direct PostgREST path intact.
drop policy if exists "post as self" on public.messages;
revoke insert, update, delete, truncate, references, trigger
    on public.messages from anon, authenticated;
