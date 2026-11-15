import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";

export async function playerPerformance({ user, body }) {
  const result = await admin.rpc("gameon_player_performance", {
    actor: user.id,
    target_player: body.playerId,
  });
  if (result.error?.code === "42501") fail(result.error.message, 403);
  if (result.error?.code === "P0001") fail(result.error.message, 404);
  return { performance: check(result) };
}
