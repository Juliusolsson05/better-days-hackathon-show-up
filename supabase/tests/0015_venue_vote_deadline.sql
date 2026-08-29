-- Partial and empty ballots must still produce one deterministic venue when time expires.

do $$
declare
    members jsonb := '[
      {"user_id":"00000000-0000-4000-8000-000000000001","target_id":"00000000-0000-4000-8000-000000000002","question":"One"},
      {"user_id":"00000000-0000-4000-8000-000000000002","target_id":"00000000-0000-4000-8000-000000000003","question":"Two"},
      {"user_id":"00000000-0000-4000-8000-000000000003","target_id":"00000000-0000-4000-8000-000000000004","question":"Three"},
      {"user_id":"00000000-0000-4000-8000-000000000004","target_id":"00000000-0000-4000-8000-000000000001","question":"Four"}
    ]'::jsonb;
    grp uuid;
    no_vote_grp uuid;
    low_option uuid;
    high_option uuid;
begin
    grp := public.form_group(
        now() + interval '3 days', null, 'deadline-partial', 0.2, members
    );
    perform public.replace_venue_options(grp, '[
      {"position":1,"venue_id":"low","name":"Low","kind":"cafe","address":"1 St","locality":"SF","lat":37.7,"lng":-122.4,"pitch":"Low","score":0.2,"per_member":[0.2]},
      {"position":2,"venue_id":"high","name":"High","kind":"park","address":"2 St","locality":"SF","lat":37.8,"lng":-122.3,"pitch":"High","score":0.9,"per_member":[0.9]}
    ]'::jsonb);
    select id into low_option from public.venue_options where group_id = grp and position = 1;
    update public.groups set venue_vote_closes_at = now() + interval '1 hour' where id = grp;
    insert into public.venue_votes (group_id, user_id, option_id)
    values (grp, '00000000-0000-4000-8000-000000000001', low_option);
    if public.finalize_venue_vote(grp) is not null then
        raise exception 'partial ballot finalized before its deadline';
    end if;

    update public.groups set venue_vote_closes_at = now() - interval '1 second' where id = grp;
    if public.finalize_venue_vote(grp) <> low_option then
        raise exception 'received vote did not win at the deadline';
    end if;

    no_vote_grp := public.form_group(
        now() + interval '3 days', null, 'deadline-empty', 0.2, members
    );
    perform public.replace_venue_options(no_vote_grp, '[
      {"position":1,"venue_id":"empty-low","name":"Low","kind":"cafe","address":"1 St","locality":"SF","lat":37.7,"lng":-122.4,"pitch":"Low","score":0.2,"per_member":[0.2]},
      {"position":2,"venue_id":"empty-high","name":"High","kind":"park","address":"2 St","locality":"SF","lat":37.8,"lng":-122.3,"pitch":"High","score":0.9,"per_member":[0.9]}
    ]'::jsonb);
    select id into high_option
    from public.venue_options where group_id = no_vote_grp and position = 2;
    update public.groups
    set venue_vote_closes_at = now() - interval '1 second'
    where id = no_vote_grp;
    if public.finalize_due_venue_votes() < 1
       or (select chosen_venue_id from public.groups where id = no_vote_grp) <> high_option then
        raise exception 'zero-vote deadline did not choose the highest grounded score';
    end if;

    if has_function_privilege(
        'authenticated', 'public.finalize_due_venue_votes()', 'execute'
    ) or not has_function_privilege(
        'service_role', 'public.finalize_due_venue_votes()', 'execute'
    ) then
        raise exception 'venue deadline sweep is callable from the wrong API role';
    end if;
    if not exists (
        select 1 from cron.job
        where jobname = 'showup-finalize-venue-votes'
          and schedule = '*/5 * * * *'
          and command = 'select public.finalize_due_venue_votes();'
          and active
    ) then
        raise exception 'venue deadline sweep is not scheduled';
    end if;
end;
$$;
