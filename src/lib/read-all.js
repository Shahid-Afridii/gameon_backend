import { admin } from '../config/supabase.js';
import { check, fail } from './errors.js';
// Transitional snapshot contract. Bound memory; move to cursor endpoints as the product grows.
export async function readAll(table, columns, order, filters = {}) {
  const data = [];
  for (let offset = 0; offset < 10000; offset += 500) {
    let query = admin
      .from(table)
      .select(columns)
      .order(order)
      .range(offset, offset + 499);
    if (table === 'gameon_team_players') query = query.order('player_id');
    if (table === 'gameon_memberships') query = query.order('community_id');
    for (const [column, value] of Object.entries(filters)) query = query.eq(column, value);
    const rows = check(await query);
    data.push(...rows);
    if (rows.length < 500) return { data, error: null };
  }
  fail('Directory is too large for snapshot. Use paginated endpoints before growing further.', 503);
}
