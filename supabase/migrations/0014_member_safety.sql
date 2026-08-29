-- Give people an immediate safety exit and keep blocked pairs out of future matching.
--
-- These tables are intentionally not group-readable. A report is private moderation material and
-- a block is a one-way decision; exposing either to the subject would create retaliation risk.

create table public.blocked_users (
    blocker_id uuid not null references public.profiles(id) on delete cascade,
    blocked_id uuid not null references public.profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);

create table public.safety_reports (
    id uuid primary key default gen_random_uuid(),
    reporter_id uuid references public.profiles(id) on delete set null,
    reported_id uuid references public.profiles(id) on delete set null,
    group_id uuid references public.groups(id) on delete set null,
    reason text not null check (
        reason in ('harassment', 'hate', 'threats', 'sexual_content', 'spam', 'other')
    ),
    details text,
    status text not null default 'open'
        check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
    created_at timestamptz not null default now(),
    resolved_at timestamptz,
    check (details is null or char_length(details) <= 2000)
);

alter table public.blocked_users enable row level security;
alter table public.safety_reports enable row level security;
revoke all on public.blocked_users, public.safety_reports from public, anon, authenticated;
grant all on public.blocked_users, public.safety_reports to service_role;

alter table public.groups add column if not exists needs_repair boolean not null default false;

create or replace function public.report_user(
    grp uuid,
    reported uuid,
    report_reason text,
    report_details text default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    report_id uuid;
begin
    if caller is null or caller = reported or not exists (
        select 1
        from public.group_members reporter_membership
        join public.group_members subject_membership
          on subject_membership.group_id = reporter_membership.group_id
        where reporter_membership.group_id = grp
          and reporter_membership.user_id = caller
          and subject_membership.user_id = reported
    ) then
        raise exception 'report access is unavailable' using errcode = '42501';
    end if;
    if report_reason is null or report_reason not in (
        'harassment', 'hate', 'threats', 'sexual_content', 'spam', 'other'
    ) then
        raise exception 'unsupported report reason' using errcode = '22023';
    end if;
    if report_details is not null and char_length(report_details) > 2000 then
        raise exception 'report details exceed 2000 characters' using errcode = '22001';
    end if;

    insert into public.safety_reports (reporter_id, reported_id, group_id, reason, details)
    values (caller, reported, grp, report_reason, nullif(btrim(report_details), ''))
    returning id into report_id;
    return report_id;
end;
$$;

create or replace function public.block_user(blocked uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
begin
    if caller is null or caller = blocked or not public.shares_any_group_with(blocked) then
        raise exception 'block access is unavailable' using errcode = '42501';
    end if;

    insert into public.blocked_users (blocker_id, blocked_id)
    values (caller, blocked)
    on conflict (blocker_id, blocked_id) do nothing;
end;
$$;

create or replace function public.leave_group(grp uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
begin
    if caller is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    -- Lock before deletion so a concurrent leave/retry has one stable answer. Treat an exact retry
    -- as success: losing the HTTP response after access was revoked must not strand the UI.
    perform 1 from public.group_members
    where group_id = grp and user_id = caller
    for update;
    if not found then return; end if;

    delete from public.group_members where group_id = grp and user_id = caller;
    update public.groups set needs_repair = true where id = grp;
end;
$$;

revoke all on function public.report_user(uuid, uuid, text, text)
    from public, anon, authenticated;
revoke all on function public.block_user(uuid) from public, anon, authenticated;
revoke all on function public.leave_group(uuid) from public, anon, authenticated;
grant execute on function public.report_user(uuid, uuid, text, text) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
