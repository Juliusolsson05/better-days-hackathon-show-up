-- Make RSVP a server-owned transition rather than a direct table mutation.
--
-- The user owns the decision, but Postgres owns who is making it, whether the person still belongs
-- to the group, and whether the decision window is open. A decline also marks the assignment for
-- repair so remaining members are not shown a room whose headcount and derangement are now stale.

alter table public.groups add column if not exists rsvp_closes_at timestamptz;

update public.groups
set rsvp_closes_at = event_at
where rsvp_closes_at is null;

alter table public.groups alter column rsvp_closes_at set not null;

alter table public.groups add constraint groups_rsvp_before_event check (
    rsvp_closes_at <= event_at
) not valid;

create or replace function public.set_group_rsvp_deadline()
returns trigger
language plpgsql set search_path = public as $$
begin
    if new.rsvp_closes_at is null
       or (tg_op = 'UPDATE'
           and new.event_at is distinct from old.event_at
           and new.rsvp_closes_at is not distinct from old.rsvp_closes_at) then
        new.rsvp_closes_at := new.event_at;
    end if;
    return new;
end;
$$;

create trigger set_group_rsvp_deadline
before insert or update of event_at, rsvp_closes_at
on public.groups
for each row execute function public.set_group_rsvp_deadline();

create or replace function public.set_rsvp(grp uuid, new_status text)
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    deadline timestamptz;
    cancelled timestamptz;
    repair_required boolean;
begin
    if caller is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if new_status is null or new_status not in ('confirmed', 'declined') then
        raise exception 'RSVP must be confirmed or declined' using errcode = '22023';
    end if;

    -- The group row is the serialization point for decisions racing the deadline, cancellation,
    -- or another member's decline. An exact retry is harmless because the update is idempotent.
    select group_row.rsvp_closes_at,
           group_row.cancelled_at,
           group_row.needs_repair
    into deadline, cancelled, repair_required
    from public.groups group_row
    join public.group_members membership on membership.group_id = group_row.id
    where group_row.id = grp and membership.user_id = caller
    for update of group_row;

    if not found or cancelled is not null then
        raise exception 'RSVP access is unavailable' using errcode = '42501';
    end if;
    if repair_required then
        raise exception 'group assignment requires repair' using errcode = '55000';
    end if;
    if now() >= deadline then
        raise exception 'RSVP window is closed' using errcode = '55000';
    end if;

    update public.rsvps
    set status = new_status
    where group_id = grp and user_id = caller;
    if not found then
        -- form_group creates every RSVP row in the same transaction as membership. Missing state
        -- is an integrity problem; silently inserting here would hide a partially formed group.
        raise exception 'group RSVP state is incomplete' using errcode = '55000';
    end if;

    if new_status = 'declined' then
        update public.groups set needs_repair = true where id = grp;
    end if;
end;
$$;

-- Keep reads for the assignment card, but remove every direct mutation route. Dropping the old
-- FOR ALL policy matters even after privilege revocation: it prevents a later broad grant from
-- accidentally restoring the bypass without an explicit policy change.
drop policy if exists "set own rsvp" on public.rsvps;
revoke insert, update, delete on public.rsvps from authenticated;

revoke all on function public.set_group_rsvp_deadline() from public, anon, authenticated;
revoke all on function public.set_rsvp(uuid, text) from public, anon, authenticated;
grant execute on function public.set_rsvp(uuid, text) to authenticated;
