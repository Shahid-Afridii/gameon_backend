begin;

alter table public.gameon_match_requests add column if not exists plan jsonb;

create or replace function public.gameon_match_action(actor uuid, operation text, payload jsonb)
returns void language plpgsql set search_path = public as $$
declare
  own_team public.gameon_teams;
  target public.gameon_teams;
  invitation public.gameon_match_requests;
  community uuid;
  challenge_plan jsonb;
  venue_kind text;
  venue_name text;
  venue_location text;
begin
  select * into own_team from public.gameon_teams where captain_id = actor;
  if not found or not exists (select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed) then
    raise exception 'Only a captain with a completed team can manage matches.';
  end if;
  if operation = 'availability' then
    update public.gameon_teams set match_available = (payload->>'available')::boolean where id = own_team.id;
    return;
  end if;
  if operation in ('request', 'request_with_plan') then
    community := (payload->>'communityId')::uuid;
    select * into target from public.gameon_teams where id = (payload->>'teamId')::uuid;
    if not found or target.id = own_team.id then raise exception 'Choose another team.'; end if;
    perform id from public.gameon_teams where id in (own_team.id, target.id) order by id for update;
    -- Check availability after locking both teams so concurrent toggles cannot bypass it.
    select * into own_team from public.gameon_teams t where t.id = own_team.id;
    if not found or not own_team.match_available then
      raise exception 'Turn on your team availability before sending a challenge.';
    end if;
    select * into target from public.gameon_teams t where t.id = target.id;
    if not found or not target.match_available then
      raise exception 'This team is not available for a match.';
    end if;
    if (select count(*) from (
      select team_id from public.gameon_memberships
      where community_id = community and team_id in (own_team.id, target.id)
      order by team_id for key share
    ) as admitted) <> 2 then
      raise exception 'Both teams must belong to this community.';
    end if;
    if operation = 'request_with_plan' then
      challenge_plan := payload->'plan';
      if coalesce(challenge_plan->>'ballType', '') not in
        ('Stitch ball', 'Tennis ball', 'Cork ball', 'Soft tennis ball') then
        raise exception 'Choose a ball type.';
      end if;
      if jsonb_typeof(challenge_plan->'overs') is distinct from 'array' then
        raise exception 'Add the overs for each match.';
      end if;
      if jsonb_array_length(challenge_plan->'overs') not between 1 and 5 or exists (
        select 1 from jsonb_array_elements(challenge_plan->'overs') as item(value)
        where value::text !~ '^([1-9]|[1-4][0-9]|50)$'
      ) then
        raise exception 'Choose 1 to 5 matches and 1 to 50 overs per match.';
      end if;

      venue_kind := challenge_plan->'venue'->>'kind';
      case venue_kind
        when 'home' then
          if not own_team.has_ground then raise exception 'Your team no longer has a home ground.'; end if;
          venue_name := own_team.ground_name;
          venue_location := own_team.ground_area;
        when 'away' then
          if not target.has_ground then raise exception 'This team no longer has a home ground.'; end if;
          venue_name := target.ground_name;
          venue_location := target.ground_area;
        when 'neutral' then
          venue_name := 'Neutral ground';
          venue_location := btrim(coalesce(challenge_plan->'venue'->>'location', ''));
          if char_length(venue_location) not between 3 and 250 then
            raise exception 'Enter a location for the neutral ground.';
          end if;
        else raise exception 'Choose a match venue.';
      end case;

      -- Capture the confirmed venue so later team edits do not change the challenge.
      challenge_plan := jsonb_build_object(
        'ballType', challenge_plan->'ballType',
        'overs', challenge_plan->'overs',
        'venue', jsonb_build_object('kind', venue_kind, 'name', venue_name, 'location', venue_location)
      );
    end if;
    insert into public.gameon_match_requests(community_id, from_team_id, to_team_id, plan)
    values(community, own_team.id, target.id, challenge_plan);
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
