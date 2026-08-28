-- Chat delivery metadata, applied after the shared product contract.
--
-- 0003 owns message kinds and the author/null-author invariant because venue and system rows
-- are shared with multiple edge functions. This migration deliberately adds only the client
-- delivery key used by optimistic rendering and retry, so later chat iterations cannot weaken
-- a database rule that belongs to the whole product.
--
-- Two problems, one column.
--
-- The message is echoed back through the sender's own realtime subscription, so an
-- optimistic bubble and its echo are two renderings of one message with nothing to tie
-- them together -- `id` is a bigserial the client does not learn until the insert returns.
-- The client generates this uuid before sending, so it can reconcile the two.
--
-- It also makes the insert idempotent. A send that times out AFTER Postgres committed but
-- before the response arrived is indistinguishable, from the client, from one that never
-- landed. Without a stable key, the retry double-posts; with `on conflict do nothing` it
-- cannot. This matters on the demo network specifically.
--
-- Nullable because rows written server-side (system, venue_vote) have no client to
-- generate one. PostgreSQL unique constraints deliberately allow multiple NULLs, so an
-- ordinary constraint preserves that while also giving PostgREST a real conflict target.
-- A partial unique index looks attractive, but `upsert(onConflict: 'client_msg_id')`
-- generates `ON CONFLICT (client_msg_id)`, which cannot infer a partial index unless its
-- predicate is repeated -- and PostgREST has no API for supplying that predicate.

alter table messages add column if not exists client_msg_id uuid;

do $$ begin
    alter table messages add constraint messages_client_msg_id_key unique (client_msg_id);
exception when duplicate_object then null;
end $$;

-- No publication change: 0001 already ran `alter publication supabase_realtime add table
-- messages`, and that covers columns added later. Adding it twice raises.

-- Opening is a database transition, not a check-then-insert convention. A cron sweep and a
-- manual demo sweep can overlap; serializing on the group row makes both callers observe one
-- opener without inventing an unnatural unique constraint across all future system messages.
alter table public.groups add column if not exists chat_opened_at timestamptz;
update public.groups g
set chat_opened_at = existing.first_message_at
from (
    select group_id, min(created_at) as first_message_at
    from public.messages
    group by group_id
) existing
where existing.group_id = g.id and g.chat_opened_at is null;

create or replace function public.open_group_chat(grp uuid, opening_body text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
    existing_message_at timestamptz;
begin
    perform 1 from public.groups where id = grp for update;
    if not found then
        raise exception 'unknown group %', grp using errcode = '23503';
    end if;

    if (select chat_opened_at is not null from public.groups where id = grp) then
        return false;
    end if;

    -- Deployed groups can contain messages from before chat_opened_at existed. Treat any such
    -- room as open instead of inserting a greeting above an already-live conversation.
    select min(created_at) into existing_message_at
    from public.messages where group_id = grp;
    if existing_message_at is not null then
        update public.groups set chat_opened_at = existing_message_at where id = grp;
        return false;
    end if;

    insert into public.messages (group_id, user_id, kind, body)
    values (grp, null, 'system', opening_body);
    update public.groups set chat_opened_at = now() where id = grp;
    return true;
end;
$$;

revoke all on function public.open_group_chat(uuid, text) from public, anon, authenticated;
grant execute on function public.open_group_chat(uuid, text) to service_role;
