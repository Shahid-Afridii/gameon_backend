-- Apply after 202611190001_team_roster_and_stats.sql.
begin;

alter table public.gameon_teams drop constraint if exists gameon_teams_captain_id_key;
create index if not exists gameon_teams_captain_idx on public.gameon_teams(captain_id, created_at, id);
alter table public.gameon_profiles
  add column if not exists active_team_id uuid references public.gameon_teams(id) on delete set null;

create or replace function public.gameon_active_captain_team(actor uuid)
returns uuid language sql stable set search_path = '' as $$
  select team.id
  from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = actor
  where team.captain_id = actor
  order by (team.id is distinct from profile.active_team_id), team.created_at, team.id
  limit 1;
$$;

create or replace function public.gameon_manage_captain_team(actor uuid, target_team uuid, details jsonb)
returns uuid language plpgsql set search_path = '' as $$
declare
  profile public.gameon_profiles;
  saved_team uuid;
  team_name text := btrim(details->>'name');
  owns_ground boolean := (details->>'hasGround')::boolean;
  venue_name text := case when owns_ground then btrim(details->>'groundName') else '' end;
  venue_area text := case when owns_ground then btrim(details->>'groundArea') else '' end;
  team_description text := coalesce(btrim(details->>'description'), '');
  venue_amenities text[] := array(select jsonb_array_elements_text(coalesce(details->'amenities', '[]'::jsonb)));
begin
  select * into profile from public.gameon_profiles where id = actor for update;
  if not found or profile.role <> 'Captain' or not profile.completed or exists (
    select 1 from public.gameon_admins where user_id = actor
  ) then raise exception 'Only a captain can manage teams.' using errcode = '42501'; end if;
  if target_team is not null and not exists (
    select 1 from public.gameon_teams where id = target_team and captain_id = actor
  ) then raise exception 'Only this team’s captain can manage it.' using errcode = '42501'; end if;
  if details is not null then
    if team_name is null or char_length(team_name) not between 2 and 60
      or owns_ground is null or char_length(team_description) > 600
      or (owns_ground and (venue_name is null or char_length(venue_name) not between 3 and 100
        or venue_area is null or char_length(venue_area) not between 1 and 250))
      or cardinality(venue_amenities) > 20 or exists (
        select 1 from unnest(venue_amenities) as item where item is null or char_length(btrim(item)) not between 1 and 60
      )
    then raise exception 'Check your team and ground details.'; end if;
    if exists (
      select 1 from public.gameon_teams where captain_id = actor
        and id is distinct from target_team and lower(btrim(name)) = lower(team_name)
    ) then raise exception 'You already captain a team with this name.'; end if;
    if target_team is null then
      insert into public.gameon_teams(captain_id, name, description, has_ground, ground_name, ground_area, amenities)
      values(actor, team_name, team_description, owns_ground, venue_name, venue_area, venue_amenities)
      returning id into saved_team;
    else
      update public.gameon_teams set name = team_name, description = team_description,
        has_ground = owns_ground, ground_name = venue_name, ground_area = venue_area, amenities = venue_amenities
      where id = target_team returning id into saved_team;
    end if;
  else
    if target_team is null then raise exception 'Choose one of your teams.'; end if;
    saved_team := target_team;
  end if;
  update public.gameon_profiles set active_team_id = saved_team where id = actor;
  return saved_team;
end;
$$;

