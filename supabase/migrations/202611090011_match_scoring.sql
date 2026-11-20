begin;

create table public.gameon_match_scores (
  request_id uuid not null references public.gameon_match_requests(id) on delete cascade,
  match_index integer not null check (match_index between 0 and 4),
  revision integer not null check (revision > 0),
  state jsonb not null,
  primary key (request_id, match_index)
);
alter table public.gameon_match_scores enable row level security;
revoke all on public.gameon_match_scores from public, anon, authenticated;
grant select, insert, update on public.gameon_match_scores to service_role;

create function public.gameon_read_match_score(actor uuid, fixture_id uuid, slot_index integer)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  fixture public.gameon_match_requests;
  own_team uuid;
  teams jsonb;
  score public.gameon_match_scores;
  overs integer;
begin
  select * into fixture from public.gameon_match_requests where id = fixture_id;
  select team.id into own_team
  from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = team.captain_id
  where team.captain_id = actor and team.id in (fixture.from_team_id, fixture.to_team_id)
    and profile.role = 'Captain' and profile.completed
    and not exists (select 1 from public.gameon_admins where user_id = actor);
  if own_team is null then raise exception 'Only the two captains can open scoring.' using errcode = '42501'; end if;

  overs := (fixture.plan->'overs'->>slot_index)::integer;
  if fixture.status <> 'accepted' or slot_index not between 0 and 4 or overs is null then
    raise exception 'Scoring requires a confirmed match with an overs limit.';
  end if;

  select * into score from public.gameon_match_scores where request_id = fixture_id and match_index = slot_index;

  select jsonb_agg(jsonb_build_object('id', team.id, 'name', team.name, 'roster', roster.players)
    order by team.id <> fixture.from_team_id)
  into teams
  from public.gameon_teams team
  cross join lateral (
    select coalesce(jsonb_agg(jsonb_build_object('id', profile.id, 'name', profile.name)
      order by profile.id <> team.captain_id, profile.name, profile.id), '[]'::jsonb) as players
    from public.gameon_profiles profile
    where profile.id = team.captain_id or profile.id in (
      select player_id from public.gameon_team_players where team_id = team.id
    )
  ) roster
  where team.id in (fixture.from_team_id, fixture.to_team_id);

  return jsonb_build_object('teams', teams, 'ownTeamId', own_team, 'overs', overs,
    'revision', coalesce(score.revision, 0), 'state', score.state);
end;
$$;

create function public.gameon_save_match_score(
  actor uuid, fixture_id uuid, slot_index integer, expected_revision integer, next_state jsonb
)
returns integer language plpgsql set search_path = public as $$
declare
  current_score jsonb;
  next_revision integer := expected_revision + 1;
begin
  -- Serialize score writes against fixture cancellation and the other captain's writes.
  perform id from public.gameon_match_requests where id = fixture_id for update;
  current_score := public.gameon_read_match_score(actor, fixture_id, slot_index);
  if (current_score->>'revision')::integer <> expected_revision then
    raise exception 'The score changed. Refresh before trying again.';
  end if;
  insert into public.gameon_match_scores(request_id, match_index, revision, state)
  values (fixture_id, slot_index, next_revision, next_state)
  on conflict (request_id, match_index) do update
    set revision = excluded.revision, state = excluded.state;
  return next_revision;
end;
$$;

revoke all on function public.gameon_read_match_score(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.gameon_read_match_score(uuid, uuid, integer) to service_role;
revoke all on function public.gameon_save_match_score(uuid, uuid, integer, integer, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_save_match_score(uuid, uuid, integer, integer, jsonb) to service_role;

commit;
