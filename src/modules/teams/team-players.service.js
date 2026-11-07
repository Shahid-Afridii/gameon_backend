import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
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
  const captain = check(
    await admin
      .from("gameon_teams")
      .select("id")
      .eq("captain_id", user.id)
      .maybeSingle(),
  );
  const profile = check(
    await admin
      .from("gameon_profiles")
      .select("role,completed")
      .eq("id", user.id)
      .single(),
  );
  if (
    !captain ||
    profile.role !== "Captain" ||
    !profile.completed ||
    (await isAdmin(user.id))
  )
    fail("Only a team captain can find players.", 403);
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
