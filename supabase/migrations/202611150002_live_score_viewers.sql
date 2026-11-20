-- Live scoreboard viewer presence. Safe to run more than once.
begin;

create table if not exists public.gameon_score_viewers (
  request_id uuid not null references public.gameon_match_requests(id) on delete cascade,
  match_index integer not null check (match_index between 0 and 4),
  user_id uuid not null references auth.users(id) on delete cascade,
  last_active_at timestamptz not null,
  primary key (request_id, match_index, user_id)
);

create index if not exists gameon_score_viewers_active_idx
  on public.gameon_score_viewers(request_id, match_index, last_active_at desc);

alter table public.gameon_score_viewers enable row level security;
revoke all on public.gameon_score_viewers from public, anon, authenticated;
grant all on public.gameon_score_viewers to service_role;

create or replace function public.gameon_touch_score_viewer(
  actor uuid, fixture_id uuid, slot_index integer
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  active_viewers integer;
begin
  insert into public.gameon_score_viewers(request_id, match_index, user_id, last_active_at)
  select fixture_id, slot_index, profile.id, clock_timestamp()
  from public.gameon_profiles profile
  where profile.id = actor and profile.completed
  on conflict (request_id, match_index, user_id) do update
    set last_active_at = excluded.last_active_at;

  select count(*)::integer
  into active_viewers
  from public.gameon_score_viewers viewer
  where viewer.request_id = fixture_id
    and viewer.match_index = slot_index
    and viewer.last_active_at >= clock_timestamp() - interval '20 seconds';

  return active_viewers;
end;
$$;

revoke all on function public.gameon_touch_score_viewer(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.gameon_touch_score_viewer(uuid, uuid, integer)
  to service_role;

commit;
