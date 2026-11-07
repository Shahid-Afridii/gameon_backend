import { check, fail } from '../../lib/errors.js';
import { text } from '../../lib/validation.js';
import { isAdmin } from '../auth/permissions.js';
import { snapshot } from '../snapshot/snapshot.service.js';
export async function createCommunity({ body, user, client }) {
  if (!(await isAdmin(user.id))) fail('Superadmin access required.', 403);
  const values = body.values || {};
  const rules = String(values.rules || '')
    .split('\n')
    .map((r) => r.trim())
    .filter(Boolean);
  if (!rules.length || rules.length > 12 || rules.some((r) => r.length > 250))
    fail('Add 1–12 rules, up to 250 characters each.');
  if (!['Corporate', 'Local'].includes(values.category)) fail('Choose a community type.');
  const community = check(
    await client
      .from('gameon_communities')
      .insert({
        name: text(values.name, 3, 80, 'Community name'),
        location: text(values.city, 2, 100, 'Location'),
        description: text(values.description, 10, 1000, 'Description'),
        rules,
        category: values.category,
      })
      .select('id')
      .single(),
  );
  return { communityId: community.id, snapshot: await snapshot(user) };
}
