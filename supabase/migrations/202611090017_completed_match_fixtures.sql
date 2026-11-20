begin;

create function public.gameon_score_is_complete(score_state jsonb)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(
    jsonb_array_length(score_state->'innings') = 2 and (
      (score_state->'innings'->1->>'runs')::integer > (score_state->'innings'->0->>'runs')::integer
      or (score_state->'innings'->1->>'balls')::integer >= (score_state->>'overs')::integer * 6
      or (score_state->'innings'->1->>'wickets')::integer >= 10
    ),
    false
  );
$$;

revoke all on function public.gameon_score_is_complete(jsonb) from public, anon, authenticated;
grant execute on function public.gameon_score_is_complete(jsonb) to service_role;

create or replace function public.gameon_read_match_score(actor uuid, fixture_id uuid, slot_index integer)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  fixture public.gameon_match_requests;
  own_team uuid;
  captain boolean;
  teams jsonb;
  score public.gameon_match_scores;
  overs integer;
begin
  select * into fixture from public.gameon_match_requests where id = fixture_id;
  select * into score from public.gameon_match_scores where request_id = fixture_id and match_index = slot_index;
  select team.id, team.captain_id = actor and profile.role = 'Captain' into own_team, captain
  from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = actor and profile.completed
  where team.id in (fixture.from_team_id, fixture.to_team_id)
    and not exists (select 1 from public.gameon_admins where user_id = actor)
    and (
      (team.captain_id = actor and profile.role = 'Captain')
      or (
        score.state->'scorers'->>team.id::text = actor::text
        and exists (
          select 1 from public.gameon_team_players member
          where member.team_id = team.id and member.player_id = actor
        )
      )
    )
  order by (team.captain_id = actor and profile.role = 'Captain') desc, team.id
  limit 1;
  if own_team is null and not (
    coalesce(jsonb_array_length(score.state->'innings'), 0) > 0
    and exists (
      select 1 from public.gameon_profiles profile
      where profile.id = actor and profile.completed
        and not exists (select 1 from public.gameon_admins where user_id = actor)
    )
    and exists (
      select 1
      from public.gameon_memberships membership
      join public.gameon_teams team on team.id = membership.team_id
      where membership.community_id = fixture.community_id
        and (team.captain_id = actor or exists (
          select 1 from public.gameon_team_players player
          where player.team_id = team.id and player.player_id = actor
        ))
    )
  ) then
    raise exception 'Only eligible club members can view a started match.' using errcode = '42501';
  end if;

  overs := (fixture.plan->'overs'->>slot_index)::integer;
  if slot_index not between 0 and 4 or overs is null or not (
    fixture.status = 'accepted' or (fixture.status = 'cancelled' and public.gameon_score_is_complete(score.state))
  ) then
    raise exception 'Scoring requires a confirmed match with an overs limit.';
  end if;

  if fixture.status = 'cancelled' then
    own_team := null;
    captain := false;
  end if;

  select jsonb_agg(jsonb_build_object('id', team.id, 'name', team.name, 'captainId', team.captain_id, 'roster', roster.players)
    order by team.id <> fixture.from_team_id)
  into teams
  from public.gameon_teams team
  cross join lateral (
    select coalesce(jsonb_agg(jsonb_build_object('id', profile.id, 'name', profile.name,
      'jerseyNumber', profile.jersey_number, 'cricketRole', profile.cricket_role)
      order by profile.id <> team.captain_id, profile.name, profile.id), '[]'::jsonb) as players
    from public.gameon_profiles profile
    where profile.id = team.captain_id or profile.id in (
      select player_id from public.gameon_team_players where team_id = team.id
    )
  ) roster
  where team.id in (fixture.from_team_id, fixture.to_team_id);

  return jsonb_build_object('teams', teams, 'ownTeamId', own_team, 'isCaptain', coalesce(captain, false), 'overs', overs,
    'revision', coalesce(score.revision, 0), 'state', score.state);
end;
$$;

create or replace function public.gameon_list_confirmed_matches(actor uuid)
returns jsonb language sql stable set search_path = public as $$
  with clubs as (
    select membership.community_id
    from public.gameon_memberships membership
    join public.gameon_teams team on team.id = membership.team_id
    where team.captain_id = actor
      or exists (
        select 1 from public.gameon_team_players player
        where player.team_id = team.id and player.player_id = actor
      )
  )
  select coalesce(jsonb_agg(fixture order by active desc, reviewed_at desc, request_id), '[]'::jsonb)
  from (
    select request.id as request_id, request.reviewed_at,
      request.status = 'accepted' and exists (
        select 1 from public.gameon_match_slots(request.plan) slot
        where upper(slot.period) > now()
          and not exists (
            select 1 from public.gameon_match_scores score
            where score.request_id = request.id and score.match_index = slot.match_number - 1
              and public.gameon_score_is_complete(score.state)
          )
      ) as active, jsonb_build_object(
      'id', request.id, 'communityId', club.id, 'communityName', club.name,
      'fromTeamId', request.from_team_id, 'toTeamId', request.to_team_id,
      'fromTeam', home.name, 'toTeam', away.name,
      'plan', request.plan - 'guestEmail',
      'status', request.status, 'cancellation', request.cancellation,
      'scoringSlots', coalesce((
        select jsonb_agg(score.match_index order by score.match_index)
        from public.gameon_match_scores score
        where score.request_id = request.id and request.status = 'accepted'
          and exists (
            select 1 from public.gameon_team_players member
            where member.player_id = actor and member.team_id in (request.from_team_id, request.to_team_id)
              and score.state->'scorers'->>member.team_id::text = actor::text
          )
      ), '[]'::jsonb),
      'startedSlots', coalesce((
        select jsonb_agg(score.match_index order by score.match_index)
        from public.gameon_match_scores score
        where score.request_id = request.id and request.status = 'accepted'
          and jsonb_array_length(score.state->'innings') > 0
      ), '[]'::jsonb),
      'completedSlots', coalesce((
        select jsonb_agg(score.match_index order by score.match_index)
        from public.gameon_match_scores score
        where score.request_id = request.id and public.gameon_score_is_complete(score.state)
      ), '[]'::jsonb),
      'canCancel', request.status = 'accepted' and actor in (home.captain_id, away.captain_id)
        and exists (select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed)
        and not exists (select 1 from public.gameon_admins where user_id = actor)
    ) as fixture
    from public.gameon_match_requests request
    join public.gameon_communities club on club.id = request.community_id
    join public.gameon_teams home on home.id = request.from_team_id
    join public.gameon_teams away on away.id = request.to_team_id
    where request.status in ('accepted', 'cancelled') and request.community_id in (select community_id from clubs)
    order by active desc, request.reviewed_at desc, request.id
    limit 100
  ) fixtures;
$$;

commit;
