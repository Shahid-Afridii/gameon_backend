begin;
alter table public.gameon_teams add column if not exists match_available boolean not null default false;
-- Availability is changed only through the authenticated API.
revoke update on public.gameon_teams from authenticated;
grant update (name, has_ground, ground_name, ground_area, amenities) on public.gameon_teams to authenticated;
create table if not exists public.gameon_match_requests (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.gameon_communities(id) on delete cascade,
  from_team_id uuid not null references public.gameon_teams(id) on delete cascade,
  to_team_id uuid not null references public.gameon_teams(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  check (from_team_id <> to_team_id)
);
create unique index if not exists gameon_match_pending_pair_idx on public.gameon_match_requests
  (community_id, least(from_team_id, to_team_id), greatest(from_team_id, to_team_id)) where status = 'pending';
create index if not exists gameon_match_inbox_idx on public.gameon_match_requests(to_team_id, created_at desc);
create index if not exists gameon_match_outbox_idx on public.gameon_match_requests(from_team_id, created_at desc);
alter table public.gameon_match_requests enable row level security;
revoke all on public.gameon_match_requests from public, anon, authenticated;
grant all on public.gameon_match_requests to service_role;
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
    select * into target from public.gameon_teams t where t.id = target.id;
    if not target.match_available then raise exception 'This team is not available for a match.'; end if;
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
-- Leaving a community clears unanswered invitations for that team.
create or replace function public.gameon_clear_departed_match_requests()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.gameon_match_requests where community_id = old.community_id
    and (from_team_id = old.team_id or to_team_id = old.team_id) and status = 'pending';
  return old;
end;
$$;
revoke all on function public.gameon_clear_departed_match_requests() from public, anon, authenticated;
drop trigger if exists gameon_clear_departed_matches on public.gameon_memberships;
create trigger gameon_clear_departed_matches after delete on public.gameon_memberships
  for each row execute function public.gameon_clear_departed_match_requests();
commit;
