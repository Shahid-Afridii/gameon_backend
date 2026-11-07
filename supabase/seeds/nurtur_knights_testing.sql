-- If needed, run ONLY this lookup first to see both team UUIDs and their captains:
-- select t.id, t.name, p.name as captain, p.phone from public.gameon_teams t
-- join public.gameon_profiles p on p.id = t.captain_id
-- where regexp_replace(lower(t.name), '[^a-z0-9]', '', 'g') = 'nurturknights';
-- TEST DATA ONLY. Run the entire file in the Supabase SQL Editor.
-- Requires all GameOn migrations through 202611060008.
-- Existing accounts/names/admin permissions are preserved. No notifications are sent.
-- After this SQL, run npm run seed:test-logins in backend to enable env-based static-code login.
-- No phone numbers are verified, and no SMS is sent.
begin;

create or replace function pg_temp.gameon_seed_person(
  seed_key text, display_name text, specialty text, shirt integer, account_role text default 'Player'
) returns uuid language plpgsql as $$
declare
  person_id uuid := md5('gameon-testing-v1:' || seed_key)::uuid;
  dummy_phone text;
  seed_email text := seed_key || '@seed.gameon.invalid';
  seed_tag text;
begin
  select raw_user_meta_data->>'gameon_seed' into seed_tag from auth.users where id = person_id;
  if found and seed_tag is distinct from 'nurtur-testing-v1' then
    raise exception 'Fixture identity collision for %. No changes committed.', seed_key;
  end if;
  select phone into dummy_phone from public.gameon_profiles where id = person_id;
  if dummy_phone is null then
    -- These dummy numbers are never sent to SMS/push and do not enable test login.
    loop
      dummy_phone := '999' || lpad(floor(random() * 10000000)::bigint::text, 7, '0');
      exit when not exists(select 1 from public.gameon_profiles where phone = dummy_phone);
    end loop;
  end if;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, reauthentication_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values(coalesce((select u.instance_id from auth.users u where u.instance_id is not null order by u.created_at limit 1), '00000000-0000-0000-0000-000000000000'::uuid), person_id, 'authenticated', 'authenticated', seed_email, '', '', '', '', '', '', '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('gameon_seed','nurtur-testing-v1','gameon_seed_key',seed_key,'name',display_name), now(), now())
  on conflict(id) do nothing;
  insert into auth.identities(id, provider_id, user_id, identity_data, provider, created_at, updated_at)
  values(md5('gameon-seed-identity:' || seed_key)::uuid, person_id::text, person_id,
    jsonb_build_object('sub',person_id::text,'email',seed_email,'email_verified',false,'phone_verified',false), 'email', now(), now())
  on conflict(provider_id, provider) do nothing;
  insert into public.gameon_profiles(id, name, phone, role, completed, cricket_role, jersey_number, ball_type, ball_types)
  values(person_id, display_name, dummy_phone, account_role, true, specialty, shirt, 'Stitch ball', array['Stitch ball','Tennis ball'])
  on conflict(id) do update set name = excluded.name, role = excluded.role, completed = true,
    cricket_role = excluded.cricket_role, jersey_number = excluded.jersey_number,
    ball_type = excluded.ball_type, ball_types = excluded.ball_types;
  return person_id;
end;
$$;

-- Prevent two executions of this seed from racing against each other.
select pg_advisory_xact_lock(hashtext('gameon-nurtur-testing-v1'));


do $$
declare
  -- Set this only if several existing teams have the exact name Nurtur Knights.
  target_team_id uuid := null;
  target public.gameon_teams;
  matches integer;
  person uuid;
  captain uuid;
  test_team uuid;
  current_size integer;
  seeded_team_ids uuid[];
  fixture record;
  config record;
  item jsonb;
  player_index integer;
  specialties text[] := array['Batsman','Bowler','All-rounder','Wicketkeeper-batsman'];
begin
  if target_team_id is null then
    select count(*) into matches from public.gameon_teams
      where regexp_replace(lower(name), '[^a-z0-9]', '', 'g') = 'nurturknights';
    if matches = 0 then raise exception 'Nurtur Knights was not found.'; end if;
    -- Prefer the team containing the supplied existing accounts; captain name breaks ties.
    with candidates as (
      select t.id,
        (select count(*) from public.gameon_profiles p
          where p.phone in ('9000000000','9092745806','8056585587')
          and (p.id = t.captain_id or exists(select 1 from public.gameon_team_players m where m.team_id = t.id and m.player_id = p.id))) as known_members,
        exists(select 1 from public.gameon_profiles p where p.id = t.captain_id and lower(btrim(p.name)) = 'andrews solomon') as named_captain
      from public.gameon_teams t where regexp_replace(lower(t.name), '[^a-z0-9]', '', 'g') = 'nurturknights'
    ), ranked as (
      select *, dense_rank() over(order by known_members desc, named_captain desc) as priority from candidates
    ) select count(*), (array_agg(id))[1] into matches, target_team_id from ranked where priority = 1;
    if matches <> 1 then
      raise exception 'Matching teams are still tied. Run the lookup SELECT at the top of this file and set target_team_id to the intended UUID.';
    end if;
    select * into target from public.gameon_teams where id = target_team_id;
  else
    select * into target from public.gameon_teams where id = target_team_id;
    if not found then raise exception 'Target team UUID not found.'; end if;
  end if;
  if not exists(select 1 from public.gameon_memberships where team_id = target.id) then
    raise exception 'Nurtur Knights has no approved community membership. Join its intended community first, then rerun.';
  end if;

  -- Existing test accounts: keep their names, roles, numbers and admin permissions.
  for fixture in select unnest(array['9000000000','9092745806','8056585587']) as phone loop
    select id into person from public.gameon_profiles where phone = fixture.phone;
    if not found then raise exception 'Existing test account % was not found; no data has been committed.', fixture.phone; end if;
    if person <> target.captain_id then
      insert into public.gameon_team_players(team_id, player_id) values(target.id, person)
      on conflict do nothing;
    end if;
  end loop;

  -- Reuse named members already in THIS roster (including its captain).
  -- Same-name users outside this team are not silently reassigned.
  for fixture in select * from (values
    ('yogesh', 'Yogesh', 'Bowler', 12),
    ('praveen-kumar', 'Praveen Kumar', 'Wicketkeeper-batsman', 17),
    ('suraj', 'Suraj', 'Batsman', 18),
    ('sridhar', 'Sridhar', 'Batsman', 24),
    ('andrews-solomon', 'Andrews Solomon', 'All-rounder', 7),
    ('srinath', 'Srinath', 'All-rounder', 33),
    ('arun', 'Arun', 'All-rounder', 45),
    ('karthick-raja', 'Karthick Raja', 'Batsman', 10)
  ) as names(seed_key, display_name, specialty, shirt) loop
    select count(*) into matches from public.gameon_profiles p
      where lower(btrim(p.name)) = lower(fixture.display_name)
      and (p.id = target.captain_id or exists(select 1 from public.gameon_team_players m where m.team_id = target.id and m.player_id = p.id));
    if matches > 1 then raise exception 'Several % profiles exist in Nurtur Knights. Resolve that name before seeding.', fixture.display_name; end if;
    if matches = 1 then
      select p.id into person from public.gameon_profiles p
        where lower(btrim(p.name)) = lower(fixture.display_name)
        and (p.id = target.captain_id or exists(select 1 from public.gameon_team_players m where m.team_id = target.id and m.player_id = p.id));
      -- Only the requested cricket specialty changes on existing named accounts.
      update public.gameon_profiles set cricket_role = fixture.specialty where id = person;
    else
      person := pg_temp.gameon_seed_person('nurtur-' || fixture.seed_key, fixture.display_name, fixture.specialty, fixture.shirt);
    end if;
    if person <> target.captain_id then
      insert into public.gameon_team_players(team_id, player_id) values(target.id, person) on conflict do nothing;
    end if;
  end loop;

  -- Top up to 13 total members if needed; never remove existing members.
  for fixture in select * from (values
    ('vignesh','Vignesh','Bowler',21), ('balaji','Balaji','All-rounder',28),
    ('hari-prasath','Hari Prasath','Batsman',36), ('sathish','Sathish','Bowler',41),
    ('naveen','Naveen','Wicketkeeper-batsman',55), ('manoj','Manoj','Batsman',63),
    ('ganesh','Ganesh','Bowler',72), ('ashwin','Ashwin','All-rounder',88),
    ('saran','Saran','Batsman',91), ('siva','Siva','Bowler',97)
  ) as names(seed_key, display_name, specialty, shirt) loop
    select 1 + count(*) into current_size from public.gameon_team_players where team_id = target.id and player_id <> target.captain_id;
    exit when current_size >= 13;
    person := pg_temp.gameon_seed_person('nurtur-extra-' || fixture.seed_key, fixture.display_name, fixture.specialty, fixture.shirt);
    insert into public.gameon_team_players(team_id, player_id) values(target.id, person) on conflict do nothing;
  end loop;
  seeded_team_ids := array[target.id];
  perform set_config('gameon.seed_target_team', target.id::text, true);

  -- Two new teams: 13 and 12 TOTAL members, including each captain.
  for config in select * from (values
    ('falcons', 'Kovai Falcons (Test)', 'Weekend cricket squad for testing team and match flows.', true,
      '["Adithya Raman","Rahul Menon","Vijay Kumar","Naveen Raj","Kishore Anand","Dinesh Prabhu","Sanjay Kumar","Aravind Mani","Madhan Raj","Rohit Nair","Bharath Kumar","Prasanna Dev","Gokul Raj"]'::jsonb),
    ('titans', 'Coimbatore Titans (Test)', 'Practice squad for testing invitations, rosters and match requests.', false,
      '["Vikram Anand","Kavin Raj","Ajay Kumar","Suresh Babu","Deepan Raj","Ramesh Kumar","Pradeep Nair","Nithin Das","Harish Mani","Senthil Raj","Varun Dev","Arjun Kumar"]'::jsonb)
  ) as teams(seed_key, team_name, description, owns_ground, players) loop
    captain := pg_temp.gameon_seed_person(config.seed_key || '-captain', config.players->>0, 'All-rounder', 7, 'Captain');
    select id into test_team from public.gameon_teams where captain_id = captain;
    if test_team is null then
      insert into public.gameon_teams(captain_id, name, description, has_ground, ground_name, ground_area, amenities, match_available)
      values(captain, config.team_name, config.description, config.owns_ground,
        case when config.owns_ground then 'Falcons Practice Ground' else '' end,
        case when config.owns_ground then 'Coimbatore' else '' end,
        case when config.owns_ground then array['Parking','Drinking water','Practice nets'] else array[]::text[] end, true)
      returning id into test_team;
    end if;
    player_index := 0;
    for item in select value from jsonb_array_elements(config.players) loop
      if player_index > 0 then
        person := pg_temp.gameon_seed_person(config.seed_key || '-player-' || player_index,
          item #>> '{}', specialties[1 + ((player_index - 1) % 4)], 10 + player_index);
        insert into public.gameon_team_players(team_id, player_id) values(test_team, person) on conflict do nothing;
      end if;
      player_index := player_index + 1;
    end loop;
    insert into public.gameon_memberships(community_id, team_id, approved_by)
      select community_id, test_team, approved_by from public.gameon_memberships where team_id = target.id
      on conflict do nothing;
    seeded_team_ids := array_append(seeded_team_ids, test_team);
  end loop;

  -- Existing pending player requests now represented by seeded memberships are accepted.
  update public.gameon_team_player_requests r set status = 'accepted', reviewed_at = now()
    where r.status = 'pending' and r.team_id = any(seeded_team_ids)
    and exists(select 1 from public.gameon_team_players m where m.team_id = r.team_id and m.player_id = r.player_id);
end;
$$;

-- Result 1: teams, real roster counts (captain included), and communities.
select t.name as team, 1 + (select count(*) from public.gameon_team_players p where p.team_id = t.id and p.player_id <> t.captain_id) as total_members,
  (select string_agg(c.name, ', ' order by c.name) from public.gameon_memberships m join public.gameon_communities c on c.id = m.community_id where m.team_id = t.id) as communities
from (select id as team_id from public.gameon_teams
  where id = nullif(current_setting('gameon.seed_target_team', true), '')::uuid
  or captain_id in (md5('gameon-testing-v1:falcons-captain')::uuid, md5('gameon-testing-v1:titans-captain')::uuid)) r join public.gameon_teams t on t.id = r.team_id order by t.name;

-- Result 2: each player, specialty, jersey number and dummy/existing phone.
select t.name as team, p.name, case when p.id = t.captain_id then 'Captain' else 'Player' end as team_role,
  p.cricket_role, p.jersey_number, p.phone
from (select id as team_id from public.gameon_teams
  where id = nullif(current_setting('gameon.seed_target_team', true), '')::uuid
  or captain_id in (md5('gameon-testing-v1:falcons-captain')::uuid, md5('gameon-testing-v1:titans-captain')::uuid)) r join public.gameon_teams t on t.id = r.team_id
join public.gameon_profiles p on p.id = t.captain_id or exists(select 1 from public.gameon_team_players m where m.team_id = t.id and m.player_id = p.id)
order by t.name, (p.id = t.captain_id) desc, p.name;
commit;