-- Keep old clients working with their active team, without a captain-ID upsert.
create or replace function public.gameon_save_team_details(team_name text, team_description text, owns_ground boolean,
  venue_name text, venue_area text, venue_amenities text[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.gameon_manage_captain_team(auth.uid(), public.gameon_active_captain_team(auth.uid()),
    jsonb_build_object('name', team_name, 'description', team_description, 'hasGround', owns_ground,
      'groundName', venue_name, 'groundArea', venue_area, 'amenities', coalesce(venue_amenities, '{}'::text[])));
end;
$$;

create or replace function public.gameon_save_team(team_name text, owns_ground boolean,
  venue_name text, venue_area text, venue_amenities text[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.gameon_save_team_details(team_name, coalesce((
    select description from public.gameon_teams where id = public.gameon_active_captain_team(auth.uid())
  ), ''), owns_ground, venue_name, venue_area, venue_amenities);
end;
$$;

create or replace function public.gameon_save_profile(display_name text, contact_email text, playing_role text, selected_team text)
returns void language plpgsql security definer set search_path = '' as $$
declare own_team public.gameon_teams%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if char_length(btrim(display_name)) not between 2 and 60 or display_name is null then raise exception 'Invalid name'; end if;
  if playing_role not in ('Player', 'Captain') or playing_role is null then raise exception 'Invalid role'; end if;
  if contact_email is not null and (char_length(contact_email) > 254 or contact_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'Invalid email'; end if;
  selected_team := btrim(coalesce(selected_team, ''));
  if char_length(selected_team) > 60 or (selected_team <> '' and char_length(selected_team) < 2) then raise exception 'Invalid team name'; end if;
  perform 1 from public.gameon_profiles where id = auth.uid() for update;
  if not found then raise exception 'Profile not found'; end if;
  select * into own_team from public.gameon_teams where id = public.gameon_active_captain_team(auth.uid()) for update;
  if own_team.id is not null and playing_role <> 'Captain' and (
    exists (select 1 from public.gameon_teams where captain_id = auth.uid() and id <> own_team.id)
    or exists (select 1 from public.gameon_memberships where team_id = own_team.id)
  ) then raise exception 'Resolve your team ownership and memberships before changing role'; end if;
  if playing_role = 'Player' and selected_team <> '' and not exists(select 1 from public.gameon_teams where name = selected_team) then raise exception 'Choose an existing team'; end if;
  update public.gameon_profiles set name = btrim(display_name), email = contact_email, role = playing_role, completed = true,
    team_name = case when playing_role = 'Player' then selected_team else '' end where id = auth.uid();
  if playing_role = 'Captain' and selected_team <> '' and own_team.id is null then
    -- Legacy onboarding can create a first team. Later edits belong in My Teams.
    insert into public.gameon_teams(captain_id, name) values(auth.uid(), selected_team);
  elsif own_team.id is not null and playing_role <> 'Captain' then
    delete from public.gameon_teams where id = own_team.id;
  end if;
end;
$$;

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
  select team.* into own_team from public.gameon_teams team
  where team.captain_id = actor and team.id = case
    when operation = 'review' then (
      select to_team_id from public.gameon_match_requests where id = (payload->>'requestId')::uuid
    )
    else coalesce((payload->>'sourceTeamId')::uuid, public.gameon_active_captain_team(actor))
  end;
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
    if not found or target.captain_id = actor then raise exception 'Choose another team.'; end if;
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

create or replace function public.gameon_schedule_match(actor uuid, payload jsonb)
returns void language plpgsql set search_path = public as $$
declare
  slots jsonb := payload->'plan'->'schedule';
  slot jsonb;
  start_time timestamptz;
  previous_start timestamptz := now();
  guest_email text := nullif(btrim(payload->'plan'->>'guestEmail'), '');
  own_team_id uuid;
begin
  if jsonb_typeof(slots) is distinct from 'array' or
     jsonb_typeof(payload->'plan'->'overs') is distinct from 'array' then
    raise exception 'Pick a date and time for every match.';
  end if;
  if jsonb_array_length(slots) <> jsonb_array_length(payload->'plan'->'overs') then
    raise exception 'Pick a date and time for every match.';
  end if;
  for slot in select value from jsonb_array_elements(slots) loop
    if coalesce(slot->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or
       coalesce(slot->>'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'Pick a valid date and time for each match.';
    end if;
    start_time := ((slot->>'date')::date + (slot->>'time')::time) at time zone 'Asia/Kolkata';
    if start_time <= previous_start then
      raise exception 'Match times must be in the future and in order.';
    end if;
    previous_start := start_time;
  end loop;

  if guest_email is not null and (char_length(guest_email) > 254 or guest_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
    raise exception 'Enter a valid guest email.';
  end if;

  -- Keep the availability, captain, venue and pending-pair checks in the existing operation.
  own_team_id := coalesce((payload->>'sourceTeamId')::uuid, public.gameon_active_captain_team(actor));
  perform public.gameon_match_action(actor, 'request_with_plan', payload || jsonb_build_object('sourceTeamId', own_team_id));
  perform public.gameon_check_match_slots(own_team_id, (payload->>'teamId')::uuid, payload->'plan');
  update public.gameon_match_requests
  set plan = plan || jsonb_strip_nulls(jsonb_build_object('schedule', slots, 'guestEmail', guest_email))
  where community_id = (payload->>'communityId')::uuid
    and from_team_id = own_team_id and to_team_id = (payload->>'teamId')::uuid and status = 'pending';
  if not found then
    raise exception 'The challenge schedule could not be saved.';
  end if;
end;
$$;

create or replace function public.gameon_match_conversation(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  own_team_id uuid;
  match_request public.gameon_match_requests;
  changes jsonb;
  slot jsonb;
  start_time timestamptz;
  previous_start timestamptz := now();
  notify_user uuid;
  messages jsonb;
begin
  if not exists (
    select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed
  ) then
    raise exception 'Only the two captains can open this match conversation.';
  end if;

  if operation = 'list' then
    select * into match_request from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
  else
    select * into match_request from public.gameon_match_requests where id = (payload->>'requestId')::uuid for update;
  end if;
  select team.id into own_team_id from public.gameon_teams team
  where team.captain_id = actor and team.id in (match_request.from_team_id, match_request.to_team_id);
  if own_team_id is null then
    raise exception 'Only the two captains can open this match conversation.';
  end if;
  if match_request.status not in ('pending', 'accepted') and operation <> 'list' then
    raise exception 'This match conversation is closed.';
  end if;

  if operation = 'review' then
    if payload->>'decision' = 'accepted' and match_request.proposal is not null then
      raise exception 'Resolve the proposed changes before confirming the match.';
    end if;
    perform public.gameon_match_action(actor, 'review', payload);
    if payload->>'decision' = 'accepted' then
      select captain_id into notify_user from public.gameon_teams where id = match_request.from_team_id;
    else
      update public.gameon_match_requests set proposal = null where id = match_request.id;
    end if;
    return jsonb_build_object('notifyUser', notify_user, 'communityId', match_request.community_id);
  elsif operation = 'message' then
    insert into public.gameon_match_messages(request_id, sender_team_id, body)
    values (match_request.id, own_team_id, btrim(payload->>'message'));
  elsif operation in ('propose', 'decide') then
    if operation = 'propose' then
      if match_request.plan->'schedule' is null then raise exception 'This match has no schedule to edit.'; end if;
      if match_request.proposal is not null then raise exception 'Resolve the pending change proposal first.'; end if;
      if (payload->>'version')::integer is distinct from match_request.plan_version then
        raise exception 'The match plan has changed. Reopen the editor and try again.';
      end if;
      changes := payload->'changes';
    else
      if match_request.proposal is null or match_request.proposal->>'id' is distinct from payload->>'proposalId' then
        raise exception 'This proposal has already been resolved.';
      end if;
      if match_request.proposal->>'teamId' = own_team_id::text then
        raise exception 'Only the other captain can respond to this proposal.';
      end if;
      if payload->>'decision' = 'accepted' then changes := match_request.proposal->'changes'; end if;
    end if;
    if changes is not null then
      if coalesce(changes->>'ballType', '') not in ('Stitch ball', 'Tennis ball', 'Cork ball', 'Soft tennis ball') or
         jsonb_typeof(changes->'schedule') is distinct from 'array' or
         jsonb_typeof(changes->'overs') is distinct from 'array' then
        raise exception 'Enter valid match details.';
      end if;
      if jsonb_array_length(changes->'schedule') <> jsonb_array_length(match_request.plan->'overs') or
         jsonb_array_length(changes->'overs') <> jsonb_array_length(match_request.plan->'overs') or exists (
           select 1 from jsonb_array_elements(changes->'overs') as item(value) where value::text !~ '^([1-9]|[1-4][0-9]|50)$'
         ) then
        raise exception 'Enter date, time and overs for every match.';
      end if;
      for slot in select value from jsonb_array_elements(changes->'schedule') loop
        if coalesce(slot->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or
           coalesce(slot->>'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'Pick a valid date and time for each match.';
        end if;
        start_time := ((slot->>'date')::date + (slot->>'time')::time) at time zone 'Asia/Kolkata';
        if start_time <= previous_start then raise exception 'Match times must be in the future and in order.'; end if;
        previous_start := start_time;
      end loop;
    end if;
    if operation = 'propose' then
      update public.gameon_match_requests set proposal = jsonb_build_object(
        'id', gen_random_uuid(), 'teamId', own_team_id, 'changes',
        jsonb_build_object('ballType', changes->'ballType', 'overs', changes->'overs', 'schedule', changes->'schedule')
      ) where id = match_request.id returning * into match_request;
    elsif changes is not null then
      update public.gameon_match_requests set plan = plan || changes, proposal = null, plan_version = plan_version + 1
      where id = match_request.id returning * into match_request;
    else
      update public.gameon_match_requests set proposal = null
      where id = match_request.id returning * into match_request;
    end if;
  elsif operation <> 'list' then
    raise exception 'Unknown match conversation operation.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(recent) order by recent.created_at, recent.id), '[]'::jsonb)
  into messages from (
    select id, sender_team_id, body, created_at from public.gameon_match_messages
    where request_id = match_request.id order by created_at desc, id desc limit 100
  ) recent;
  return jsonb_build_object(
    'messages', messages, 'plan', match_request.plan, 'status', match_request.status,
    'proposal', match_request.proposal, 'version', match_request.plan_version, 'ownTeamId', own_team_id,
    'fromTeam', (select name from public.gameon_teams where id = match_request.from_team_id),
    'toTeam', (select name from public.gameon_teams where id = match_request.to_team_id),
    'incoming', own_team_id = match_request.to_team_id
  );
end;
$$;

create or replace function public.gameon_match_head_to_head(actor uuid, club_id uuid, opponent_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  own_team uuid;
  history jsonb;
begin
  select team.id into own_team
  from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = actor and profile.completed and profile.role = 'Captain'
  join public.gameon_memberships member on member.team_id = team.id and member.community_id = club_id
  where team.captain_id = actor and team.id = public.gameon_active_captain_team(actor)
    and not exists (select 1 from public.gameon_admins where user_id = actor);

  if own_team is null or opponent_id is null or own_team = opponent_id or not exists (
    select 1 from public.gameon_memberships
    where team_id = opponent_id and community_id = club_id
  ) then
    raise exception 'Only a club captain can view this matchup.' using errcode = '42501';
  end if;

  with scorecards as (
    select request.id, request.reviewed_at, score.match_index,
      request.plan->'schedule'->score.match_index as slot,
      coalesce(score.state->'result'->>'type' = 'draw', false) as drawn,
      (score.state->'innings'->0->>'runs')::integer as first_runs,
      (score.state->'innings'->1->>'runs')::integer as chase_runs,
      (score.state->'innings'->1->>'wickets')::integer as chase_wickets,
      (score.state->'innings'->0->>'teamId')::uuid as first_team,
      (score.state->'innings'->1->>'teamId')::uuid as chase_team
    from public.gameon_match_requests request
    join public.gameon_match_scores score on score.request_id = request.id
    where request.community_id = club_id and request.status in ('accepted', 'cancelled')
      and least(request.from_team_id, request.to_team_id) = least(own_team, opponent_id)
      and greatest(request.from_team_id, request.to_team_id) = greatest(own_team, opponent_id)
      and public.gameon_score_is_complete(score.state)
  ), results as (
    select *,
      case
        when drawn then null
        when chase_runs > first_runs then chase_team
        when chase_runs < first_runs then first_team
      end as winner,
      case
        when drawn then null
        when chase_runs > first_runs then 10 - chase_wickets
        else first_runs - chase_runs
      end as margin,
      case when drawn then null when chase_runs > first_runs then 'wickets' else 'runs' end as unit
    from scorecards
  )
  select jsonb_build_object(
    'played', count(*),
    'ownWins', count(*) filter (where winner = own_team),
    'opponentWins', count(*) filter (where winner = opponent_id),
    'ties', count(*) filter (where winner is null and not drawn),
    'draws', count(*) filter (where drawn),
    'lastMeeting', (
      select jsonb_build_object(
        'winnerId', winner, 'margin', margin, 'unit', unit, 'date', slot->>'date', 'drawn', drawn
      )
      from results
      order by coalesce((slot->>'date')::date, reviewed_at::date) desc,
        slot->>'time' desc nulls last, reviewed_at desc, match_index desc, id desc
      limit 1
    )
  ) into history from results;

  return history;
end;
$$;

revoke all on function public.gameon_active_captain_team(uuid),
  public.gameon_manage_captain_team(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.gameon_active_captain_team(uuid),
  public.gameon_manage_captain_team(uuid,uuid,jsonb) to service_role;
commit;
