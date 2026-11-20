begin;

create index if not exists gameon_match_conversation_pair_idx
  on public.gameon_match_requests (
    community_id, least(from_team_id, to_team_id), greatest(from_team_id, to_team_id),
    created_at desc, id desc
  );

create or replace function public.gameon_match_chat(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  anchor public.gameon_match_requests;
  current_request public.gameon_match_requests;
  thread jsonb;
  messages jsonb;
  reader_team uuid;
  opponent_id uuid;
  opponent_name text;
  club_name text;
  seen_at timestamptz;
begin
  select * into anchor from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
  -- Authenticate against the linked request before following it to the current challenge.
  if not found or not exists (
    select 1 from public.gameon_teams team
    join public.gameon_profiles profile on profile.id = team.captain_id
    where team.captain_id = actor and profile.role = 'Captain' and profile.completed
      and team.id in (anchor.from_team_id, anchor.to_team_id)
  ) then
    raise exception 'Only the two captains can open this match conversation.';
  end if;

  select * into strict current_request from public.gameon_match_requests request
  where request.community_id = anchor.community_id
    and least(request.from_team_id, request.to_team_id) = least(anchor.from_team_id, anchor.to_team_id)
    and greatest(request.from_team_id, request.to_team_id) = greatest(anchor.from_team_id, anchor.to_team_id)
  order by request.created_at desc, request.id desc limit 1;

  if operation <> 'list' and current_request.id <> anchor.id then
    raise exception 'A newer challenge is available. Reopen the latest match plan and try again.';
  end if;
  thread := public.gameon_match_conversation(
    actor, operation, payload || jsonb_build_object('requestId', current_request.id)
  );
  reader_team := (thread->>'ownTeamId')::uuid;

  select opponent.captain_id, captain.name, community.name
  into opponent_id, opponent_name, club_name
  from public.gameon_communities community
  join public.gameon_teams opponent on opponent.id = case
    when current_request.from_team_id = reader_team then current_request.to_team_id
    else current_request.from_team_id end
  join public.gameon_profiles captain on captain.id = opponent.captain_id
  where community.id = current_request.community_id;

  select coalesce(jsonb_agg(to_jsonb(recent) order by recent.created_at, recent.id), '[]'::jsonb)
  into messages from (
    select message.id, message.request_id, message.sender_team_id, message.body, message.created_at
    from public.gameon_match_requests request
    join public.gameon_match_messages message on message.request_id = request.id
    where request.community_id = anchor.community_id
      and least(request.from_team_id, request.to_team_id) = least(anchor.from_team_id, anchor.to_team_id)
      and greatest(request.from_team_id, request.to_team_id) = greatest(anchor.from_team_id, anchor.to_team_id)
    order by message.created_at desc, message.id desc limit 100
  ) recent;

  if operation = 'list' then
    seen_at := (messages->-1->>'created_at')::timestamptz;
    insert into public.gameon_match_chat_reads(request_id, reader_id, read_through)
    select request.id, actor, max(message.created_at)
    from public.gameon_match_requests request
    join public.gameon_match_messages message on message.request_id = request.id
    where request.community_id = anchor.community_id
      and least(request.from_team_id, request.to_team_id) = least(anchor.from_team_id, anchor.to_team_id)
      and greatest(request.from_team_id, request.to_team_id) = greatest(anchor.from_team_id, anchor.to_team_id)
      and message.sender_team_id <> reader_team and message.created_at <= seen_at
    group by request.id
    order by request.id
    on conflict on constraint gameon_match_chat_reads_pkey do update
      set read_through = greatest(gameon_match_chat_reads.read_through, excluded.read_through);
  elsif operation = 'message' then
    thread := thread || jsonb_build_object(
      'notifyUser', opponent_id,
      'senderName', (select name from public.gameon_profiles where id = actor)
    );
  end if;
  return thread || jsonb_build_object(
    'requestId', current_request.id, 'messages', messages,
    'captainName', opponent_name, 'communityName', club_name
  );
end;
$$;

create or replace function public.gameon_match_inbox(actor uuid)
returns jsonb language sql stable set search_path = public as $$
  with participant_requests as (
    select request.*, own.id as own_team_id,
      case when request.from_team_id = own.id then request.to_team_id else request.from_team_id end as opponent_id
    from public.gameon_teams own
    join public.gameon_profiles reader on reader.id = own.captain_id and reader.role = 'Captain' and reader.completed
    join public.gameon_match_requests request on own.id in (request.from_team_id, request.to_team_id)
    where own.captain_id = actor
  ), current_requests as (
    select distinct on (community_id, own_team_id, opponent_id) *
    from participant_requests
    order by community_id, own_team_id, opponent_id, created_at desc, id desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'requestId', request.id,
    'conversationId', concat_ws(':', request.community_id, least(request.own_team_id, request.opponent_id),
      greatest(request.own_team_id, request.opponent_id)),
    'communityName', community.name, 'teamName', opponent.name, 'captainName', captain.name,
    'status', request.status, 'activityAt', greatest(request.created_at, latest.created_at, request.reviewed_at),
    'message', latest.body, 'isOwnMessage', coalesce(latest.sender_team_id = request.own_team_id, false),
    'unread', unread.count
  ) order by greatest(request.created_at, latest.created_at, request.reviewed_at) desc, request.id), '[]'::jsonb)
  from current_requests request
  join public.gameon_communities community on community.id = request.community_id
  join public.gameon_teams opponent on opponent.id = request.opponent_id
  join public.gameon_profiles captain on captain.id = opponent.captain_id
  left join lateral (
    select message.body, message.sender_team_id, message.created_at
    from participant_requests history
    join public.gameon_match_messages message on message.request_id = history.id
    where (history.community_id, history.own_team_id, history.opponent_id) =
      (request.community_id, request.own_team_id, request.opponent_id)
    order by message.created_at desc, message.id desc limit 1
  ) latest on true
  cross join lateral (
    select count(*) from participant_requests history
    join public.gameon_match_messages message on message.request_id = history.id
    left join public.gameon_match_chat_reads seen on seen.request_id = history.id and seen.reader_id = actor
    where (history.community_id, history.own_team_id, history.opponent_id) =
      (request.community_id, request.own_team_id, request.opponent_id)
      and message.sender_team_id <> request.own_team_id
      and message.created_at > coalesce(seen.read_through, '-infinity'::timestamptz)
  ) unread
  where request.status <> 'declined' or latest.created_at is not null;
