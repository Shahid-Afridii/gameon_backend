begin;

create or replace function public.gameon_join_community(actor uuid, club_id uuid, source_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.gameon_admins where user_id = actor) then
    raise exception 'Only team captains can join communities.' using errcode = '42501';
  end if;

  -- Use the same lock order as legacy request reviews.
  perform 1 from public.gameon_join_requests r
  where r.community_id = club_id and r.team_id = source_id and r.status = 'pending'
  for update;

  perform 1 from public.gameon_teams t
  join public.gameon_profiles p on p.id = t.captain_id
  where t.id = source_id and p.id = actor and p.role = 'Captain' and p.completed
  for update of t, p;
  if not found then
    raise exception 'Only a captain with a completed profile can join for this team.' using errcode = '42501';
  end if;

  perform 1 from public.gameon_communities c where c.id = club_id for key share;
  if not found then
    raise exception 'Community unavailable.' using errcode = 'P0002';
  end if;

  insert into public.gameon_memberships (community_id, team_id, approved_by)
  values (club_id, source_id, actor)
  on conflict (community_id, team_id) do nothing;

  update public.gameon_join_requests r
  set status = 'approved', seen = true, reviewed_at = now(), reviewed_by = actor
  where r.community_id = club_id and r.team_id = source_id and r.status = 'pending';
end;
$$;

revoke all on function public.gameon_join_community(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.gameon_join_community(uuid, uuid, uuid) to service_role;

commit;
