begin;

create or replace function public.gameon_team_stats(actor uuid, target_team uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  target public.gameon_teams;
  result jsonb;
begin
  select * into target from public.gameon_teams where id = target_team;
  if not found or (target.captain_id <> actor and not exists (
    select 1 from public.gameon_team_players where team_id = target_team and player_id = actor
  )) then raise exception 'Team stats are available to its members.' using errcode = '42501'; end if;

  with completed as materialized (
    select fixture.id as request_id, score.match_index, score.state, opponent.name as opponent,
      coalesce((score.state->'result'->>'recordedAt')::timestamptz,
        (((fixture.plan->'schedule'->score.match_index->>'date') || 'T' ||
          (fixture.plan->'schedule'->score.match_index->>'time') || ':00+05:30'))::timestamptz,
        fixture.reviewed_at, fixture.created_at) as played_at
    from public.gameon_match_requests fixture
    join public.gameon_match_scores score on score.request_id = fixture.id
    left join public.gameon_teams opponent on opponent.id = case
      when fixture.from_team_id = target_team then fixture.to_team_id else fixture.from_team_id end
    where (fixture.from_team_id = target_team or fixture.to_team_id = target_team)
      and public.gameon_score_is_complete(score.state)
  ), figures as (
    select completed.*, side.own_score, side.other_score,
      case
        when state->'result'->>'type' = 'draw' then 'Draw'
        when own_score is null or other_score is null then 'No result'
        when state->'result'->>'type' = 'ended'
          and state->'result'->>'reason' is distinct from 'completed' then 'No result'
        when own_score = other_score then 'Tie'
        when own_score > other_score then 'Won'
        else 'Lost'
      end as outcome
    from completed
    cross join lateral (
      select max((inning->>'runs')::integer) filter (where inning->>'teamId' = target_team::text) own_score,
        max((inning->>'runs')::integer) filter (where inning->>'teamId' <> target_team::text) other_score
      from jsonb_array_elements(completed.state->'innings') as inning
    ) side
  ), aliases as materialized (
    select id::text old_id, linked_player_id::text current_id
    from public.gameon_manual_players where team_id = target_team and linked_player_id is not null
  ), match_players as (
    select coalesce(aliases.current_id, player->>'id') as player_id,
      max(player->>'name') as name, request_id, match_index
    from completed
    cross join lateral jsonb_array_elements(completed.state->'lineups'->target_team::text) as player
    left join aliases on aliases.old_id = player->>'id'
    group by 1, request_id, match_index
  ), deliveries as (
    select request_id, match_index, inning->>'teamId' = target_team::text as own_batting, delivery as ball
    from completed
    cross join lateral jsonb_array_elements(completed.state->'innings') as inning
    cross join lateral jsonb_array_elements(inning->'deliveries') as delivery
  ), match_contributions as (
    select coalesce(aliases.current_id, stat.player_id) as player_id,
      request_id, match_index, sum(stat.runs)::integer as runs, sum(stat.wickets)::integer as wickets
    from deliveries
    cross join lateral (values
      (case when own_batting then ball->>'batterId' end, coalesce((ball->>'runs')::integer, 0), null::integer),
      (case when own_batting then ball->>'nonStrikerId' end, 0, null::integer),
      (case when not own_batting then ball->>'bowlerId' end, null::integer, case when coalesce((ball->>'bowlerWicket')::boolean,
        ball->>'dismissal' in ('bowled', 'caught', 'lbw', 'stumped', 'hitWicket')) then 1 else 0 end)
    ) as stat(player_id, runs, wickets)
    left join aliases on aliases.old_id = stat.player_id
    where stat.player_id is not null
    group by 1, request_id, match_index
  ), contributions as (
    select player_id, sum(runs)::integer as runs, sum(wickets)::integer as wickets
    from match_contributions
    group by player_id
  ), played as (
    select player_id, request_id, match_index from match_players
    union
    select player_id, request_id, match_index from match_contributions
  ), appearances as (
    select played.player_id, max(match_players.name) as name, count(*)::integer as matches
    from played left join match_players using (player_id, request_id, match_index)
    group by played.player_id
  ), ranked_form as (
    select player_id, request_id, match_index, figures.opponent, figures.played_at,
      match_contributions.runs, match_contributions.wickets,
      row_number() over (
        partition by player_id order by figures.played_at desc nulls last, request_id, match_index desc
      ) as position
    from played
    join figures using (request_id, match_index)
    left join match_contributions using (player_id, request_id, match_index)
  ), player_form as (
    select player_id, jsonb_agg(jsonb_build_object(
      'requestId', request_id, 'matchIndex', match_index, 'opponent', opponent,
      'playedAt', played_at, 'runs', runs, 'wickets', wickets
    ) order by position) as recent
    from ranked_form
    where position <= 5
    group by player_id
  ), people as (
    select profile.id::text player_id, profile.name
    from public.gameon_profiles profile
    where profile.id = target.captain_id or exists (
      select 1 from public.gameon_team_players member where member.team_id = target_team and member.player_id = profile.id
    )
    union all
    select id::text, name from public.gameon_manual_players where team_id = target_team and linked_player_id is null
  )
  select jsonb_build_object(
    'teamId', target_team, 'teamName', target.name,
    'played', (select count(*) from figures),
    'runsFor', coalesce((select sum(own_score) from figures), 0),
    'runsAgainst', coalesce((select sum(other_score) from figures), 0),
    'won', (select count(*) from figures where outcome = 'Won'),
    'lost', (select count(*) from figures where outcome = 'Lost'),
    'tied', (select count(*) from figures where outcome = 'Tie'),
    'drawn', (select count(*) from figures where outcome = 'Draw'),
    'noResult', (select count(*) from figures where outcome = 'No result'),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('requestId', request_id, 'matchIndex', match_index, 'opponent', opponent,
        'outcome', outcome, 'runs', own_score, 'opponentRuns', other_score, 'playedAt', played_at)
        order by played_at desc nulls last, request_id, match_index desc)
      from (select * from figures order by played_at desc nulls last, request_id, match_index desc limit 5) recent
    ), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', player_id, 'name', coalesce(people.name, appearances.name),
        'matches', coalesce(appearances.matches, 0), 'runs', coalesce(contributions.runs, 0),
        'wickets', coalesce(contributions.wickets, 0), 'recent', coalesce(player_form.recent, '[]'::jsonb)) order by coalesce(contributions.runs, 0) desc,
        coalesce(contributions.wickets, 0) desc, coalesce(people.name, appearances.name), player_id)
      from people full join appearances using (player_id)
      left join contributions using (player_id)
      left join player_form using (player_id)
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

commit;
