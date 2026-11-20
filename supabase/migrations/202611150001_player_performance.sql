-- Player performance profile, badges, and manual scorer completion.
-- Run this whole file in the Supabase SQL Editor.
begin;

create index if not exists gameon_match_scores_state_gin
  on public.gameon_match_scores using gin (state jsonb_path_ops);

create or replace function public.gameon_score_is_complete(score_state jsonb)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(
    score_state ? 'result'
    or (
      jsonb_array_length(score_state->'innings') = 2 and (
        (score_state->'innings'->1->>'runs')::integer > (score_state->'innings'->0->>'runs')::integer
        or (score_state->'innings'->1->>'balls')::integer >= (score_state->>'overs')::integer * 6
        or (score_state->'innings'->1->>'wickets')::integer >= 10
      )
    ),
    false
  );
$$;

create or replace function public.gameon_player_performance(actor uuid, target_player uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  profile public.gameon_profiles;
  payload jsonb;
begin
  select * into profile from public.gameon_profiles where id = target_player and completed;
  if profile.id is null then
    raise exception 'Player profile not found.' using errcode = 'P0001';
  end if;

  if actor <> target_player and not exists (
    select 1
    from public.gameon_teams team
    where (
      team.captain_id = actor or exists (
        select 1 from public.gameon_team_players mine
        where mine.team_id = team.id and mine.player_id = actor
      )
    ) and (
      team.captain_id = target_player or exists (
        select 1 from public.gameon_team_players theirs
        where theirs.team_id = team.id and theirs.player_id = target_player
      )
    )
  ) and not exists (
    select 1
    from public.gameon_team_player_requests request
    join public.gameon_teams team on team.id = request.team_id
    where request.player_id = target_player and request.status = 'pending'
      and team.captain_id = actor
  ) then
    raise exception 'Player stats are available to teammates.' using errcode = '42501';
  end if;

  with eligible_scores as materialized (
    select score.request_id, score.match_index, score.state, request.reviewed_at
    from public.gameon_match_scores score
    join public.gameon_match_requests request on request.id = score.request_id
    where public.gameon_score_is_complete(score.state)
      and jsonb_path_exists(
        score.state,
        '$.lineups.*[*] ? (@.id == $player)',
        jsonb_build_object('player', target_player::text)
      )
  ), innings as materialized (
    select score.request_id, score.match_index, score.reviewed_at, inning.value as innings
    from eligible_scores score
    cross join lateral jsonb_array_elements(score.state->'innings') inning(value)
  ), balls as materialized (
    select innings.request_id, innings.match_index, innings.reviewed_at,
      innings.innings->>'teamId' as batting_team_id, delivery.value as ball
    from innings
    cross join lateral jsonb_array_elements(innings.innings->'deliveries') delivery(value)
  ), career as (
    select
      (select count(*) from eligible_scores)::integer as matches,
      count(*) filter (where ball->>'batterId' = target_player::text and ball->>'outcome' <> 'wide')::integer as balls_faced,
      coalesce(sum((ball->>'runs')::integer) filter (where ball->>'batterId' = target_player::text), 0)::integer as runs,
      count(*) filter (where ball->>'batterId' = target_player::text and (ball->>'boundary')::integer = 4)::integer as fours,
      count(*) filter (where ball->>'batterId' = target_player::text and (ball->>'boundary')::integer = 6)::integer as sixes,
      count(*) filter (where ball->>'dismissedId' = target_player::text)::integer as dismissals,
      count(*) filter (where ball->>'bowlerId' = target_player::text and (ball->>'legal')::boolean)::integer as balls_bowled,
      coalesce(sum((ball->>'bowlerRuns')::integer) filter (where ball->>'bowlerId' = target_player::text), 0)::integer as runs_conceded,
      count(*) filter (where ball->>'bowlerId' = target_player::text and (ball->>'bowlerWicket')::boolean)::integer as wickets,
      count(*) filter (where ball->>'fielderId' = target_player::text)::integer as fielding_dismissals,
      count(*) filter (where ball->>'fielderId' = target_player::text and ball->>'dismissal' = 'caught')::integer as catches,
      count(*) filter (where ball->>'fielderId' = target_player::text and ball->>'dismissal' = 'stumped')::integer as stumpings,
      count(*) filter (where ball->>'fielderId' = target_player::text and ball->>'dismissal' in ('runOutStriker', 'runOutNonStriker'))::integer as run_outs
    from balls
  ), innings_figures as (
    select request_id, match_index, reviewed_at,
      coalesce(sum((ball->>'runs')::integer) filter (where ball->>'batterId' = target_player::text), 0)::integer as runs,
      count(*) filter (where ball->>'bowlerId' = target_player::text and (ball->>'bowlerWicket')::boolean)::integer as wickets,
      count(*) filter (where ball->>'bowlerId' = target_player::text and (ball->>'legal')::boolean)::integer as bowling_balls,
      coalesce(sum((ball->>'bowlerRuns')::integer) filter (where ball->>'bowlerId' = target_player::text), 0)::integer as conceded
    from balls group by request_id, match_index, reviewed_at, batting_team_id
  ), bests as (
    select coalesce(max(runs), 0)::integer as high_score,
      coalesce(max(wickets), 0)::integer as best_wickets,
      count(*) filter (where runs >= 50)::integer as fifties,
      count(*) filter (where runs >= 100)::integer as hundreds,
      count(*) filter (where wickets >= 3)::integer as three_fors,
      count(*) filter (where wickets >= 5)::integer as five_fors
    from innings_figures
  ), participants as (
    select score.request_id, score.match_index, player.value->>'id' as player_id
    from eligible_scores score
    cross join lateral jsonb_each(score.state->'lineups') lineup
    cross join lateral jsonb_array_elements(lineup.value) player(value)
  ), match_impacts as (
    select participant.request_id, participant.match_index, participant.player_id,
      coalesce(sum((ball->>'runs')::integer) filter (where ball->>'batterId' = participant.player_id), 0)
      + count(*) filter (where ball->>'bowlerId' = participant.player_id and (ball->>'bowlerWicket')::boolean) * 25
      + count(*) filter (where ball->>'fielderId' = participant.player_id) * 10 as impact
    from participants participant
    left join balls on balls.request_id = participant.request_id and balls.match_index = participant.match_index
    group by participant.request_id, participant.match_index, participant.player_id
  ), ranked_impacts as (
    select *, dense_rank() over (partition by request_id, match_index order by impact desc) as impact_rank
    from match_impacts
  ), awards as (
    select count(*) filter (where player_id = target_player::text and impact_rank = 1 and impact > 0)::integer as player_of_match
    from ranked_impacts
  ), recent as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'runs', form.runs, 'wickets', form.wickets,
      'label', case
        when form.runs > 0 and form.wickets > 0 then form.runs || ' & ' || form.wickets || 'W'
        when form.wickets > 0 then form.wickets || 'W'
        else form.runs::text
      end
    ) order by form.reviewed_at desc, form.request_id desc, form.match_index desc), '[]'::jsonb) as items
    from (
      select request_id, match_index, max(reviewed_at) as reviewed_at,
        sum(runs)::integer as runs, sum(wickets)::integer as wickets
      from innings_figures group by request_id, match_index
      order by reviewed_at desc, request_id desc, match_index desc limit 5
    ) form
  ), badges as (
    select coalesce(jsonb_agg(badge order by rank), '[]'::jsonb) as items from (
      select 1 as rank, jsonb_build_object('id','centurion','title','Centurion','detail','Scored a match century','tone','gold') badge
        from bests where hundreds > 0
      union all select 2, jsonb_build_object('id','run-machine','title','Run Machine','detail','500+ career runs','tone','lime')
        from career where runs >= 500
      union all select 3, jsonb_build_object('id','boundary-hunter','title','Boundary Hunter','detail','25+ boundaries','tone','teal')
        from career where fours + sixes >= 25
      union all select 4, jsonb_build_object('id','five-for','title','Five-for','detail','Five wickets in an innings','tone','gold')
        from bests where five_fors > 0
      union all select 5, jsonb_build_object('id','strike-force','title','Strike Force','detail','10+ career wickets','tone','teal')
        from career where wickets >= 10
      union all select 6, jsonb_build_object('id','safe-hands','title','Safe Hands','detail','5+ fielding dismissals','tone','lime')
        from career where fielding_dismissals >= 5
      union all select 7, jsonb_build_object('id','all-round-impact','title','All-round Impact','detail','250 runs and 10 wickets','tone','gold')
        from career where runs >= 250 and wickets >= 10
    ) earned
  )
  select jsonb_build_object(
    'matches', career.matches,
    'batting', jsonb_build_object(
      'runs', career.runs, 'balls', career.balls_faced, 'highScore', bests.high_score,
      'average', case when career.dismissals = 0 then null else round(career.runs::numeric / career.dismissals, 2) end,
      'strikeRate', case when career.balls_faced = 0 then 0 else round(career.runs::numeric * 100 / career.balls_faced, 2) end,
      'fours', career.fours, 'sixes', career.sixes, 'fifties', bests.fifties, 'hundreds', bests.hundreds
    ),
    'bowling', jsonb_build_object(
      'wickets', career.wickets, 'best', bests.best_wickets,
      'economy', case when career.balls_bowled = 0 then 0 else round(career.runs_conceded::numeric * 6 / career.balls_bowled, 2) end,
      'threeFors', bests.three_fors, 'fiveFors', bests.five_fors
    ),
    'fielding', jsonb_build_object(
      'dismissals', career.fielding_dismissals, 'catches', career.catches,
      'stumpings', career.stumpings, 'runOuts', career.run_outs
    ),
    'awards', jsonb_build_object('playerOfMatch', awards.player_of_match),
    'recent', recent.items, 'badges', badges.items
  ) into payload
  from career cross join bests cross join awards cross join recent cross join badges;

  return payload;
end;
$$;

revoke all on function public.gameon_player_performance(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_player_performance(uuid, uuid) to service_role;

commit;
