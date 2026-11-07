-- GameOn: community database foundation.
-- Run the ENTIRE file in the Supabase SQL Editor. Safe to rerun; existing rows are preserved.
-- Static client codes do NOT authenticate Supabase users. Auth integration follows this migration.
begin;
create schema if not exists gameon_private;
revoke all on schema gameon_private from public, anon;
grant usage on schema gameon_private to authenticated;

create table if not exists public.gameon_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 60),
  phone text unique check (phone ~ '^[6-9][0-9]{9}$'),
  email text,
  role text not null default 'Player' check (role in ('Player', 'Captain')),
  completed boolean not null default false,
  created_at timestamptz not null default now()
);
-- Only a trusted server or SQL Editor may assign superadmins. Never use user-editable metadata.
create table if not exists public.gameon_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create or replace function gameon_private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.gameon_admins where user_id = (select auth.uid()));
$$;
revoke all on function gameon_private.is_admin() from public, anon;
grant execute on function gameon_private.is_admin() to authenticated;

create table if not exists public.gameon_teams (
  id uuid primary key default gen_random_uuid(),
  captain_id uuid not null unique references public.gameon_profiles(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 60),
  has_ground boolean not null default false,
  ground_name text not null default '',
  ground_area text not null default '',
  amenities text[] not null default '{}',
  created_at timestamptz not null default now(),
  check (not has_ground or (char_length(btrim(ground_name)) >= 3 and char_length(btrim(ground_area)) > 0))
);
create table if not exists public.gameon_communities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 3 and 80),
  location text not null check (char_length(btrim(location)) between 2 and 100),
  description text not null check (char_length(btrim(description)) between 10 and 1000),
  rules text[] not null check (cardinality(rules) between 1 and 12),
  category text not null check (category in ('Corporate', 'Local')),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create unique index if not exists gameon_unique_community on public.gameon_communities(lower(btrim(name)), lower(btrim(location)));
