begin;
-- Also works when the previous single-ball migration was skipped.
alter table public.gameon_profiles add column if not exists ball_type text
  check (ball_type in ('Stitch ball', 'Tennis ball', 'Cork ball', 'Soft tennis ball'));
alter table public.gameon_profiles add column if not exists ball_types text[] not null default '{}'
  check (cardinality(ball_types) <= 4 and ball_types <@ array['Stitch ball','Tennis ball','Cork ball','Soft tennis ball']::text[] and array_position(ball_types, null) is null);
update public.gameon_profiles set ball_types = array[ball_type] where ball_type is not null and cardinality(ball_types) = 0;
create or replace function public.gameon_save_cricket_preferences(display_name text, contact_email text,
  account_role text, selected_team text, cricket_specialty text, shirt_number integer, preferred_balls text[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if preferred_balls is null or cardinality(preferred_balls) > 4 or array_position(preferred_balls, null) is not null
    or not preferred_balls <@ array['Stitch ball','Tennis ball','Cork ball','Soft tennis ball']::text[] then
    raise exception 'Choose valid ball types';
  end if;
  perform public.gameon_save_player_profile(display_name, contact_email, account_role, selected_team, cricket_specialty, shirt_number);
  update public.gameon_profiles set ball_types = preferred_balls, ball_type = preferred_balls[1] where id = auth.uid();
end;
$$;
revoke all on function public.gameon_save_cricket_preferences(text,text,text,text,text,integer,text[]) from public, anon;
grant execute on function public.gameon_save_cricket_preferences(text,text,text,text,text,integer,text[]) to authenticated;
commit;
