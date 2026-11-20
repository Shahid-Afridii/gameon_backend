begin;

create table if not exists public.gameon_match_chat_reads (
  request_id uuid not null references public.gameon_match_requests(id) on delete cascade,
  reader_id uuid not null references auth.users(id) on delete cascade,
  read_through timestamptz not null,
  primary key (request_id, reader_id)
);
alter table public.gameon_match_chat_reads enable row level security;
revoke all on public.gameon_match_chat_reads from public, anon, authenticated;
grant all on public.gameon_match_chat_reads to service_role;

create or replace function public.gameon_match_chat(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  thread jsonb;
  request_id uuid := (payload->>'requestId')::uuid;
  reader_team uuid;
  opponent_id uuid;
  opponent_name text;
  sender_name text;
  club_name text;
  seen_at timestamptz;
begin
  thread := public.gameon_match_conversation(actor, operation, payload);
  reader_team := (thread->>'ownTeamId')::uuid;
  select opponent.captain_id, community.name
  into opponent_id, club_name
  from public.gameon_match_requests request
  join public.gameon_communities community on community.id = request.community_id
  join public.gameon_teams opponent on opponent.id = case
    when request.from_team_id = reader_team then request.to_team_id else request.from_team_id end
  where request.id = request_id;

  select name into opponent_name from public.gameon_profiles where id = opponent_id;
  if operation = 'list' then
    select max((message->>'created_at')::timestamptz) into seen_at
    from jsonb_array_elements(thread->'messages') message
    where message->>'sender_team_id' <> reader_team::text;
    if seen_at is not null then
      insert into public.gameon_match_chat_reads(request_id, reader_id, read_through)
      values (request_id, actor, seen_at)
      on conflict on constraint gameon_match_chat_reads_pkey do update
        set read_through = greatest(gameon_match_chat_reads.read_through, excluded.read_through);
    end if;
  elsif operation = 'message' then
    select name into sender_name from public.gameon_profiles where id = actor;
    thread := thread || jsonb_build_object('notifyUser', opponent_id, 'senderName', sender_name);
  end if;
  return thread || jsonb_build_object('captainName', opponent_name, 'communityName', club_name);
end;
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
    where own.captain_id = actor and (request.status in ('pending', 'accepted') or latest.created_at is not null)
  ) conversations;
$$;

revoke all on function public.gameon_match_chat(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_match_chat(uuid, text, jsonb) to service_role;
revoke all on function public.gameon_match_inbox(uuid) from public, anon, authenticated;
grant execute on function public.gameon_match_inbox(uuid) to service_role;

commit;
