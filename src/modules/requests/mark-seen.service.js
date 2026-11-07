import { snapshot } from '../snapshot/snapshot.service.js';
import { check } from '../../lib/errors.js';
export async function markSeen({ body, user, client }) {
  check(
    await client.rpc('gameon_mark_requests_seen', {
      community_filter: body.communityId || null,
    }),
  );
  return { snapshot: await snapshot(user) };
}
