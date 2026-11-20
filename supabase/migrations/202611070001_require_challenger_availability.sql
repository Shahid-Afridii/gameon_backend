begin;

create or replace function public.gameon_match_action(actor uuid, operation text, payload jsonb)
returns void language plpgsql set search_path = public as $$
declare own_team public.gameon_teams; target public.gameon_teams; invitation public.gameon_match_requests; community uuid;
begin
  select * into own_team from public.gameon_teams where captain_id = actor;
  if not found or not exists (select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed) then
    raise exception 'Only a captain with a completed team can manage matches.';
  end if;
  if operation = 'availability' then
    update public.gameon_teams set match_available = (payload->>'available')::boolean where id = own_team.id;
    return;
  end if;
  if operation = 'request' then
    community := (payload->>'communityId')::uuid;
    select * into target from public.gameon_teams where id = (payload->>'teamId')::uuid;
    if not found or target.id = own_team.id then raise exception 'Choose another team.'; end if;
    perform id from public.gameon_teams where id in (own_team.id, target.id) order by id for update;
    -- Check availability after locking both teams so concurrent toggles cannot bypass it.
    if not exists (select 1 from public.gameon_teams where id = own_team.id and match_available) then
      raise exception 'Turn on your team availability before sending a challenge.';
    end if;
    select * into target from public.gameon_teams t where t.id = target.id;
    if not found or not target.match_available then
      raise exception 'This team is not available for a match.';
    end if;
    if (select count(*) from public.gameon_memberships where community_id = community and team_id in (own_team.id, target.id)) <> 2 then
      raise exception 'Both teams must belong to this community.';
    end if;
    insert into public.gameon_match_requests(community_id, from_team_id, to_team_id) values(community, own_team.id, target.id);
    return;
  end if;
  if operation = 'review' then
    select * into invitation from public.gameon_match_requests where id = (payload->>'requestId')::uuid for update;
    if not found or invitation.to_team_id <> own_team.id then raise exception 'Only the receiving captain can respond.'; end if;
    if invitation.status <> 'pending' then raise exception 'This request has already been answered.'; end if;
    if payload->>'decision' not in ('accepted', 'declined') then raise exception 'Choose accept or decline.'; end if;
    if (select count(*) from public.gameon_memberships where community_id = invitation.community_id and team_id in (invitation.from_team_id, invitation.to_team_id)) <> 2 then
      raise exception 'Both teams must still belong to this community.';
    end if;
    update public.gameon_match_requests set status = payload->>'decision', reviewed_at = now() where id = invitation.id;
    return;
  end if;
  raise exception 'Unknown match operation.';
end;
$$;
revoke all on function public.gameon_match_action(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_match_action(uuid, text, jsonb) to service_role;

commit;
