-- Apply after 202611190001_team_roster_and_stats.sql.
begin;

create or replace function public.gameon_team_match_insights(actor uuid, target_team uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  result jsonb;
begin
  if not exists (
    select 1 from public.gameon_teams team where team.id = target_team
      and (team.captain_id = actor or exists (
        select 1 from public.gameon_team_players member
        where member.team_id = team.id and member.player_id = actor
      ))
  ) then raise exception 'Team stats are available to its members.' using errcode = '42501'; end if;

  with completed as (
    select score.state
    from public.gameon_match_scores score
    join public.gameon_match_requests fixture on fixture.id = score.request_id
    where target_team in (fixture.from_team_id, fixture.to_team_id)
      and public.gameon_score_is_complete(score.state)
  ), figures as (
    select
      state->'innings'->0->>'teamId' = target_team::text as batted_first,
      state->'toss'->>'winnerTeamId' as toss_winner,
      state->'toss'->>'decision' as toss_decision,
      totals.scored,
      totals.conceded,
      totals.scored > totals.conceded and (
        state->'result' is null or
        (state->'result'->>'type' = 'ended' and state->'result'->>'reason' = 'completed')
      ) as won
    from completed
    cross join lateral (
      select max((inning->>'runs')::integer) filter (where inning->>'teamId' = target_team::text) as scored,
        max((inning->>'runs')::integer) filter (where inning->>'teamId' <> target_team::text) as conceded
      from jsonb_array_elements(completed.state->'innings') as inning
    ) totals
  )
  select jsonb_build_object(
    'scores', jsonb_build_object(
      'scoredHigh', max(scored), 'scoredLow', min(scored),
      'concededHigh', max(conceded), 'concededLow', min(conceded)
    ),
    'toss', jsonb_build_object(
      'recorded', count(toss_winner),
      'won', count(*) filter (where toss_winner = target_team::text),
      'lost', count(*) filter (where toss_winner <> target_team::text),
      'choseBat', count(*) filter (where toss_winner = target_team::text and toss_decision = 'bat'),
      'choseBowl', count(*) filter (where toss_winner = target_team::text and toss_decision = 'bowl')
    ),
    'batFirst', jsonb_build_object(
      'played', count(*) filter (where batted_first), 'won', count(*) filter (where batted_first and won)
    ),
    'chase', jsonb_build_object(
      'played', count(*) filter (where not batted_first), 'won', count(*) filter (where not batted_first and won)
    )
  ) into result from figures;
  return result;
end;
$$;

revoke all on function public.gameon_team_match_insights(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_team_match_insights(uuid, uuid) to service_role;

commit;
