-- Apply after the existing GameOn migrations through 202611150002.
begin;

-- Saving captain preferences with a blank team field preserves an existing team.
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
    and playing_role <> 'Captain' then raise exception 'Leave communities before removing captain role or team'; end if;
  if playing_role = 'Player' and selected_team <> '' and not exists(select 1 from public.gameon_teams where name = selected_team) then raise exception 'Choose an existing team'; end if;
  update public.gameon_profiles set name = btrim(display_name), email = contact_email, role = playing_role, completed = true,
    team_name = case when playing_role = 'Player' then selected_team else '' end where id = auth.uid();
  if playing_role = 'Captain' and selected_team <> '' then
    insert into public.gameon_teams(captain_id, name) values(auth.uid(), selected_team)
      on conflict(captain_id) do update set name = excluded.name;
  elsif own_team.id is not null and playing_role <> 'Captain' then
    delete from public.gameon_teams where id = own_team.id;
  end if;
end;
$$;

create table if not exists public.gameon_manual_players (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.gameon_teams(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 60),
  cricket_role text check (cricket_role in ('Batsman','Bowler','All-rounder','Wicketkeeper-batsman')),
  jersey_number integer check (jersey_number between 0 and 99),
  invite_phone text check (invite_phone ~ '^[6-9][0-9]{9}$'),
  invite_requested_at timestamptz,
  claimed_player_id uuid references public.gameon_profiles(id) on delete set null,
  linked_player_id uuid references public.gameon_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (team_id, invite_phone),
  unique (team_id, linked_player_id)
);
create unique index if not exists gameon_manual_players_identity_idx
  on public.gameon_manual_players (team_id, lower(btrim(name)), (coalesce(jersey_number, -1)));
create index if not exists gameon_manual_players_phone_idx
  on public.gameon_manual_players (invite_phone) where claimed_player_id is null;
alter table public.gameon_manual_players enable row level security;
revoke all on public.gameon_manual_players from public, anon, authenticated;
grant select, insert, update, delete on public.gameon_manual_players to service_role;

-- A signed-in player claims only invitations for the phone on their own profile.
-- Existing requests use the normal Requests inbox and review flow.
create or replace function public.gameon_claim_manual_invites(actor uuid, only_player uuid default null)
returns void language plpgsql set search_path = '' as $$
declare
  person public.gameon_profiles;
  entry public.gameon_manual_players;
  target uuid;
begin
  select * into person from public.gameon_profiles where id = actor and role = 'Player';
  if not found or exists (select 1 from public.gameon_teams where captain_id = actor) then return; end if;
  for target in
    select distinct team_id from public.gameon_manual_players
    where invite_phone = person.phone and claimed_player_id is null
      and (only_player is null or id = only_player)
    order by team_id
  loop
    -- Match the lock order in gameon_team_player_action.
    perform id from public.gameon_teams where id = target for update;
    select * into entry from public.gameon_manual_players
    where team_id = target and invite_phone = person.phone and claimed_player_id is null
      and (only_player is null or id = only_player) for update;
    if not found then continue; end if;
    if exists (select 1 from public.gameon_team_players where team_id = target and player_id = actor) then
      update public.gameon_manual_players set claimed_player_id = actor, linked_player_id = actor
      where id = entry.id;
    else
      insert into public.gameon_team_player_requests (team_id, player_id, kind)
      values (target, actor, 'invite')
      on conflict (team_id, player_id) where status = 'pending' do nothing;
      update public.gameon_manual_players set claimed_player_id = actor where id = entry.id;
    end if;
  end loop;
end;
$$;

create or replace function public.gameon_invite_manual_player(actor uuid, roster_id uuid, mobile text)
returns void language plpgsql set search_path = '' as $$
declare
  target uuid;
  recipient uuid;
  existing_phone text;
begin
  if mobile is null or mobile !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid mobile number.'; end if;
  select team.id into target
  from public.gameon_manual_players entry
  join public.gameon_teams team on team.id = entry.team_id
  join public.gameon_profiles profile on profile.id = actor and profile.completed and profile.role = 'Captain'
  where entry.id = roster_id and team.captain_id = actor
    and not exists (select 1 from public.gameon_admins where user_id = actor)
  for update of team;
  if not found then raise exception 'Only the team captain can invite this player.' using errcode = '42501'; end if;
  if exists (select 1 from public.gameon_profiles where id = actor and phone = mobile) then
    raise exception 'Use the player’s mobile number.';
  end if;
  select invite_phone into existing_phone from public.gameon_manual_players where id = roster_id for update;
  if existing_phone is not null and existing_phone <> mobile then
    raise exception 'This player already has a phone invitation.';
  end if;
  update public.gameon_manual_players
    set invite_phone = mobile, invite_requested_at = coalesce(invite_requested_at, now())
    where id = roster_id;
  select id into recipient from public.gameon_profiles where phone = mobile and role = 'Player';
  if recipient is not null then perform public.gameon_claim_manual_invites(recipient, roster_id); end if;
end;
$$;

create or replace function public.gameon_link_manual_member()
returns trigger language plpgsql set search_path = '' as $$
begin
  update public.gameon_manual_players entry
    set linked_player_id = new.player_id, claimed_player_id = new.player_id
  from public.gameon_profiles person
  where entry.team_id = new.team_id and person.id = new.player_id
    and (entry.claimed_player_id = person.id or
         (entry.claimed_player_id is null and entry.invite_phone = person.phone))
    and entry.invite_phone = person.phone;
  return new;
end;
$$;
drop trigger if exists gameon_link_manual_member on public.gameon_team_players;
create trigger gameon_link_manual_member after insert on public.gameon_team_players
  for each row execute function public.gameon_link_manual_member();

