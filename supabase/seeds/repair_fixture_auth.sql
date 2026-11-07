-- Repairs ONLY this script's marked test accounts. No teams or players are recreated.
begin;
do $$
declare
  auth_instance uuid;
  token_column text;
begin
  select u.instance_id into auth_instance from auth.users u
    where u.instance_id is not null
      and u.raw_user_meta_data->>'gameon_seed' is distinct from 'nurtur-testing-v1'
    order by u.created_at limit 1;
  auth_instance := coalesce(auth_instance, '00000000-0000-0000-0000-000000000000'::uuid);
  update auth.users set instance_id = auth_instance,
    aud = 'authenticated', role = 'authenticated',
    encrypted_password = coalesce(encrypted_password, ''), updated_at = now()
    where raw_user_meta_data->>'gameon_seed' = 'nurtur-testing-v1';
  -- GoTrue versions expect empty strings, rather than SQL NULL, for these token fields.
  foreach token_column in array array['confirmation_token','recovery_token','email_change_token_new',
    'email_change','email_change_token_current','reauthentication_token'] loop
    if exists(select 1 from information_schema.columns c where c.table_schema = 'auth'
      and c.table_name = 'users' and c.column_name = token_column) then
      execute format('update auth.users set %I = coalesce(%I, '''') where raw_user_meta_data->>''gameon_seed'' = ''nurtur-testing-v1''', token_column, token_column);
    end if;
  end loop;
end;
$$;
select count(*) as repaired_fixture_accounts from auth.users
where raw_user_meta_data->>'gameon_seed' = 'nurtur-testing-v1';
commit;
