import { snapshot } from '../snapshot/snapshot.service.js';
import { check } from '../../lib/errors.js';
export async function leaveCommunity({ body, user, client }) {
  const team = check(
    await client.from('gameon_teams').select('id').eq('captain_id', user.id).maybeSingle(),
  );
  if (team)
    check(
      await client
        .from('gameon_memberships')
        .delete()
        .eq('community_id', body.communityId)
        .eq('team_id', team.id),
    );
  return { snapshot: await snapshot(user) };
}
