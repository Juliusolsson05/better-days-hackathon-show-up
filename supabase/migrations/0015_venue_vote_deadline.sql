-- A venue decision cannot depend on every member opening the app and voting.
--
-- Complete ballots still finalize immediately. At the deadline, received votes decide; a tie uses
-- grounded retrieval score then stable ballot position, and zero votes choose the strongest
-- grounded option. A scheduled sweep closes rooms even when nobody submits the final trigger row.

alter table public.groups
    add column if not exists venue_vote_closes_at timestamptz;

update public.groups
set venue_vote_closes_at = event_at - interval '24 hours'
where venue_vote_closes_at is null;

alter table public.groups alter column venue_vote_closes_at set not null;

create or replace function public.set_venue_vote_deadline()
returns trigger
language plpgsql set search_path = public as $$
begin
    if new.venue_vote_closes_at is null
       or (tg_op = 'UPDATE'
           and new.event_at is distinct from old.event_at
           and new.venue_vote_closes_at is not distinct from old.venue_vote_closes_at) then
        new.venue_vote_closes_at := new.event_at - interval '24 hours';
    end if;
    if new.venue_vote_closes_at >= new.event_at then
        raise exception 'venue vote deadline must precede the meetup' using errcode = '23514';
    end if;
    return new;
end;
$$;

create trigger set_venue_vote_deadline
before insert or update of event_at, venue_vote_closes_at on public.groups
for each row execute function public.set_venue_vote_deadline();

create or replace function public.finalize_venue_vote(grp uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    winner uuid;
    member_count integer;
    vote_count integer;
    closes_at timestamptz;
    existing_winner uuid;
begin
    select chosen_venue_id, venue_vote_closes_at
    into existing_winner, closes_at
    from public.groups where id = grp for update;
    if not found then
        raise exception 'unknown group %', grp using errcode = '23503';
    end if;
    if existing_winner is not null then return existing_winner; end if;

    select count(*) into member_count
    from public.group_members where group_id = grp;
    select count(*) into vote_count
    from public.venue_votes where group_id = grp;

    if member_count = 0 then return null; end if;
    if vote_count <> member_count and now() < closes_at then return null; end if;

    select option.id into winner
    from public.venue_options option
    left join public.venue_votes vote
      on vote.group_id = option.group_id and vote.option_id = option.id
    where option.group_id = grp
    group by option.id, option.position, option.score
    order by count(vote.user_id) desc, option.score desc nulls last, option.position
    limit 1;

    update public.groups
    set chosen_venue_id = winner, venue_status = 'chosen'
    where id = grp and chosen_venue_id is null;

    insert into public.messages (group_id, user_id, body, kind)
    select grp, null, 'The group picked a venue.', 'system'
    where winner is not null
      and not exists (
          select 1 from public.messages
          where group_id = grp and kind = 'system' and body = 'The group picked a venue.'
      );

    return winner;
end;
$$;

create or replace function public.reject_vote_after_venue_finalized()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
    closes_at timestamptz;
    winner uuid;
begin
    select venue_vote_closes_at, chosen_venue_id into closes_at, winner
    from public.groups where id = new.group_id for update;
    if not found then
        raise exception 'unknown group %', new.group_id using errcode = '23503';
    end if;
    if winner is not null then
        raise exception 'venue voting is already finalized' using errcode = '55000';
    end if;
    if now() >= closes_at then
        raise exception 'venue voting is closed' using errcode = '55000';
    end if;
    return new;
end;
$$;

create or replace function public.finalize_due_venue_votes()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    due_group record;
    finalized integer := 0;
begin
    for due_group in
        select id from public.groups
        where chosen_venue_id is null
          and venue_status = 'voting'
          and venue_vote_closes_at <= now()
        order by venue_vote_closes_at
    loop
        if public.finalize_venue_vote(due_group.id) is not null then
            finalized := finalized + 1;
        end if;
    end loop;
    return finalized;
end;
$$;

revoke all on function public.set_venue_vote_deadline() from public, anon, authenticated;
revoke all on function public.finalize_due_venue_votes() from public, anon, authenticated;
grant execute on function public.finalize_due_venue_votes() to service_role;

select cron.schedule(
    'showup-finalize-venue-votes',
    '*/5 * * * *',
    'select public.finalize_due_venue_votes();'
);
