begin;
create table if not exists public.gameon_team_polls (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references public.gameon_teams(id) on delete cascade,
 created_by uuid not null references public.gameon_profiles(id),
 title text not null check(char_length(title) between 3 and 120),
 match_date date not null,
 closes_at timestamptz not null,
 created_at timestamptz not null default now()
);
create index if not exists gameon_team_polls_team_idx on public.gameon_team_polls(team_id, created_at desc);
create table if not exists public.gameon_team_poll_votes (
 poll_id uuid not null references public.gameon_team_polls(id) on delete cascade,
 player_id uuid not null references public.gameon_profiles(id) on delete cascade,
 answer text not null check(answer in ('yes','no')),
 updated_at timestamptz not null default now(),
 primary key(poll_id, player_id)
);
alter table public.gameon_team_polls enable row level security;
alter table public.gameon_team_poll_votes enable row level security;
revoke all on public.gameon_team_polls, public.gameon_team_poll_votes from public, anon, authenticated;
grant all on public.gameon_team_polls, public.gameon_team_poll_votes to service_role;
create or replace function public.gameon_team_poll_action(actor uuid, payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare target public.gameon_teams; poll public.gameon_team_polls; day date; manager boolean; member boolean; result jsonb;
begin
 select * into target from public.gameon_teams where id = (payload->>'teamId')::uuid;
 if not found then raise exception 'Team not found.'; end if;
 manager := target.captain_id = actor or exists(select 1 from public.gameon_admins where user_id = actor);
 member := target.captain_id = actor or exists(select 1 from public.gameon_team_players where team_id = target.id and player_id = actor);
 if not manager and not member then raise exception 'Only this team can access its polls.'; end if;
 if payload->>'operation' = 'create' then
   if not manager then raise exception 'Only an admin or team captain can create polls.'; end if;
   day := (payload->>'matchDate')::date;
   if day is null or day < (clock_timestamp() at time zone 'Asia/Kolkata')::date or day > (clock_timestamp() at time zone 'Asia/Kolkata')::date + 366 then raise exception 'Choose a match date within the next year.'; end if;
   if payload->>'title' is null or char_length(btrim(payload->>'title')) not between 3 and 120 then raise exception 'Enter a poll title.'; end if;
   insert into public.gameon_team_polls(team_id,created_by,title,match_date,closes_at)
   values(target.id,actor,btrim(payload->>'title'),day,(day + 1)::timestamp at time zone 'Asia/Kolkata');
 elsif payload->>'operation' = 'vote' then
   if not member then raise exception 'Only squad members can respond.'; end if;
   select * into poll from public.gameon_team_polls where id = (payload->>'pollId')::uuid and team_id = target.id for update;
   if not found then raise exception 'Poll not found.'; end if;
   if clock_timestamp() >= poll.closes_at then raise exception 'This poll has closed.'; end if;
   if payload->>'answer' is null or payload->>'answer' not in ('yes','no') then raise exception 'Choose Yes or No.'; end if;
   insert into public.gameon_team_poll_votes(poll_id,player_id,answer) values(poll.id,actor,payload->>'answer')
   on conflict(poll_id,player_id) do update set answer = excluded.answer, updated_at = clock_timestamp();
 elsif payload->>'operation' <> 'list' or payload->>'operation' is null then
   raise exception 'Unknown poll action.';
 end if;
 select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb) into result from (
   select p.created_at, jsonb_build_object('id',p.id,'title',p.title,'matchDate',p.match_date,'closesAt',p.closes_at,
     'closed',clock_timestamp() >= p.closes_at,'canManage',manager,'canVote',member,
     'responses',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'answer',v.answer) order by r.name)
       from public.gameon_profiles r left join public.gameon_team_poll_votes v on v.player_id = r.id and v.poll_id = p.id
       where r.id = target.captain_id or exists(select 1 from public.gameon_team_players tp where tp.team_id = target.id and tp.player_id = r.id)), '[]'::jsonb)) item
   from public.gameon_team_polls p where p.team_id = target.id order by p.created_at desc limit 50
 ) rows;
 return result;
end;
$$;
revoke all on function public.gameon_team_poll_action(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.gameon_team_poll_action(uuid,jsonb) to service_role;
commit;
