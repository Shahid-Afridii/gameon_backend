begin;
alter table public.gameon_profiles add column if not exists jersey_number integer check (jersey_number between 0 and 99);
create or replace function public.gameon_save_player_profile(display_name text, contact_email text,
  account_role text, selected_team text, cricket_specialty text, shirt_number integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if shirt_number is not null and shirt_number not between 0 and 99 then raise exception 'Choose a jersey number from 0 to 99'; end if;
  perform public.gameon_save_profile_details(display_name, contact_email, account_role, selected_team, cricket_specialty);
  update public.gameon_profiles set jersey_number = shirt_number where id = auth.uid();
end;
$$;
revoke all on function public.gameon_save_player_profile(text,text,text,text,text,integer) from public, anon;
grant execute on function public.gameon_save_player_profile(text,text,text,text,text,integer) to authenticated;
commit;
