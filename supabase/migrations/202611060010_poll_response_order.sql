begin;
-- Preserve first response time when a player changes Yes/No later.
alter table public.gameon_team_poll_votes add column if not exists voted_at timestamptz;
-- Previous votes only recorded their latest update; retain the best available timestamp.
update public.gameon_team_poll_votes set voted_at = updated_at where voted_at is null;
alter table public.gameon_team_poll_votes alter column voted_at set default now();
alter table public.gameon_team_poll_votes alter column voted_at set not null;
commit;
