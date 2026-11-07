-- Player team requests do not require completing unrelated profile fields.
-- Includes admin-in-Player-mode support; migration 007 may be skipped.
begin;
create or replace function public.gameon_team_player_action(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare target public.gameon_teams; person public.gameon_profiles; invitation public.gameon_team_player_requests;
  recipient uuid; request_id uuid; player uuid; team uuid; decision text;
begin
  if operation = 'review' then
    -- Lock the team before the request, consistently with invitation creation.
    select * into invitation from public.gameon_team_player_requests where id = (payload->>'requestId')::uuid;
    if not found then raise exception 'Request not found.'; end if;
    select * into target from public.gameon_teams where id = invitation.team_id for update;
    select * into invitation from public.gameon_team_player_requests where id = (payload->>'requestId')::uuid for update;
    if not found or invitation.status <> 'pending' then raise exception 'This request has already been answered.'; end if;
    if (invitation.kind = 'invite' and actor <> invitation.player_id) or
       (invitation.kind = 'join' and actor <> target.captain_id) then
      raise exception 'Only the recipient can answer this request.';
    end if;
    decision := payload->>'decision';
    if decision is null or decision not in ('accepted', 'declined') then raise exception 'Choose accept or decline.'; end if;
    if decision = 'accepted' then
      select * into person from public.gameon_profiles where id = invitation.player_id for update;
      if not found or person.role <> 'Player' or exists(select 1 from public.gameon_teams where captain_id = person.id) then
        raise exception 'Use a Player profile to join a team.';
      end if;
      insert into public.gameon_team_players(team_id, player_id) values(invitation.team_id, invitation.player_id);
    end if;
    update public.gameon_team_player_requests set status = decision, reviewed_at = now() where id = invitation.id;
    recipient := case when invitation.kind = 'invite' then target.captain_id else invitation.player_id end;
    return jsonb_build_object('recipientId', recipient, 'requestId', invitation.id, 'teamName', target.name, 'status', decision);
  end if;
  team := (payload->>'teamId')::uuid;
  select * into target from public.gameon_teams where id = team for update;
  if not found then raise exception 'Team not found.'; end if;
  if operation = 'invite' then
    if actor <> target.captain_id or not exists(select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed) then
      raise exception 'Only the team captain can invite players.';
    end if;
    player := (payload->>'playerId')::uuid;
    recipient := player;
  elsif operation = 'join' then
    player := actor;
    recipient := target.captain_id;
  else raise exception 'Unknown team operation.';
  end if;
  select * into person from public.gameon_profiles where id = player for update;
  if not found or person.role <> 'Player' or exists(select 1 from public.gameon_teams where captain_id = person.id) then
    raise exception 'Use a Player profile to join a team.';
  end if;
  if player = target.captain_id then raise exception 'You already captain this team.'; end if;
  if exists(select 1 from public.gameon_team_players where team_id = team and player_id = player) then
    raise exception 'This player is already in the team.';
  end if;
  insert into public.gameon_team_player_requests(team_id, player_id, kind)
    values(team, player, case when operation = 'invite' then 'invite' else 'join' end) returning id into request_id;
  return jsonb_build_object('recipientId', recipient, 'requestId', request_id, 'teamName', target.name, 'status', 'pending');
end;
$$;
revoke all on function public.gameon_team_player_action(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.gameon_team_player_action(uuid,text,jsonb) to service_role;
commit;
