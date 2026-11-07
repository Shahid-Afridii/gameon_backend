import { admin } from '../../config/supabase.js';
import { notifyUsers } from '../notifications/push.service.js';
import { check, fail } from '../../lib/errors.js';
export async function teamPoll({ user, body }) {
  const result = await admin.rpc('gameon_team_poll_action', { actor: user.id, payload: body });
  if (result.error?.code === 'P0001') fail(result.error.message, 409);
  const polls = check(result);
  const playerIds = [...new Set(polls.flatMap(poll => poll.responses.map(player => player.id)))];
  if (playerIds.length) {
    // IDs come exclusively from the authorized team poll RPC, never client input.
    const profiles = check(await admin.from('gameon_profiles').select('id,jersey_number').in('id', playerIds));
    const numbers = new Map(profiles.map(profile => [profile.id, profile.jersey_number]));
    for (const poll of polls) for (const player of poll.responses) player.jerseyNumber = numbers.get(player.id) ?? null;
  }
  if (polls.length) {
    const votes = check(await admin.from('gameon_team_poll_votes').select('poll_id,player_id,voted_at').in('poll_id', polls.map(poll => poll.id)));
    const times = new Map(votes.map(vote => [`${vote.poll_id}:${vote.player_id}`, vote.voted_at]));
    for (const poll of polls) {
      for (const player of poll.responses) player.votedAt = times.get(`${poll.id}:${player.id}`) || null;
      poll.responses.sort((a, b) => {
        if (!a.answer && b.answer) return 1;
        if (a.answer && !b.answer) return -1;
        return (a.votedAt && b.votedAt ? Date.parse(a.votedAt) - Date.parse(b.votedAt) : 0) || (a.name || '').localeCompare(b.name || '') || a.id.localeCompare(b.id);
      });
    }
  }
  if (body.operation === 'create') {
    await notifyUsers((polls[0]?.responses || []).map((r) => r.id).filter((id) => id !== user.id), {
      title: 'Match availability · New poll',
      body: `${body.title} · ${body.matchDate.split('-').reverse().join('/')} — Open to confirm Yes or No.`,
      data: { type: 'team-poll', teamId: body.teamId },
    });
  }
  return { polls };
}
