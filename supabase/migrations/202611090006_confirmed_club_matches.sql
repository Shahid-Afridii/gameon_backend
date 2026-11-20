begin;

create or replace function public.gameon_confirm_match(actor uuid, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  result jsonb;
  fixture jsonb;
  club_id uuid;
  recipients jsonb;
begin
  -- The existing review locks the request and only the receiving captain can confirm it.
  result := public.gameon_match_conversation(actor, 'review', payload);
  if payload->>'decision' <> 'accepted' then return result; end if;

  select request.community_id, jsonb_build_object(
    'communityName', club.name, 'fromTeam', home.name, 'toTeam', away.name,
    'plan', request.plan - 'guestEmail'
  ) into club_id, fixture
  from public.gameon_match_requests request
  join public.gameon_communities club on club.id = request.community_id
  join public.gameon_teams home on home.id = request.from_team_id
  join public.gameon_teams away on away.id = request.to_team_id
  where request.id = (payload->>'requestId')::uuid;

  select coalesce(jsonb_agg(member.user_id), '[]'::jsonb) into recipients
  from (
    select team.captain_id as user_id
    from public.gameon_memberships membership
    join public.gameon_teams team on team.id = membership.team_id
    where membership.community_id = club_id
    union
    select player.player_id
    from public.gameon_memberships membership
    join public.gameon_team_players player on player.team_id = membership.team_id
    where membership.community_id = club_id
  ) member;

  return result || jsonb_build_object('fixture', fixture, 'recipientIds', recipients);
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
  select coalesce(jsonb_agg(fixture order by reviewed_at desc, request_id), '[]'::jsonb)
  from (
    select request.id as request_id, request.reviewed_at, jsonb_build_object(
      'id', request.id, 'communityName', club.name,
      'fromTeam', home.name, 'toTeam', away.name,
      'plan', request.plan - 'guestEmail'
    ) as fixture
    from public.gameon_match_requests request
    join public.gameon_communities club on club.id = request.community_id
    join public.gameon_teams home on home.id = request.from_team_id
    join public.gameon_teams away on away.id = request.to_team_id
    where request.status = 'accepted' and request.community_id in (select community_id from clubs)
    order by request.reviewed_at desc, request.id
    limit 100
  ) fixtures;
$$;

revoke all on function public.gameon_confirm_match(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_confirm_match(uuid, jsonb) to service_role;
revoke all on function public.gameon_list_confirmed_matches(uuid) from public, anon, authenticated;
grant execute on function public.gameon_list_confirmed_matches(uuid) to service_role;

commit;
