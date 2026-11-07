import { admin } from '../../config/supabase.js';
import { check } from '../../lib/errors.js';
export async function isAdmin(id) {
  return Boolean(
    check(await admin.from('gameon_admins').select('user_id').eq('user_id', id).maybeSingle()),
  );
}
