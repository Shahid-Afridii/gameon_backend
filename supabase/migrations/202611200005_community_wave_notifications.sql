begin;

create or replace function public.gameon_community_match_waves(actor uuid, club_id uuid, change jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  source_id uuid := public.gameon_active_captain_team(actor);
  today date := (now() at time zone 'Asia/Kolkata')::date;
  requested_date date;
  source_available boolean;
  notification jsonb;
begin
  if source_id is null or exists (select 1 from public.gameon_admins where user_id = actor)
    or not exists (
      select 1 from public.gameon_memberships m
      join public.gameon_teams t on t.id = m.team_id
      join public.gameon_profiles p on p.id = t.captain_id
      where m.community_id = club_id and m.team_id = source_id
        and p.id = actor and p.role = 'Captain' and p.completed
    ) then
    raise exception 'Only captains in this community can use Match Waves.' using errcode = '42501';
  end if;

  if change ? 'date' then
    if change->>'date' is null then
      delete from public.gameon_match_waves where community_id = club_id and team_id = source_id;
    else
      requested_date := (change->>'date')::date;
      if requested_date < today then
        raise exception 'Choose today or a future match date.';
      end if;

      select t.match_available into source_available
      from public.gameon_teams t where t.id = source_id and t.captain_id = actor for update;
      if source_available is not true then
        raise exception 'Turn on match availability before sending a wave.';
      end if;

      insert into public.gameon_match_waves (community_id, team_id, match_date)
      values (club_id, source_id, requested_date)
      on conflict (community_id, team_id) do update
        set match_date = excluded.match_date, waved_at = now()
        where gameon_match_waves.match_date is distinct from excluded.match_date;

      if found then
        select jsonb_build_object(
          'teamName', t.name,
          'communityName', c.name,
          'date', requested_date,
          'recipientIds', (
            select coalesce(jsonb_agg(recipients.user_id), '[]'::jsonb)
            from (
              select ct.captain_id as user_id
              from public.gameon_memberships m
              join public.gameon_teams ct on ct.id = m.team_id
              where m.community_id = club_id

              union

              select p.player_id as user_id
              from public.gameon_memberships m
              join public.gameon_team_players p on p.team_id = m.team_id
              where m.community_id = club_id
            ) recipients
          )
        )
        into notification
        from public.gameon_teams t
        cross join public.gameon_communities c
        where t.id = source_id and c.id = club_id;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'notification', notification,
    'ownDate', (select w.match_date from public.gameon_match_waves w
      where w.community_id = club_id and w.team_id = source_id and w.match_date >= today),
    'opponents', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'teamId', t.id, 'teamName', t.name, 'captainName', p.name, 'date', w.match_date
      ) order by w.waved_at desc, t.id), '[]'::jsonb)
      from public.gameon_match_waves w
      join public.gameon_teams t on t.id = w.team_id
      join public.gameon_profiles p on p.id = t.captain_id
      where w.community_id = club_id and w.match_date >= today
        and t.captain_id <> actor and t.match_available
        and p.role = 'Captain' and p.completed
    )
  );
end;
$$;

revoke all on function public.gameon_community_match_waves(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_community_match_waves(uuid, uuid, jsonb) to service_role;

commit;
