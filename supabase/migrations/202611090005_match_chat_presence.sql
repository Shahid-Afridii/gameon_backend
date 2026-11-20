begin;

create table if not exists public.gameon_match_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_active_at timestamptz not null
);
alter table public.gameon_match_presence enable row level security;
revoke all on public.gameon_match_presence from public, anon, authenticated;
grant all on public.gameon_match_presence to service_role;

create or replace function public.gameon_touch_match_presence(actor uuid)
returns void language sql set search_path = public as $$
  insert into public.gameon_match_presence(user_id, last_active_at)
  select profile.id, clock_timestamp()
  from public.gameon_profiles profile
  where profile.id = actor and profile.role = 'Captain' and profile.completed
    and exists (select 1 from public.gameon_teams where captain_id = actor)
    and not exists (select 1 from public.gameon_admins where user_id = actor)
  on conflict (user_id) do update
    set last_active_at = greatest(gameon_match_presence.last_active_at, excluded.last_active_at);
$$;

create or replace function public.gameon_match_chat_status(actor uuid, operation text, payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  thread jsonb;
  opponent_read_through timestamptz;
  opponent_last_active_at timestamptz;
  messages jsonb;
begin
  -- This call checks captain membership and records reads for the open thread.
  thread := public.gameon_match_chat(actor, operation, payload);
  select reads.read_through, presence.last_active_at
  into opponent_read_through, opponent_last_active_at
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
    'messages', messages,
    'opponentLastSeenAt', opponent_last_active_at,
    'opponentOnline', coalesce(opponent_last_active_at >= clock_timestamp() - interval '60 seconds', false)
  );
end;
$$;

revoke all on function public.gameon_touch_match_presence(uuid) from public, anon, authenticated;
grant execute on function public.gameon_touch_match_presence(uuid) to service_role;
revoke all on function public.gameon_match_chat_status(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_match_chat_status(uuid, text, jsonb) to service_role;

commit;
