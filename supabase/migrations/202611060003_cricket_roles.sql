begin;
alter table public.gameon_profiles add column if not exists cricket_role text
  check (cricket_role in ('Batsman', 'Bowler', 'All-rounder', 'Wicketkeeper-batsman'));
create or replace function public.gameon_save_profile_details(display_name text, contact_email text,
  account_role text, selected_team text, cricket_specialty text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if cricket_specialty is not null and cricket_specialty not in ('Batsman', 'Bowler', 'All-rounder', 'Wicketkeeper-batsman') then
    raise exception 'Choose a valid cricket role';
  end if;
  perform public.gameon_save_profile(display_name, contact_email, account_role, selected_team);
  update public.gameon_profiles set cricket_role = cricket_specialty where id = auth.uid();
end;
$$;
revoke all on function public.gameon_save_profile_details(text,text,text,text,text) from public, anon;
grant execute on function public.gameon_save_profile_details(text,text,text,text,text) to authenticated;
commit;
