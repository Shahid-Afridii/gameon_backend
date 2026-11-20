begin;

alter table public.gameon_match_requests
  add column if not exists proposal jsonb,
  add column if not exists plan_version integer not null default 0;

create table if not exists public.gameon_match_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.gameon_match_requests(id) on delete cascade,
  sender_team_id uuid not null references public.gameon_teams(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists gameon_match_messages_recent_idx
  on public.gameon_match_messages(request_id, created_at desc, id desc);
alter table public.gameon_match_messages enable row level security;
revoke all on public.gameon_match_messages from public, anon, authenticated;
grant all on public.gameon_match_messages to service_role;

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
  select id into own_team_id from public.gameon_teams where captain_id = actor;
  if own_team_id is null or not exists (
    select 1 from public.gameon_profiles where id = actor and role = 'Captain' and completed
  ) then
    raise exception 'Only the two captains can open this match conversation.';
  end if;

  if operation = 'list' then
    select * into match_request from public.gameon_match_requests where id = (payload->>'requestId')::uuid;
  else
    select * into match_request from public.gameon_match_requests where id = (payload->>'requestId')::uuid for update;
  end if;
  if not found or own_team_id not in (match_request.from_team_id, match_request.to_team_id) then
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

revoke all on function public.gameon_match_conversation(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_match_conversation(uuid, text, jsonb) to service_role;

commit;
