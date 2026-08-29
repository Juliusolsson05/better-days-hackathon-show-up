-- Make restoration and post-meetup eligibility server-owned lifecycle facts.
--
-- A device clock and "latest membership forever" cannot distinguish an upcoming room from a
-- completed, cancelled, or repair-needed group. These timestamps are durable and one narrow RPC
-- returns the only phase the app may restore for its current membership.

alter table public.groups
    add column if not exists ends_at timestamptz,
    add column if not exists after_opens_at timestamptz,
    add column if not exists after_closes_at timestamptz,
    add column if not exists cancelled_at timestamptz;

update public.groups
set ends_at = coalesce(ends_at, event_at + interval '2 hours'),
    after_opens_at = coalesce(after_opens_at, event_at + interval '2 hours'),
    after_closes_at = coalesce(after_closes_at, event_at + interval '7 days');

alter table public.groups
    alter column ends_at set not null,
    alter column after_opens_at set not null,
    alter column after_closes_at set not null;

alter table public.groups add constraint groups_lifecycle_order check (
    event_at <= ends_at
    and ends_at <= after_opens_at
    and after_opens_at < after_closes_at
) not valid;

create or replace function public.set_group_lifecycle_times()
returns trigger
language plpgsql set search_path = public as $$
begin
    if new.ends_at is null
       or (tg_op = 'UPDATE' and new.event_at is distinct from old.event_at
           and new.ends_at is not distinct from old.ends_at) then
        new.ends_at := new.event_at + interval '2 hours';
    end if;
    if new.after_opens_at is null
       or (tg_op = 'UPDATE' and new.event_at is distinct from old.event_at
           and new.after_opens_at is not distinct from old.after_opens_at) then
        new.after_opens_at := new.ends_at;
    end if;
    if new.after_closes_at is null
       or (tg_op = 'UPDATE' and new.event_at is distinct from old.event_at
           and new.after_closes_at is not distinct from old.after_closes_at) then
        new.after_closes_at := new.event_at + interval '7 days';
    end if;
    return new;
end;
$$;

create trigger set_group_lifecycle_times
before insert or update of event_at, ends_at, after_opens_at, after_closes_at
on public.groups
for each row execute function public.set_group_lifecycle_times();

create or replace function public.current_experience()
returns table (group_id uuid, lifecycle_state text)
language sql stable security definer set search_path = public as $$
    select candidate.group_id,
           case
               when candidate.cancelled_at is not null or candidate.needs_repair then 'cancelled'
               when candidate.completed then 'completed'
               when now() < candidate.event_at then 'pre_meetup'
               when now() < candidate.after_opens_at then 'during'
               when now() < candidate.after_closes_at then 'after'
               else 'completed'
           end
    from (
        select membership.group_id,
               group_row.event_at,
               group_row.after_opens_at,
               group_row.after_closes_at,
               group_row.cancelled_at,
               group_row.needs_repair,
               exists (
                   select 1 from public.after_flow_completions completion
                   where completion.group_id = membership.group_id
                     and completion.user_id = membership.user_id
               ) as completed
        from public.group_members membership
        join public.groups group_row on group_row.id = membership.group_id
        where membership.user_id = auth.uid()
        order by membership.joined_at desc, group_row.created_at desc
        limit 1
    ) candidate;
$$;

revoke all on function public.current_experience() from public, anon, authenticated;
grant execute on function public.current_experience() to authenticated;

-- Replace the event-start gate with the actual after-flow window. A modified client cannot submit
-- attendance, reflections, or contact decisions during the meetup or after the review window.
create or replace function public.has_post_meetup_access(grp uuid)
returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from public.groups group_row
        join public.group_members membership on membership.group_id = group_row.id
        where group_row.id = grp
          and membership.user_id = auth.uid()
          and group_row.after_opens_at <= now()
          and group_row.after_closes_at > now()
          and group_row.cancelled_at is null
          and not group_row.needs_repair
    );
$$;

revoke all on function public.set_group_lifecycle_times() from public, anon, authenticated;