create table if not exists public.gameon_join_requests (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.gameon_communities(id) on delete cascade,
  team_id uuid not null references public.gameon_teams(id) on delete cascade,
  captain_id uuid not null default auth.uid() references public.gameon_profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  seen boolean not null default false,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
create unique index if not exists gameon_one_pending_request on public.gameon_join_requests(community_id, team_id) where status = 'pending';
create index if not exists gameon_request_captain on public.gameon_join_requests(captain_id);
create index if not exists gameon_request_status on public.gameon_join_requests(status, created_at desc);
create table if not exists public.gameon_memberships (
  community_id uuid not null references public.gameon_communities(id) on delete cascade,
  team_id uuid not null references public.gameon_teams(id) on delete cascade,
  approved_by uuid not null references auth.users(id),
  joined_at timestamptz not null default now(),
  primary key (community_id, team_id)
);
create index if not exists gameon_membership_team on public.gameon_memberships(team_id);

alter table public.gameon_profiles enable row level security;
alter table public.gameon_admins enable row level security;
alter table public.gameon_teams enable row level security;
alter table public.gameon_communities enable row level security;
alter table public.gameon_join_requests enable row level security;
alter table public.gameon_memberships enable row level security;

revoke all on public.gameon_profiles, public.gameon_admins, public.gameon_teams,
  public.gameon_communities, public.gameon_join_requests, public.gameon_memberships from anon, authenticated;
grant select, insert on public.gameon_profiles to authenticated;
-- Phone is set by a trusted auth handler; it cannot be changed with a profile edit.
grant update (name, email, role, completed) on public.gameon_profiles to authenticated;
grant select, insert on public.gameon_teams to authenticated;
grant update (name, has_ground, ground_name, ground_area, amenities) on public.gameon_teams to authenticated;
grant select, insert on public.gameon_communities to authenticated;
grant select on public.gameon_join_requests, public.gameon_memberships to authenticated;
grant insert (community_id, team_id, captain_id) on public.gameon_join_requests to authenticated;
grant delete on public.gameon_memberships to authenticated;

drop policy if exists gameon_profile_read on public.gameon_profiles;
create policy gameon_profile_read on public.gameon_profiles for select to authenticated using (id = (select auth.uid()) or (select gameon_private.is_admin()));
drop policy if exists gameon_profile_create on public.gameon_profiles;
create policy gameon_profile_create on public.gameon_profiles for insert to authenticated with check (id = (select auth.uid()) and phone is null);
drop policy if exists gameon_profile_update on public.gameon_profiles;
create policy gameon_profile_update on public.gameon_profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
drop policy if exists gameon_team_read on public.gameon_teams;
create policy gameon_team_read on public.gameon_teams for select to authenticated using (captain_id = (select auth.uid()) or (select gameon_private.is_admin()));
drop policy if exists gameon_team_create on public.gameon_teams;
create policy gameon_team_create on public.gameon_teams for insert to authenticated with check (
  captain_id = (select auth.uid()) and exists(select 1 from public.gameon_profiles p where p.id = (select auth.uid()) and p.role = 'Captain' and p.completed)
);
drop policy if exists gameon_team_update on public.gameon_teams;
create policy gameon_team_update on public.gameon_teams for update to authenticated using (captain_id = (select auth.uid())) with check (
  captain_id = (select auth.uid()) and exists(select 1 from public.gameon_profiles p where p.id = (select auth.uid()) and p.role = 'Captain' and p.completed)
);
drop policy if exists gameon_community_read on public.gameon_communities;
create policy gameon_community_read on public.gameon_communities for select to authenticated using (true);
drop policy if exists gameon_community_create on public.gameon_communities;
create policy gameon_community_create on public.gameon_communities for insert to authenticated with check ((select gameon_private.is_admin()) and created_by = (select auth.uid()));
drop policy if exists gameon_request_read on public.gameon_join_requests;
create policy gameon_request_read on public.gameon_join_requests for select to authenticated using (captain_id = (select auth.uid()) or (select gameon_private.is_admin()));
drop policy if exists gameon_request_create on public.gameon_join_requests;
create policy gameon_request_create on public.gameon_join_requests for insert to authenticated with check (
  captain_id = (select auth.uid()) and status = 'pending' and not seen and reviewed_at is null and reviewed_by is null
  and exists(select 1 from public.gameon_teams t join public.gameon_profiles p on p.id = t.captain_id where t.id = team_id and t.captain_id = (select auth.uid()) and p.role = 'Captain' and p.completed)
  and not exists(select 1 from public.gameon_memberships m where m.team_id = gameon_join_requests.team_id and m.community_id = gameon_join_requests.community_id)
);
drop policy if exists gameon_membership_read on public.gameon_memberships;
create policy gameon_membership_read on public.gameon_memberships for select to authenticated using (
  (select gameon_private.is_admin()) or exists(select 1 from public.gameon_teams t where t.id = team_id and t.captain_id = (select auth.uid()))
);
drop policy if exists gameon_membership_leave on public.gameon_memberships;
create policy gameon_membership_leave on public.gameon_memberships for delete to authenticated using (
  exists(select 1 from public.gameon_teams t where t.id = team_id and t.captain_id = (select auth.uid()))
);

-- Approval and membership activation happen in one locked transaction.
create or replace function public.gameon_review_request(request_id uuid, decision text) returns void
language plpgsql security definer set search_path = '' as $$
declare req public.gameon_join_requests%rowtype;
begin
  if auth.uid() is null or not gameon_private.is_admin() then raise exception 'Superadmin access required'; end if;
  if decision not in ('approved', 'rejected') or decision is null then raise exception 'Invalid decision'; end if;
  select * into req from public.gameon_join_requests where id = request_id for update;
  if not found then raise exception 'Request unavailable'; end if;
  if req.status <> 'pending' then return; end if;
  if decision = 'approved' then
    perform 1 from public.gameon_teams t join public.gameon_profiles p on p.id = t.captain_id
      where t.id = req.team_id and t.captain_id = req.captain_id and p.role = 'Captain' and p.completed
      for update of t, p;
    if not found then raise exception 'Captain or team is no longer eligible'; end if;
    insert into public.gameon_memberships(community_id, team_id, approved_by)
      values(req.community_id, req.team_id, auth.uid()) on conflict do nothing;
  end if;
  update public.gameon_join_requests set status = decision, seen = true, reviewed_at = now(), reviewed_by = auth.uid() where id = request_id;
end;
$$;
revoke all on function public.gameon_review_request(uuid, text) from public, anon;
grant execute on function public.gameon_review_request(uuid, text) to authenticated;

create or replace function public.gameon_mark_requests_seen(community_filter uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not gameon_private.is_admin() then raise exception 'Superadmin access required'; end if;
  update public.gameon_join_requests set seen = true where status = 'pending' and not seen and (community_filter is null or community_id = community_filter);
end;
$$;
revoke all on function public.gameon_mark_requests_seen(uuid) from public, anon;
grant execute on function public.gameon_mark_requests_seen(uuid) to authenticated;

-- Publish only the tables needed for admission changes. RLS filters delivery.
do $$
declare tab text;
begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach tab in array array['gameon_communities', 'gameon_join_requests', 'gameon_memberships'] loop
      if not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = tab) then
        execute format('alter publication supabase_realtime add table public.%I', tab);
      end if;
    end loop;
  end if;
end;
$$;
-- The editor should display six rows, with row_security = true for each table.
select c.relname as table_name, c.relrowsecurity as row_security
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in (
  'gameon_profiles', 'gameon_admins', 'gameon_teams',
  'gameon_communities', 'gameon_join_requests', 'gameon_memberships'
)
order by c.relname;
commit;
