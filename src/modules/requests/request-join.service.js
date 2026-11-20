import { captainTeam } from '../teams/captain-team.js';
import { admin } from '../../config/supabase.js';
import { snapshot } from '../snapshot/snapshot.service.js';
import { check, fail } from '../../lib/errors.js';
import { isAdmin } from '../auth/permissions.js';
export async function requestJoin({ body, user, client }) {
  if (await isAdmin(user.id)) fail('Only a team captain can join a community.', 403);
  if (body.accepted !== true) fail('Accept the community rules.');
  const team = await captainTeam(client, user.id, body.sourceTeamId);
  if (!team) fail('Add your team before joining a community.');
  const result = await admin.rpc('gameon_join_community', {
    actor: user.id,
    club_id: body.communityId,
    source_id: team.id,
  });
  if (result.error?.code === 'P0002') fail('Community unavailable.', 404);
  check(result);
  return { snapshot: await snapshot(user) };
}
