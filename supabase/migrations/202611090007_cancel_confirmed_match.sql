begin;

alter table public.gameon_match_requests
  add column if not exists cancellation jsonb;
alter table public.gameon_match_requests
  drop constraint if exists gameon_match_requests_status_check;
alter table public.gameon_match_requests
  add constraint gameon_match_requests_status_check check (status in ('pending', 'accepted', 'declined', 'cancelled'));

create or replace function public.gameon_cancel_match(actor uuid, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  own_team public.gameon_teams;
  request public.gameon_match_requests;
  reason text := btrim(coalesce(payload->>'reason', ''));
  details jsonb;
begin
  select team.* into own_team from public.gameon_teams team
  join public.gameon_profiles profile on profile.id = team.captain_id
  where team.captain_id = actor and profile.role = 'Captain' and profile.completed
    and not exists (select 1 from public.gameon_admins where user_id = actor);
  if not found then raise exception 'Only either team captain can cancel this match.'; end if;

  select * into request from public.gameon_match_requests where id = (payload->>'requestId')::uuid for update;
  if not found or own_team.id not in (request.from_team_id, request.to_team_id) then
    raise exception 'Only either team captain can cancel this match.';
  end if;
  if request.status <> 'accepted' then raise exception 'Only a confirmed match can be cancelled.'; end if;
  if char_length(reason) not between 3 and 500 then raise exception 'Enter a cancellation reason between 3 and 500 characters.'; end if;

  details := jsonb_build_object('reason', reason, 'teamName', own_team.name, 'cancelledAt', clock_timestamp());
  update public.gameon_match_requests
  set status = 'cancelled', cancellation = details, proposal = null
  where id = request.id;
  return details;
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
begin
  -- This call checks captain membership and records reads for the open thread.
  thread := public.gameon_match_chat(actor, operation, payload);
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
  select coalesce(jsonb_agg(fixture order by reviewed_at desc, request_id), '[]'::jsonb)
  from (
    select request.id as request_id, request.reviewed_at, jsonb_build_object(
      'id', request.id, 'communityName', club.name,
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
    order by request.reviewed_at desc, request.id
    limit 100
  ) fixtures;
$$;

create or replace function public.gameon_match_inbox(actor uuid)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(thread order by activity desc, request_id), '[]'::jsonb)
  from (
    select request.id as request_id, coalesce(latest.created_at, request.created_at) as activity,
      jsonb_build_object(
        'requestId', request.id,
        'communityName', community.name,
        'teamName', opponent.name,
        'captainName', captain.name,
        'status', request.status,
        'activityAt', coalesce(latest.created_at, request.created_at),
        'message', latest.body,
        'isOwnMessage', coalesce(latest.sender_team_id = own.id, false),
        'unread', unread.count
      ) as thread
    from public.gameon_teams own
    join public.gameon_profiles reader on reader.id = own.captain_id and reader.role = 'Captain' and reader.completed
    join public.gameon_match_requests request on own.id in (request.from_team_id, request.to_team_id)
    join public.gameon_communities community on community.id = request.community_id
    join public.gameon_teams opponent on opponent.id = case when request.from_team_id = own.id then request.to_team_id else request.from_team_id end
    join public.gameon_profiles captain on captain.id = opponent.captain_id
    left join public.gameon_match_chat_reads seen on seen.request_id = request.id and seen.reader_id = actor
    left join lateral (
      select body, sender_team_id, created_at from public.gameon_match_messages
      where request_id = request.id order by created_at desc, id desc limit 1
    ) latest on true
    cross join lateral (
      select count(*) from public.gameon_match_messages
      where request_id = request.id and sender_team_id <> own.id
        and created_at > coalesce(seen.read_through, '-infinity'::timestamptz)
    ) unread
    where own.captain_id = actor and (request.status in ('pending', 'accepted', 'cancelled') or latest.created_at is not null)
  ) conversations;
$$;

revoke all on function public.gameon_cancel_match(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_cancel_match(uuid, jsonb) to service_role;

commit;
