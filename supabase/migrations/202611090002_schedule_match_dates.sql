begin;

create or replace function public.gameon_schedule_match(actor uuid, payload jsonb)
returns void language plpgsql set search_path = public as $$
declare
  slots jsonb := payload->'plan'->'schedule';
  slot jsonb;
  start_time timestamptz;
  previous_start timestamptz := now();
  guest_email text := nullif(btrim(payload->'plan'->>'guestEmail'), '');
  own_team_id uuid;
begin
  if jsonb_typeof(slots) is distinct from 'array' or
     jsonb_typeof(payload->'plan'->'overs') is distinct from 'array' then
    raise exception 'Pick a date and time for every match.';
  end if;
  if jsonb_array_length(slots) <> jsonb_array_length(payload->'plan'->'overs') then
    raise exception 'Pick a date and time for every match.';
  end if;
  for slot in select value from jsonb_array_elements(slots) loop
    if coalesce(slot->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or
       coalesce(slot->>'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'Pick a valid date and time for each match.';
    end if;
    start_time := ((slot->>'date')::date + (slot->>'time')::time) at time zone 'Asia/Kolkata';
    if start_time <= previous_start then
      raise exception 'Match times must be in the future and in order.';
    end if;
    previous_start := start_time;
  end loop;

  if guest_email is not null and (char_length(guest_email) > 254 or guest_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
    raise exception 'Enter a valid guest email.';
  end if;

  -- Keep the availability, captain, venue and pending-pair checks in the existing operation.
  perform public.gameon_match_action(actor, 'request_with_plan', payload);
  select id into strict own_team_id from public.gameon_teams where captain_id = actor;
  update public.gameon_match_requests
  set plan = plan || jsonb_strip_nulls(jsonb_build_object('schedule', slots, 'guestEmail', guest_email))
  where community_id = (payload->>'communityId')::uuid
    and from_team_id = own_team_id and to_team_id = (payload->>'teamId')::uuid and status = 'pending';
  if not found then
    raise exception 'The challenge schedule could not be saved.';
  end if;
end;
$$;

revoke all on function public.gameon_schedule_match(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.gameon_schedule_match(uuid, jsonb) to service_role;

commit;
