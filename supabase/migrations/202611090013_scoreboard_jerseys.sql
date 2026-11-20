begin;

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
  if own_team is null then
    raise exception 'Only the captains and assigned scorers can open this scoreboard.' using errcode = '42501';
  end if;

  overs := (fixture.plan->'overs'->>slot_index)::integer;
  if fixture.status <> 'accepted' or slot_index not between 0 and 4 or overs is null then
    raise exception 'Scoring requires a confirmed match with an overs limit.';
  end if;

  select jsonb_agg(jsonb_build_object('id', team.id, 'name', team.name, 'captainId', team.captain_id, 'roster', roster.players)
    order by team.id <> fixture.from_team_id)
  into teams
  from public.gameon_teams team
  cross join lateral (
    select coalesce(jsonb_agg(jsonb_build_object('id', profile.id, 'name', profile.name, 'jerseyNumber', profile.jersey_number)
      order by profile.id <> team.captain_id, profile.name, profile.id), '[]'::jsonb) as players
    from public.gameon_profiles profile
    where profile.id = team.captain_id or profile.id in (
      select player_id from public.gameon_team_players where team_id = team.id
    )
  ) roster
  where team.id in (fixture.from_team_id, fixture.to_team_id);

  return jsonb_build_object('teams', teams, 'ownTeamId', own_team, 'isCaptain', captain, 'overs', overs,
    'revision', coalesce(score.revision, 0), 'state', score.state);
end;
$$;

commit;
