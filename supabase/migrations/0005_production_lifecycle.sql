-- Close the two lifecycle gaps that cannot safely be inferred in Flutter:
--
--   * A profile row is not proof that onboarding finished. submit-profile writes Postgres
--     before the embedding reaches ClickHouse, so an interrupted request deliberately leaves
--     a resumable row with embedded_at = null.
--   * An empty contact selection is still a completed post-meetup flow. Counting selections
--     cannot distinguish "finished and selected nobody" from "has not answered yet".
--
-- Both facts live beside their source data so app restarts and a different device reach the
-- same decision without receiving the private phone column or guessing from nullable rows.
-- This exact version is already recorded by the hosted database, so keeping it in Git is part of
-- the deployment contract: later migrations and fresh environments must share one ordering.

-- Existing demo profiles may predate phone capture. NOT VALID preserves those rows during the
-- deadline upgrade while still rejecting every new insert and every future update that would
-- leave a profile unable to participate in mutual contact exchange.
alter table public.profiles add constraint profiles_phone_required
    check (phone is not null) not valid;

-- A security-definer boolean is intentional here. profiles is group-readable but phone is not,
-- and granting phone SELECT merely so the client can decide onboarding state would undo the
-- strongest privacy boundary in the product. The function reveals no more than whether the
-- caller's own profile has reached every server-side prerequisite.
create or replace function public.profile_ready()
returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from public.profiles p
        where p.id = auth.uid()
          and nullif(btrim(p.display_name), '') is not null
          and nullif(btrim(p.passion), '') is not null
          and nullif(btrim(p.city), '') is not null
          and cardinality(p.tags) > 0
          and cardinality(p.availability) > 0
          and p.photo_url is not null
          and p.phone is not null
          and p.embedded_at is not null
    );
$$;

revoke all on function public.profile_ready() from public, anon, authenticated;
grant execute on function public.profile_ready() to authenticated;

create table public.after_flow_completions (
    group_id uuid not null,
    user_id uuid not null,
    completed_at timestamptz not null default now(),
    primary key (group_id, user_id),
    -- Membership is the durable parent fact for every group-scoped answer. A pair of ordinary
    -- UUID foreign keys would allow a completion to be attached to a real user in the wrong
    -- group, which would make lifecycle restoration lie even if RLS hid the bad row.
    foreign key (group_id, user_id)
        references public.group_members (group_id, user_id) on delete cascade
);

alter table public.after_flow_completions enable row level security;

-- Completion is not socially interesting group data. Showing which members have answered would
-- create the same interpersonal pressure the one-way contact privacy model avoids, so callers
-- can read only their own durable checkpoint and cannot write it outside the final-step RPC.
create policy "read own after-flow completion"
    on public.after_flow_completions for select to authenticated
    using (user_id = auth.uid());

revoke all on table public.after_flow_completions from public, anon, authenticated;
grant select on table public.after_flow_completions to authenticated;
grant all on table public.after_flow_completions to service_role;

-- Replacement, including an empty selection, is the final post-meetup commit. Keeping the
-- completion insert in this function prevents a killed/backgrounded client from recording only
-- half of the decision and makes retries idempotent. completed_at intentionally records the first
-- completion; editing contact choices later does not turn the lifecycle checkpoint into an
-- activity timestamp.
create or replace function public.set_contact_selections(grp uuid, selected uuid[])
returns void
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is null or not exists (
        select 1 from public.group_members
        where group_id = grp and user_id = auth.uid()
    ) then
        raise exception 'not a member of group %', grp using errcode = '42501';
    end if;

    if auth.uid() = any(coalesce(selected, '{}'::uuid[]))
       or exists (
           select 1 from unnest(coalesce(selected, '{}'::uuid[])) s(id)
           where not exists (
               select 1 from public.group_members m
               where m.group_id = grp and m.user_id = s.id
           )
       ) then
        raise exception 'every selected contact must be another member of the group'
            using errcode = '23514';
    end if;

    delete from public.contact_selections
    where group_id = grp and selector_id = auth.uid();

    insert into public.contact_selections (group_id, selector_id, selected_id)
    select grp, auth.uid(), id
    from unnest(coalesce(selected, '{}'::uuid[])) s(id);

    insert into public.after_flow_completions (group_id, user_id)
    values (grp, auth.uid())
    on conflict (group_id, user_id) do nothing;
end;
$$;

revoke all on function public.set_contact_selections(uuid, uuid[]) from public, anon;
grant execute on function public.set_contact_selections(uuid, uuid[]) to authenticated;
