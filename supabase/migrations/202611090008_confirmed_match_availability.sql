begin;

create index if not exists gameon_match_from_confirmed_idx
  on public.gameon_match_requests(from_team_id) where status = 'accepted';
create index if not exists gameon_match_to_confirmed_idx
  on public.gameon_match_requests(to_team_id) where status = 'accepted';

create or replace function public.gameon_match_slots(plan jsonb)
returns table(match_number bigint, period tstzrange)
language sql stable set search_path = public as $$
  select slot.number, tstzrange(
    kickoff.start_time,
    kickoff.start_time + make_interval(mins => (plan->'overs'->>((slot.number - 1)::integer))::integer * 8 + 15),
    '[)'
  )
  from jsonb_array_elements(
    case when jsonb_typeof(plan->'schedule') = 'array' then plan->'schedule' else '[]'::jsonb end
  ) with ordinality as slot(value, number)
  cross join lateral (
    select ((slot.value->>'date')::date + (slot.value->>'time')::time) at time zone 'Asia/Kolkata' as start_time
  ) kickoff
  where plan->'overs'->>((slot.number - 1)::integer) is not null;
$$;

create or replace function public.gameon_check_match_slots(first_team uuid, second_team uuid, candidate jsonb, excluded_id uuid default null)
returns void language plpgsql set search_path = public as $$
begin
  if exists (
    select 1 from public.gameon_match_slots(candidate) first_slot
    join public.gameon_match_slots(candidate) next_slot
      on first_slot.match_number < next_slot.match_number and first_slot.period && next_slot.period
  ) then
    raise exception 'The matches in this plan overlap. Pick a later start time.';
  end if;

  if exists (
    select 1
    from public.gameon_match_requests confirmed
    cross join lateral public.gameon_match_slots(confirmed.plan) occupied
    join public.gameon_match_slots(candidate) proposed on occupied.period && proposed.period
    where confirmed.status = 'accepted' and confirmed.id is distinct from excluded_id
      and (confirmed.from_team_id in (first_team, second_team) or confirmed.to_team_id in (first_team, second_team))
  ) then
    raise exception 'That time overlaps a confirmed match for one of the teams. Choose a different time.';
  end if;
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
  perform public.gameon_match_action(actor, 'request_with_plan', payload);
  select id into strict own_team_id from public.gameon_teams where captain_id = actor;
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

create or replace function public.gameon_confirm_match(actor uuid, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  result jsonb;
  fixture jsonb;
  club_id uuid;
  recipients jsonb;
  booking public.gameon_match_requests;
  accepting boolean := payload->>'decision' = 'accepted';
begin
  if accepting then
    select * into booking from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
    -- Always lock both teams in ID order before taking the request lock.
    perform id from public.gameon_teams where id in (booking.from_team_id, booking.to_team_id) order by id for update;
  end if;
  -- The existing review locks the request and only the receiving captain can confirm it.
  result := public.gameon_match_conversation(actor, 'review', payload);
  if not accepting then return result; end if;

  select * into strict booking from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
  if (select count(*) from public.gameon_teams
    where id in (booking.from_team_id, booking.to_team_id) and match_available) <> 2 then
    raise exception 'Both captains must turn on challenge availability before confirming.';
  end if;
  perform public.gameon_check_match_slots(booking.from_team_id, booking.to_team_id, booking.plan, booking.id);
  update public.gameon_teams set match_available = false where id in (booking.from_team_id, booking.to_team_id);

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

create or replace function public.gameon_match_chat_status(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  thread jsonb;
  opponent_read_through timestamptz;
  opponent_last_active_at timestamptz;
  messages jsonb;
  cancellation_details jsonb;
  booking public.gameon_match_requests;
begin
  if operation = 'propose' or (operation = 'decide' and payload->>'decision' = 'accepted') then
    select * into booking from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
    perform id from public.gameon_teams where id in (booking.from_team_id, booking.to_team_id) order by id for update;
  end if;
  -- This call checks captain membership and records reads for the open thread.
  thread := public.gameon_match_chat(actor, operation, payload);
  if operation = 'propose' then
    perform public.gameon_check_match_slots(booking.from_team_id, booking.to_team_id, payload->'changes', booking.id);
  elsif operation = 'decide' and payload->>'decision' = 'accepted' then
    perform public.gameon_check_match_slots(booking.from_team_id, booking.to_team_id, thread->'plan', booking.id);
  end if;
  select reads.read_through, presence.last_active_at, request.cancellation
  into opponent_read_through, opponent_last_active_at, cancellation_details
  from public.gameon_match_requests request
  join public.gameon_teams opponent on opponent.id = case
    when (thread->>'incoming')::boolean then request.from_team_id else request.to_team_id end
  left join public.gameon_match_chat_reads reads on reads.request_id = request.id and reads.reader_id = opponent.captain_id
  left join public.gameon_match_presence presence on presence.user_id = opponent.captain_id
  where request.id = (payload->>'requestId')::uuid;
  select coalesce(jsonb_agg(message || jsonb_build_object(
    'readByOpponent', message->>'sender_team_id' = thread->>'ownTeamId'
      and coalesce((message->>'created_at')::timestamptz <= opponent_read_through, false)
  ) order by position), '[]'::jsonb)
  into messages from jsonb_array_elements(thread->'messages') with ordinality as entries(message, position);
  return thread || jsonb_build_object(
    'messages', messages, 'cancellation', cancellation_details,
    'opponentLastSeenAt', opponent_last_active_at,
    'opponentOnline', coalesce(opponent_last_active_at >= clock_timestamp() - interval '60 seconds', false)
  );
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
  select coalesce(jsonb_agg(fixture order by active desc, reviewed_at desc, request_id), '[]'::jsonb)
  from (
    select request.id as request_id, request.reviewed_at,
      request.status = 'accepted' and exists (
        select 1 from public.gameon_match_slots(request.plan) where upper(period) > now()
      ) as active, jsonb_build_object(
      'id', request.id, 'communityId', club.id, 'communityName', club.name,
      'fromTeamId', request.from_team_id, 'toTeamId', request.to_team_id,
      'fromTeam', home.name, 'toTeam', away.name,
      'plan', request.plan - 'guestEmail',
      'status', request.status, 'cancellation', request.cancellation,
      'canCancel', request.status = 'accepted' and actor in (home.captain_id, away.captain_id)
        and exists (select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed)
        and not exists (select 1 from public.gameon_admins where user_id = actor)
    ) as fixture
    from public.gameon_match_requests request
    join public.gameon_communities club on club.id = request.community_id
    join public.gameon_teams home on home.id = request.from_team_id
    join public.gameon_teams away on away.id = request.to_team_id
    where request.status in ('accepted', 'cancelled') and request.community_id in (select community_id from clubs)
    order by active desc, request.reviewed_at desc, request.id
    limit 100
  ) fixtures;
$$;

revoke all on function public.gameon_match_slots(jsonb) from public, anon, authenticated;
grant execute on function public.gameon_match_slots(jsonb) to service_role;
revoke all on function public.gameon_check_match_slots(uuid, uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.gameon_check_match_slots(uuid, uuid, jsonb, uuid) to service_role;

-- Pause teams that were already booked when this feature was introduced.
update public.gameon_teams team set match_available = false
where team.match_available and exists (
  select 1 from public.gameon_match_requests request
  cross join lateral public.gameon_match_slots(request.plan) slot
  where request.status = 'accepted' and team.id in (request.from_team_id, request.to_team_id)
    and upper(slot.period) > now()
);

commit;