create index if not exists gameon_match_requests_from_stats_idx on public.gameon_match_requests(from_team_id);
create index if not exists gameon_match_requests_to_stats_idx on public.gameon_match_requests(to_team_id);

create or replace function public.gameon_team_stats(actor uuid, target_team uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  target public.gameon_teams;
  result jsonb;
begin
  select * into target from public.gameon_teams where id = target_team;
  if not found or (target.captain_id <> actor and not exists (
    select 1 from public.gameon_team_players where team_id = target_team and player_id = actor
  )) then raise exception 'Team stats are available to its members.' using errcode = '42501'; end if;

  with completed as materialized (
    select fixture.id as request_id, score.match_index, score.state, opponent.name as opponent,
      coalesce((score.state->'result'->>'recordedAt')::timestamptz,
        (((fixture.plan->'schedule'->score.match_index->>'date') || 'T' ||
          (fixture.plan->'schedule'->score.match_index->>'time') || ':00+05:30'))::timestamptz,
        fixture.reviewed_at, fixture.created_at) as played_at
    from public.gameon_match_requests fixture
    join public.gameon_match_scores score on score.request_id = fixture.id
    left join public.gameon_teams opponent on opponent.id = case
      when fixture.from_team_id = target_team then fixture.to_team_id else fixture.from_team_id end
    where (fixture.from_team_id = target_team or fixture.to_team_id = target_team)
      and public.gameon_score_is_complete(score.state)
  ), figures as (
    select completed.*, side.own_score, side.other_score,
      case
        when state->'result'->>'type' = 'draw' then 'Draw'
        when own_score is null or other_score is null then 'No result'
        when state->'result'->>'type' = 'ended'
          and state->'result'->>'reason' is distinct from 'completed' then 'No result'
        when own_score = other_score then 'Tie'
        when own_score > other_score then 'Won'
        else 'Lost'
      end as outcome
    from completed
    cross join lateral (
      select max((inning->>'runs')::integer) filter (where inning->>'teamId' = target_team::text) own_score,
        max((inning->>'runs')::integer) filter (where inning->>'teamId' <> target_team::text) other_score
      from jsonb_array_elements(completed.state->'innings') as inning
    ) side
  ), aliases as materialized (
    select id::text old_id, linked_player_id::text current_id
    from public.gameon_manual_players where team_id = target_team and linked_player_id is not null
  ), appearances as (
    select coalesce(aliases.current_id, player->>'id') as player_id,
      max(player->>'name') as name, count(distinct (request_id, match_index))::integer as matches
    from completed
    cross join lateral jsonb_array_elements(completed.state->'lineups'->target_team::text) as player
    left join aliases on aliases.old_id = player->>'id'
    group by 1
  ), deliveries as (
    select inning->>'teamId' = target_team::text as own_batting, delivery as ball
    from completed
    cross join lateral jsonb_array_elements(completed.state->'innings') as inning
    cross join lateral jsonb_array_elements(inning->'deliveries') as delivery
  ), contributions as (
    select coalesce(aliases.current_id, stat.player_id) as player_id,
      sum(stat.runs)::integer as runs, sum(stat.wickets)::integer as wickets
    from deliveries
    cross join lateral (values
      (case when own_batting then ball->>'batterId' end, coalesce((ball->>'runs')::integer, 0), 0),
      (case when not own_batting then ball->>'bowlerId' end, 0, case when ball->>'bowlerWicket' = 'true' then 1 else 0 end)
    ) as stat(player_id, runs, wickets)
    left join aliases on aliases.old_id = stat.player_id
    where stat.player_id is not null
    group by 1
  ), people as (
    select profile.id::text player_id, profile.name
    from public.gameon_profiles profile
    where profile.id = target.captain_id or exists (
      select 1 from public.gameon_team_players member where member.team_id = target_team and member.player_id = profile.id
    )
    union all
    select id::text, name from public.gameon_manual_players where team_id = target_team and linked_player_id is null
  )
  select jsonb_build_object(
    'teamId', target_team, 'teamName', target.name,
    'played', (select count(*) from figures),
    'runsFor', coalesce((select sum(own_score) from figures), 0),
    'runsAgainst', coalesce((select sum(other_score) from figures), 0),
    'won', (select count(*) from figures where outcome = 'Won'),
    'lost', (select count(*) from figures where outcome = 'Lost'),
    'tied', (select count(*) from figures where outcome = 'Tie'),
    'drawn', (select count(*) from figures where outcome = 'Draw'),
    'noResult', (select count(*) from figures where outcome = 'No result'),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('requestId', request_id, 'matchIndex', match_index, 'opponent', opponent,
        'outcome', outcome, 'runs', own_score, 'opponentRuns', other_score, 'playedAt', played_at)
        order by played_at desc nulls last, request_id, match_index desc)
      from (select * from figures order by played_at desc nulls last, request_id, match_index desc limit 5) recent
    ), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', player_id, 'name', coalesce(people.name, appearances.name),
        'matches', coalesce(appearances.matches, 0), 'runs', coalesce(contributions.runs, 0),
        'wickets', coalesce(contributions.wickets, 0)) order by coalesce(contributions.runs, 0) desc,
        coalesce(contributions.wickets, 0) desc, coalesce(people.name, appearances.name), player_id)
      from people full join appearances using (player_id)
      left join contributions using (player_id)
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function public.gameon_claim_manual_invites(uuid, uuid),
  public.gameon_invite_manual_player(uuid, uuid, text),
  public.gameon_link_manual_member(), public.gameon_team_stats(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.gameon_claim_manual_invites(uuid, uuid),
  public.gameon_invite_manual_player(uuid, uuid, text), public.gameon_team_stats(uuid, uuid)
  to service_role;
commit;
