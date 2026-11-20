begin;

create table if not exists public.gameon_availability_watches (
  community_id uuid not null,
  source_team_id uuid not null,
  target_team_id uuid not null,
  user_id uuid not null references public.gameon_profiles(id) on delete cascade,
  primary key (community_id, source_team_id, target_team_id, user_id),
  foreign key (community_id, source_team_id)
    references public.gameon_memberships (community_id, team_id) on delete cascade,
  foreign key (community_id, target_team_id)
    references public.gameon_memberships (community_id, team_id) on delete cascade,
  check (source_team_id <> target_team_id)
);
alter table public.gameon_availability_watches enable row level security;
revoke all on public.gameon_availability_watches from public, anon, authenticated;
grant select, insert, delete on public.gameon_availability_watches to service_role;
create index if not exists gameon_availability_watches_target
  on public.gameon_availability_watches (target_team_id);

create or replace function public.gameon_watch_availability(
  actor uuid, club_id uuid, opponent_id uuid, watching boolean
) returns boolean language plpgsql set search_path = public as $$
declare
  source_id uuid := public.gameon_active_captain_team(actor);
  opponent public.gameon_teams;
begin
  if source_id is null or not exists (
    select 1 from public.gameon_profiles p
    join public.gameon_memberships m on m.team_id = source_id and m.community_id = club_id
    where p.id = actor and p.completed and p.role = 'Captain'
  ) or exists (select 1 from public.gameon_admins where user_id = actor) then
    raise exception 'Only a captain in this community can watch availability.' using errcode = '42501';
  end if;
  if not watching then
    delete from public.gameon_availability_watches
    where community_id = club_id and source_team_id = source_id
      and target_team_id = opponent_id and user_id = actor;
    return false;
  end if;

  select t.* into opponent
  from public.gameon_teams t
  join public.gameon_memberships m on m.team_id = t.id and m.community_id = club_id
  where t.id = opponent_id and t.captain_id <> actor
  for update of t;
  if not found then
    raise exception 'Choose another team in this community.' using errcode = '42501';
  end if;
  if opponent.match_available then
    raise exception 'This team is already available.' using errcode = 'P0001';
  end if;
  insert into public.gameon_availability_watches values (club_id, source_id, opponent_id, actor)
  on conflict do nothing;
  return true;
end;
$$;

create or replace function public.gameon_set_availability_and_collect_watches(actor uuid, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  team_id uuid := coalesce((payload->>'sourceTeamId')::uuid, public.gameon_active_captain_team(actor));
  recipients jsonb := '[]'::jsonb;
begin
  perform public.gameon_match_action(actor, 'availability', payload);
  if (payload->>'available')::boolean then
    with cleared as (
      delete from public.gameon_availability_watches w where w.target_team_id = team_id
      returning w.user_id, w.source_team_id, w.community_id
    )
    select coalesce(jsonb_agg(jsonb_build_object('userId', eligible.user_id, 'communityId', eligible.community_id)), '[]'::jsonb)
    into recipients
    from (
      select distinct on (c.user_id) c.user_id, c.community_id
      from cleared c
      join public.gameon_teams t on t.id = c.source_team_id and t.captain_id = c.user_id
      order by c.user_id, c.community_id
    ) eligible;
  end if;
  return jsonb_build_object(
    'recipients', recipients,
    'teamName', (select t.name from public.gameon_teams t where t.id = team_id)
  );
end;
$$;

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
    select
      score.state->'innings'->0 as first_innings,
      score.state->'innings'->1 as chase,
      score.state->'result'->>'type' = 'draw' as drawn
    from public.gameon_match_requests r
    join public.gameon_match_scores score on score.request_id = r.id
    where r.community_id = club_id and r.status in ('accepted', 'cancelled')
      and public.gameon_score_is_complete(score.state)
  ), winners as (
    select case
      when drawn then null
      when (first_innings->>'runs')::int > (chase->>'runs')::int then first_innings->>'teamId'
      when (first_innings->>'runs')::int < (chase->>'runs')::int then chase->>'teamId'
    end as winner
    from completed
  ), ranked as (
    select t.id, t.name, count(w.winner) as wins
    from public.gameon_memberships m
    join public.gameon_teams t on t.id = m.team_id
    left join winners w on w.winner = t.id::text
    where m.community_id = club_id
    group by t.id, t.name
    having count(w.winner) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('teamId', id, 'team', name, 'wins', wins)
    order by wins desc, name, id), '[]'::jsonb) into standings from ranked;

  select coalesce(sum(jsonb_array_length(r.plan->'schedule')), 0)::integer into match_count
  from public.gameon_match_requests r where r.community_id = club_id and r.status = 'accepted';

  select coalesce(jsonb_agg(w.target_team_id), '[]'::jsonb) into watched
  from public.gameon_availability_watches w
  where w.community_id = club_id and w.source_team_id = source_id and w.user_id = actor;

  return jsonb_build_object('standings', standings, 'watchedTeams', watched, 'matchCount', match_count);
end;
$$;

revoke all on function public.gameon_watch_availability(uuid, uuid, uuid, boolean),
  public.gameon_set_availability_and_collect_watches(uuid, jsonb),
  public.gameon_community_dashboard(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_watch_availability(uuid, uuid, uuid, boolean),
  public.gameon_set_availability_and_collect_watches(uuid, jsonb),
  public.gameon_community_dashboard(uuid, uuid) to service_role;

commit;
