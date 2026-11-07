import { snapshot } from '../snapshot/snapshot.service.js';
import { check } from '../../lib/errors.js';
export async function reviewRequest({ body, user, client }) {
  check(
    await client.rpc('gameon_review_request', {
      request_id: body.requestId,
      decision: body.decision,
    }),
  );
  return { snapshot: await snapshot(user) };
}
