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

revoke all on function public.gameon_watch_availability(uuid, uuid, uuid, boolean),
  public.gameon_set_availability_and_collect_watches(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_watch_availability(uuid, uuid, uuid, boolean),
  public.gameon_set_availability_and_collect_watches(uuid, jsonb) to service_role;

notify pgrst, 'reload schema';

commit;
