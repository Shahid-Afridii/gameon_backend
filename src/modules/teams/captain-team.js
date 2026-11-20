import { admin } from "../../config/supabase.js";
import { check } from "../../lib/errors.js";

export async function captainTeam(client, actor, sourceTeamId) {
  const id = sourceTeamId ?? check(await admin.rpc("gameon_active_captain_team", { actor }));
  if (!id) return null;
  return check(await client.from("gameon_teams").select("id").eq("id", id).eq("captain_id", actor).maybeSingle());
}
