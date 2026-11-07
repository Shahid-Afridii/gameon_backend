import { notifyAdmins } from '../notifications/push.service.js';
import { snapshot } from '../snapshot/snapshot.service.js';
import { check, fail } from '../../lib/errors.js';
import { isAdmin } from '../auth/permissions.js';
export async function requestJoin({ body, user, client }) {
  if (await isAdmin(user.id)) fail('Only a team captain can request membership.', 403);
  if (body.accepted !== true) fail('Accept the community rules.');
  const team = check(
    await client.from('gameon_teams').select('id').eq('captain_id', user.id).maybeSingle(),
  );
  if (!team) fail('Add your team before requesting membership.');
  const existing = check(
    await client
      .from('gameon_join_requests')
      .select('id')
      .eq('community_id', body.communityId)
      .eq('team_id', team.id)
      .eq('status', 'pending'),
  );
  if (!existing.length) {
    check(
      await client
        .from('gameon_join_requests')
        .insert({ community_id: body.communityId, team_id: team.id, captain_id: user.id }),
    );
    await notifyAdmins();
  }
  return { snapshot: await snapshot(user) };
}
