-- Close the two lifecycle gaps that cannot safely be inferred in Flutter:
--
--   * A profile row is not proof that onboarding finished. submit-profile writes Postgres
--     before the embedding reaches ClickHouse, so an interrupted request deliberately leaves
--     a resumable row with embedded_at = null.
--   * An empty contact selection is still a completed post-meetup flow. Counting selections
--     cannot distinguish "finished and selected nobody" from "has not answered yet".
--
-- This file mirrors migration 0005 already recorded by the hosted database. Keeping deployed
-- history in Git is mandatory: later migrations and fresh environments must share one ordering.

alter table public.profiles add constraint profiles_phone_required
    check (phone is not null) not valid;

-- A security-definer boolean avoids granting phone SELECT merely so the client can decide
-- onboarding state. It reveals only whether the caller's own profile reached every prerequisite.
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
    -- Membership is the durable parent fact. Separate UUID foreign keys would allow a real user
    -- from another group and make lifecycle restoration lie even if RLS hid the corrupt row.
    foreign key (group_id, user_id)
        references public.group_members (group_id, user_id) on delete cascade
);

alter table public.after_flow_completions enable row level security;

-- Completion is not socially interesting group data. Exposing who has answered would create
-- interpersonal pressure, so callers can read only their own durable checkpoint.
create policy "read own after-flow completion"
    on public.after_flow_completions for select to authenticated
    using (user_id = auth.uid());

revoke all on table public.after_flow_completions from public, anon, authenticated;
grant select on table public.after_flow_completions to authenticated;
grant all on table public.after_flow_completions to service_role;

-- Replacement, including an empty selection, is the final post-meetup commit. Keeping the
-- completion insert in this function makes the state transition atomic and retries idempotent.
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
