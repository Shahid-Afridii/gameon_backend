begin;
create table if not exists public.gameon_push_tokens (
  token text primary key check (char_length(token) between 20 and 300),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists gameon_push_tokens_user_id_idx on public.gameon_push_tokens(user_id);
alter table public.gameon_push_tokens enable row level security;
revoke all on public.gameon_push_tokens from public, anon, authenticated;
grant select, insert, update, delete on public.gameon_push_tokens to service_role;
commit;
