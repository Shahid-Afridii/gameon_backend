begin;

alter table public.gameon_match_requests drop constraint if exists gameon_match_requests_status_check;
alter table public.gameon_match_requests
  add constraint gameon_match_requests_status_check check (status in ('pending', 'accepted', 'declined', 'cancelled', 'withdrawn'));

create or replace function public.gameon_withdraw_match_request(actor uuid, request_id uuid)
returns void language plpgsql set search_path = public as $$
declare
  challenge public.gameon_match_requests;
begin
  select * into challenge from public.gameon_match_requests where id = request_id for update;
  if not found or not exists (
    select 1 from public.gameon_teams team
    join public.gameon_profiles profile on profile.id = team.captain_id
    where team.id = challenge.from_team_id and team.captain_id = actor
      and profile.role = 'Captain' and profile.completed
      and not exists (select 1 from public.gameon_admins where user_id = actor)
  ) then
    raise exception 'Only the captain who sent the challenge can withdraw it.';
  end if;

  if challenge.status <> 'pending' then
    raise exception 'Only a pending challenge can be withdrawn.';
  end if;

  update public.gameon_match_requests
  set status = 'withdrawn', reviewed_at = now(), proposal = null
  where id = challenge.id;
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
    where own.captain_id = actor and (request.status in ('pending', 'accepted', 'cancelled', 'withdrawn') or latest.created_at is not null)
  ) conversations;
$$;

revoke all on function public.gameon_withdraw_match_request(uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_withdraw_match_request(uuid, uuid) to service_role;

commit;
