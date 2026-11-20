begin;

-- Availability polls currently identify a fixture by team and scheduled date.
create or replace function public.gameon_close_polls_on_match_start()
returns trigger language plpgsql set search_path = '' as $$
begin
  if jsonb_array_length(coalesce(new.state->'innings', '[]'::jsonb)) = 0 then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if jsonb_array_length(coalesce(old.state->'innings', '[]'::jsonb)) > 0 then
      return new;
    end if;
  end if;

  update public.gameon_team_polls poll
  set closes_at = statement_timestamp()
  from public.gameon_match_requests fixture
  where fixture.id = new.request_id
    and poll.team_id in (fixture.from_team_id, fixture.to_team_id)
    and poll.match_date::text = fixture.plan->'schedule'->new.match_index->>'date'
    and poll.closes_at > statement_timestamp();
  return new;
end;
$$;

revoke all on function public.gameon_close_polls_on_match_start() from public, anon, authenticated;

drop trigger if exists gameon_close_polls_on_match_start on public.gameon_match_scores;
create trigger gameon_close_polls_on_match_start
after insert or update of state on public.gameon_match_scores
for each row execute function public.gameon_close_polls_on_match_start();

update public.gameon_team_polls poll
set closes_at = statement_timestamp()
where poll.closes_at > statement_timestamp()
  and exists (
    select 1
    from public.gameon_match_scores score
    join public.gameon_match_requests fixture on fixture.id = score.request_id
    where poll.team_id in (fixture.from_team_id, fixture.to_team_id)
      and poll.match_date::text = fixture.plan->'schedule'->score.match_index->>'date'
      and jsonb_array_length(coalesce(score.state->'innings', '[]'::jsonb)) > 0
  );

commit;
