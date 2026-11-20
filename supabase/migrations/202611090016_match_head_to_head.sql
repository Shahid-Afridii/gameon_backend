begin;

create function public.gameon_match_head_to_head(actor uuid, club_id uuid, opponent_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  own_team uuid;
  history jsonb;
begin
  select team.id into own_team
  from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = actor and profile.completed and profile.role = 'Captain'
  join public.gameon_memberships member on member.team_id = team.id and member.community_id = club_id
  where team.captain_id = actor
    and not exists (select 1 from public.gameon_admins where user_id = actor);

  if own_team is null or opponent_id is null or own_team = opponent_id or not exists (
    select 1 from public.gameon_memberships
    where team_id = opponent_id and community_id = club_id
  ) then
    raise exception 'Only a club captain can view this matchup.' using errcode = '42501';
  end if;

  with scorecards as (
    select request.id, request.reviewed_at, score.match_index,
      request.plan->'schedule'->score.match_index as slot,
      (score.state->>'overs')::integer as overs,
      (score.state->'innings'->0->>'runs')::integer as first_runs,
      (score.state->'innings'->1->>'runs')::integer as chase_runs,
      (score.state->'innings'->1->>'balls')::integer as chase_balls,
      (score.state->'innings'->1->>'wickets')::integer as chase_wickets,
      (score.state->'innings'->0->>'teamId')::uuid as first_team,
      (score.state->'innings'->1->>'teamId')::uuid as chase_team
    from public.gameon_match_requests request
    join public.gameon_match_scores score on score.request_id = request.id
    where request.community_id = club_id and request.status in ('accepted', 'cancelled')
      and least(request.from_team_id, request.to_team_id) = least(own_team, opponent_id)
      and greatest(request.from_team_id, request.to_team_id) = greatest(own_team, opponent_id)
      and jsonb_array_length(score.state->'innings') = 2
  ), results as (
    select *,
      case when chase_runs > first_runs then chase_team when chase_runs < first_runs then first_team end as winner,
      case when chase_runs > first_runs then 10 - chase_wickets else first_runs - chase_runs end as margin,
      case when chase_runs > first_runs then 'wickets' else 'runs' end as unit
    from scorecards
    where chase_runs > first_runs or chase_balls >= overs * 6 or chase_wickets >= 10
  )
  select jsonb_build_object(
    'played', count(*),
    'ownWins', count(*) filter (where winner = own_team),
    'opponentWins', count(*) filter (where winner = opponent_id),
    'ties', count(*) filter (where winner is null),
    'lastMeeting', (
      select jsonb_build_object('winnerId', winner, 'margin', margin, 'unit', unit, 'date', slot->>'date')
      from results
      order by coalesce((slot->>'date')::date, reviewed_at::date) desc,
        slot->>'time' desc nulls last, reviewed_at desc, match_index desc, id desc
      limit 1
    )
  ) into history from results;

  return history;
end;
$$;

revoke all on function public.gameon_match_head_to_head(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_match_head_to_head(uuid, uuid, uuid) to service_role;

commit;
