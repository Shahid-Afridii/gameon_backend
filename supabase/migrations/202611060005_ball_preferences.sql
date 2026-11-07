begin;
alter table public.gameon_profiles add column if not exists ball_type text
  check (ball_type in ('Stitch ball', 'Tennis ball', 'Cork ball', 'Soft tennis ball'));
create or replace function public.gameon_save_cricket_profile(display_name text, contact_email text,
  account_role text, selected_team text, cricket_specialty text, shirt_number integer, preferred_ball text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if preferred_ball is not null and preferred_ball not in ('Stitch ball', 'Tennis ball', 'Cork ball', 'Soft tennis ball') then
    raise exception 'Choose a valid ball type';
  end if;
  perform public.gameon_save_player_profile(display_name, contact_email, account_role, selected_team, cricket_specialty, shirt_number);
  update public.gameon_profiles set ball_type = preferred_ball where id = auth.uid();
end;
$$;
revoke all on function public.gameon_save_cricket_profile(text,text,text,text,text,integer,text) from public, anon;
grant execute on function public.gameon_save_cricket_profile(text,text,text,text,text,integer,text) to authenticated;
commit;
