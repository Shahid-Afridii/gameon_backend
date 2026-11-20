import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { phoneValue } from "../../lib/validation.js";
import { isAdmin } from "../auth/permissions.js";
import { snapshot } from "../snapshot/snapshot.service.js";
import { notifyUsers } from "../notifications/push.service.js";

const action =
  (operation) =>
  async ({ user, body }) => {
    if (operation === "invite" && (await isAdmin(user.id)))
      fail("Use a captain or player account for team requests.", 403);
    const result = await admin.rpc("gameon_team_player_action", {
      actor: user.id,
      operation,
      payload: body,
    });
    if (result.error?.code === "23505")
      fail("This player is already in the team or has a pending request.", 409);
    if (result.error?.code === "P0001") fail(result.error.message, 409);
    const saved = check(result);
    await notifyUsers([saved.recipientId], {
      title:
        operation === "review"
          ? "Team request updated"
          : operation === "invite"
            ? "You have a team invitation"
            : "New player join request",
      body:
        operation === "review"
          ? `Your request for ${saved.teamName} was ${saved.status}.`
          : operation === "invite"
            ? `${saved.teamName} invited you to join as a player.`
            : `A player wants to join ${saved.teamName}. Open My Teams to review.`,
      data: { type: "team-player-request", requestId: saved.requestId },
    });
    return { snapshot: await snapshot(user) };
  };
export const inviteTeamPlayer = action("invite");
export const requestTeamJoin = action("join");
export const reviewTeamPlayer = action("review");

export async function searchPlayers({ user, body }) {
  const profile = check(
    await admin.from("gameon_profiles").select("role,completed").eq("id", user.id).single(),
  );
  if (profile.role !== "Captain" || !profile.completed || await isAdmin(user.id))
    fail("Only a team captain can find players.", 403);
  const captain = check(
    await admin.from("gameon_teams").select("id").eq("captain_id", user.id).limit(1).maybeSingle(),
  );
  if (!captain) fail("Create a team before searching for players.", 403);
  // Search names only. Phone numbers and emails never enter the directory response.
  const escaped = body.query.replace(/[\\%_]/g, "\\$&");
  const players = check(
    await admin
      .from("gameon_profiles")
      .select("id,name")
      .eq("role", "Player")
      .ilike("name", `%${escaped}%`)
      .order("name")
      .order("id")
      .limit(20),
  );
  return { players };
}

export async function addManualTeamPlayer({ user, body }) {
  const team = check(await admin.from("gameon_teams")
    .select("id").eq("id", body.teamId).eq("captain_id", user.id).maybeSingle());
  const profile = check(await admin.from("gameon_profiles")
    .select("role,completed").eq("id", user.id).single());
  if (!team || profile.role !== "Captain" || !profile.completed || await isAdmin(user.id))
    fail("Only the team captain can add roster players.", 403);
  const saved = await admin.from("gameon_manual_players").insert({
    team_id: team.id, name: body.name, cricket_role: body.cricketRole, jersey_number: body.jerseyNumber,
  });
  if (saved.error?.code === "23505") fail("A player with that name and jersey is already in the squad.", 409);
  check(saved);
  return { snapshot: await snapshot(user) };
}

export async function inviteManualTeamPlayer({ user, body }) {
  const result = await admin.rpc("gameon_invite_manual_player", {
    actor: user.id, roster_id: body.playerId, mobile: phoneValue(body.phone),
  });
  if (result.error?.code === "23505") fail("That number already has a roster entry for this team.", 409);
  if (result.error?.code === "P0001") fail(result.error.message, 409);
  check(result);
  return { snapshot: await snapshot(user) };
}

export async function teamStats({ user, body }) {
  const args = { actor: user.id, target_team: body.teamId };
  const [record, breakdown] = await Promise.all([
    admin.rpc("gameon_team_stats", args),
    admin.rpc("gameon_team_match_insights", args),
  ]);
  const stats = check(record);
  const insights = breakdown.error?.code === "PGRST202" ? null : check(breakdown);
  return { stats: { ...stats, insights } };
}
