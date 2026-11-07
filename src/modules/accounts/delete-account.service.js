import { admin } from '../../config/supabase.js';
import { fail } from '../../lib/errors.js';
import { isAdmin } from '../auth/permissions.js';
export async function deleteAccount({ user }) {
  if (await isAdmin(user.id))
    fail('Superadmin account deletion needs a separate ownership transfer.', 403);
  const result = await admin.auth.admin.deleteUser(user.id);
  if (result.error) fail('Account could not be deleted.');
  return { deleted: true };
}
