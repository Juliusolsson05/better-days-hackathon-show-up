-- Make reflection submission one server-owned transition.
--
-- The original policies correctly hide a member's own outbound reflection: SELECT exposes only
-- notes addressed to the caller after they have written. That privacy rule has a non-obvious
-- PostgreSQL consequence: INSERT ... ON CONFLICT DO UPDATE also needs to see the conflicting row,
-- so the app's first submission works and every retry/edit fails with an RLS violation. Granting a
-- broad read-own-row policy would fix the write by leaking the outbound draft into queries meant
-- only for received reflections.
--
-- This RPC is the narrower boundary. It updates behind RLS and derives the recipient from the
-- private assignment rather than accepting a client-selected groupmate. The latter matters too:
-- the old INSERT policy proved only that about_user belonged to the group, so a modified client
-- could address a reflection to somebody other than the assigned target.

create or replace function public.submit_reflection(
    grp uuid,
    reflection_text text,
    fallback boolean default false
)
returns void
language plpgsql security definer set search_path = public as $$
declare
    caller uuid := auth.uid();
    assigned_target uuid;
begin
    if caller is null or not exists (
        select 1 from public.group_members
        where group_id = grp and user_id = caller
    ) then
        raise exception 'not a member of group %', grp using errcode = '42501';
    end if;

    if nullif(btrim(reflection_text), '') is null then
        raise exception 'reflection cannot be blank' using errcode = '22023';
    end if;

    if fallback then
        assigned_target := null;
    else
        select target_id into assigned_target
        from public.member_assignments
        where group_id = grp and user_id = caller;

        if not found then
            -- Guessing a recipient would disclose private prose to the wrong person. A group with
            -- an incomplete assignment needs repair, not a client-side fallback identity.
            raise exception 'private assignment missing for group %', grp using errcode = '55000';
        end if;
    end if;

    insert into public.reflections (
        group_id, user_id, about_user, what_stuck, was_fallback
    ) values (
        grp, caller, assigned_target, btrim(reflection_text), fallback
    )
    on conflict (group_id, user_id) do update
    set about_user = excluded.about_user,
        what_stuck = excluded.what_stuck,
        was_fallback = excluded.was_fallback;
end;
$$;

-- The RPC is the only write door. Leaving direct PostgREST writes enabled would make the assigned
-- target invariant optional for modified clients even though normal app traffic used the RPC.
drop policy if exists "write own reflection" on public.reflections;
drop policy if exists "edit own reflection" on public.reflections;
drop policy if exists "change own reflection" on public.reflections;
revoke insert, update, delete on public.reflections from anon, authenticated;

revoke all on function public.submit_reflection(uuid, text, boolean)
    from public, anon, authenticated;
grant execute on function public.submit_reflection(uuid, text, boolean) to authenticated;