$$;

create or replace function public.gameon_match_chat_status(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  thread jsonb;
  opponent_id uuid;
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
  select opponent.captain_id, presence.last_active_at, request.cancellation
  into opponent_id, opponent_last_active_at, cancellation_details
  from public.gameon_match_requests request
  join public.gameon_teams opponent on opponent.id = case
    when (thread->>'incoming')::boolean then request.from_team_id else request.to_team_id end
  left join public.gameon_match_presence presence on presence.user_id = opponent.captain_id
  where request.id = (thread->>'requestId')::uuid;
  select coalesce(jsonb_agg(message || jsonb_build_object(
    'readByOpponent', message->>'sender_team_id' = thread->>'ownTeamId'
      and coalesce((message->>'created_at')::timestamptz <= reads.read_through, false)
  ) order by position), '[]'::jsonb)
  into messages from jsonb_array_elements(thread->'messages') with ordinality as entries(message, position)
  left join public.gameon_match_chat_reads reads
    on reads.request_id = (message->>'request_id')::uuid and reads.reader_id = opponent_id;
  return thread || jsonb_build_object(
    'messages', messages, 'cancellation', cancellation_details,
    'opponentLastSeenAt', opponent_last_active_at,
    'opponentOnline', coalesce(opponent_last_active_at >= clock_timestamp() - interval '60 seconds', false)
  );
end;
$$;

commit;
