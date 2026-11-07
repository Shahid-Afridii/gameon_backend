-- Run AFTER both foundation migrations. No changes to existing identities.
begin;
create or replace function gameon_private.sync_verified_phone()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.phone_confirmed_at is not null and new.phone ~ '^\+?91[6-9][0-9]{9}$' then
    update public.gameon_profiles set phone = right(new.phone, 10) where id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function gameon_private.sync_verified_phone() from public, anon, authenticated;
drop trigger if exists gameon_sync_verified_phone on auth.users;
create trigger gameon_sync_verified_phone after update of phone, phone_confirmed_at on auth.users
for each row execute function gameon_private.sync_verified_phone();
-- Team upsert uses a transaction instead of broadening column grants for clients.
create or replace function public.gameon_save_team(team_name text, owns_ground boolean,
  venue_name text, venue_area text, venue_amenities text[])
returns void language plpgsql security definer set search_path = '' as $$
declare profile public.gameon_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into profile from public.gameon_profiles where id = auth.uid() for update;
  if not found or profile.role <> 'Captain' or not profile.completed then
    raise exception 'Complete your captain profile first';
  end if;
  if team_name is null or char_length(btrim(team_name)) not between 2 and 60 or owns_ground is null then
    raise exception 'Invalid team';
  end if;
  if owns_ground and (venue_name is null or char_length(btrim(venue_name)) not between 3 and 100
    or venue_area is null or char_length(btrim(venue_area)) not between 1 and 250) then
    raise exception 'Invalid ground';
  end if;
  if venue_amenities is null or cardinality(venue_amenities) > 20
    or exists(select 1 from unnest(venue_amenities) a where a is null or char_length(btrim(a)) not between 1 and 60) then
    raise exception 'Invalid amenities';
  end if;
  insert into public.gameon_teams(captain_id, name, has_ground, ground_name, ground_area, amenities)
  values(auth.uid(), btrim(team_name), owns_ground, case when owns_ground then btrim(venue_name) else '' end,
    case when owns_ground then btrim(venue_area) else '' end, venue_amenities)
  on conflict(captain_id) do update set name = excluded.name, has_ground = excluded.has_ground,
    ground_name = excluded.ground_name, ground_area = excluded.ground_area, amenities = excluded.amenities;
end;
$$;
revoke all on function public.gameon_save_team(text, boolean, text, text, text[]) from public, anon;
grant execute on function public.gameon_save_team(text, boolean, text, text, text[]) to authenticated;
commit;
