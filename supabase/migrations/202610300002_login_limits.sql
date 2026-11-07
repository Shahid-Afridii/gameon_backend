-- Run after the foundation migration. Required by the test-login Edge Function.
begin;
create table if not exists gameon_private.login_limits (
  key text primary key,
  started_at timestamptz not null default now(),
  attempts integer not null default 1
);
revoke all on gameon_private.login_limits from public, anon, authenticated;
create or replace function public.gameon_consume_login_attempt(bucket text, max_attempts integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare attempts_used integer;
begin
  if bucket is null or char_length(bucket) > 150 or max_attempts not between 1 and 100 then return false; end if;
  delete from gameon_private.login_limits where started_at < now() - interval '1 day';
  insert into gameon_private.login_limits as limits(key) values(bucket)
  on conflict(key) do update set
    attempts = case when limits.started_at < now() - interval '10 minutes' then 1 else limits.attempts + 1 end,
    started_at = case when limits.started_at < now() - interval '10 minutes' then now() else limits.started_at end
  returning attempts into attempts_used;
  return attempts_used <= max_attempts;
end;
$$;
revoke all on function public.gameon_consume_login_attempt(text, integer) from public, anon, authenticated;
grant execute on function public.gameon_consume_login_attempt(text, integer) to service_role;
alter table public.gameon_profiles add column if not exists team_name text not null default '';


-- Profile and optional team are updated atomically.
create or replace function public.gameon_save_profile(display_name text, contact_email text, playing_role text, selected_team text)
returns void language plpgsql security definer set search_path = '' as $$
declare own_team public.gameon_teams%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if char_length(btrim(display_name)) not between 2 and 60 or display_name is null then raise exception 'Invalid name'; end if;
  if playing_role not in ('Player', 'Captain') or playing_role is null then raise exception 'Invalid role'; end if;
  if contact_email is not null and (char_length(contact_email) > 254 or contact_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'Invalid email'; end if;
  selected_team := btrim(coalesce(selected_team, ''));
  if char_length(selected_team) > 60 or (selected_team <> '' and char_length(selected_team) < 2) then raise exception 'Invalid team name'; end if;
  perform 1 from public.gameon_profiles where id = auth.uid() for update;
  if not found then raise exception 'Profile not found'; end if;
  select * into own_team from public.gameon_teams where captain_id = auth.uid() for update;
  if own_team.id is not null and exists(select 1 from public.gameon_memberships where team_id = own_team.id)
    and (playing_role <> 'Captain' or selected_team = '') then raise exception 'Leave communities before removing captain role or team'; end if;
  if playing_role = 'Player' and selected_team <> '' and not exists(select 1 from public.gameon_teams where name = selected_team) then raise exception 'Choose an existing team'; end if;
  update public.gameon_profiles set name = btrim(display_name), email = contact_email, role = playing_role, completed = true,
    team_name = case when playing_role = 'Player' then selected_team else '' end where id = auth.uid();
  if playing_role = 'Captain' and selected_team <> '' then
    insert into public.gameon_teams(captain_id, name) values(auth.uid(), selected_team)
      on conflict(captain_id) do update set name = excluded.name;
  elsif own_team.id is not null then
    delete from public.gameon_teams where id = own_team.id;
  end if;
end;
$$;
revoke all on function public.gameon_save_profile(text, text, text, text) from public, anon;
grant execute on function public.gameon_save_profile(text, text, text, text) to authenticated;
-- Updates are routed through the validated transaction instead of arbitrary profile patches.
revoke update (name, email, role, completed) on public.gameon_profiles from authenticated;
grant all on public.gameon_profiles, public.gameon_admins, public.gameon_teams,
  public.gameon_communities, public.gameon_join_requests, public.gameon_memberships to service_role;
commit;
