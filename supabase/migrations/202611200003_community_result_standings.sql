begin;

create or replace function public.gameon_community_dashboard(actor uuid, club_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  source_id uuid := public.gameon_active_captain_team(actor);
  standings jsonb;
  watched jsonb;
  match_count integer;
begin
  if not exists (select 1 from public.gameon_admins where user_id = actor)
     and not exists (
       select 1 from public.gameon_memberships m
       join public.gameon_teams t on t.id = m.team_id
       where m.community_id = club_id and (
         t.captain_id = actor or exists (
           select 1 from public.gameon_team_players p where p.team_id = t.id and p.player_id = actor
         )
       )
     ) then
    raise exception 'Join this community to view its dashboard.' using errcode = '42501';
  end if;

  with completed as (
    select r.from_team_id, r.to_team_id, score.state
    from public.gameon_match_requests r
    join public.gameon_match_scores score on score.request_id = r.id
    where r.community_id = club_id
      and r.status in ('accepted', 'cancelled')
      and public.gameon_score_is_complete(score.state)
  ), team_results as (
    select side.team_id,
      case
        when c.state->'result'->>'type' = 'draw' then 'draw'
        when totals.scored is null or totals.conceded is null then 'no_result'
        when c.state->'result'->>'type' = 'ended'
          and c.state->'result'->>'reason' is distinct from 'completed' then 'no_result'
        when totals.scored = totals.conceded then 'tie'
        when totals.scored > totals.conceded then 'win'
        else 'loss'
      end as outcome
    from completed c
    cross join lateral (values (c.from_team_id), (c.to_team_id)) side(team_id)
    cross join lateral (
      select max((innings->>'runs')::integer)
          filter (where innings->>'teamId' = side.team_id::text) as scored,
        max((innings->>'runs')::integer)
          filter (where innings->>'teamId' <> side.team_id::text) as conceded
      from jsonb_array_elements(c.state->'innings') innings
    ) totals
  ), ranked as (
    select t.id, t.name, count(tr.outcome) as played,
      count(*) filter (where tr.outcome = 'win') as wins,
      count(*) filter (where tr.outcome = 'loss') as losses,
      count(*) filter (where tr.outcome = 'draw') as draws,
      count(*) filter (where tr.outcome = 'tie') as ties,
      count(*) filter (where tr.outcome = 'no_result') as no_results
    from public.gameon_memberships m
    join public.gameon_teams t on t.id = m.team_id
    left join team_results tr on tr.team_id = t.id
    where m.community_id = club_id
    group by t.id, t.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'teamId', id, 'team', name, 'played', played, 'wins', wins, 'losses', losses,
      'draws', draws, 'ties', ties, 'noResults', no_results
    ) order by wins desc, (played > 0) desc, losses asc, name, id), '[]'::jsonb)
    into standings
  from ranked;

  select coalesce(sum(jsonb_array_length(r.plan->'schedule')), 0)::integer into match_count
  from public.gameon_match_requests r where r.community_id = club_id and r.status = 'accepted';

  select coalesce(jsonb_agg(w.target_team_id), '[]'::jsonb) into watched
  from public.gameon_availability_watches w
  where w.community_id = club_id and w.source_team_id = source_id and w.user_id = actor;

  return jsonb_build_object('standings', standings, 'watchedTeams', watched, 'matchCount', match_count);
end;
$$;

revoke all on function public.gameon_community_dashboard(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_community_dashboard(uuid, uuid) to service_role;

commit;
