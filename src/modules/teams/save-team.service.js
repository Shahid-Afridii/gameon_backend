import { snapshot } from "../snapshot/snapshot.service.js";
import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { text } from "../../lib/validation.js";
export async function saveTeam({ body, user, client }) {
  const values = body.values || {};
  const profile = check(
    await admin
      .from("gameon_profiles")
      .select("role,completed")
      .eq("id", user.id)
      .single(),
  );
  if (profile.role !== "Captain" || !profile.completed)
    fail("Complete your captain profile first.", 403);
  const name = text(values.name, 2, 60, "Team name");
  const groundName = values.hasGround
    ? text(values.groundName, 3, 100, "Ground name")
    : "";
  const groundArea = values.hasGround
    ? text(values.groundArea, 1, 250, "Ground area")
    : "";
  const amenities = Array.isArray(values.amenities)
    ? values.amenities
        .filter((v) => typeof v === "string" && v.length <= 60)
        .slice(0, 20)
    : [];
  if (body.teamId === undefined) {
    check(await client.rpc("gameon_save_team_details", {
      team_name: name,
      team_description: values.description || "",
      owns_ground: values.hasGround,
      venue_name: groundName,
      venue_area: groundArea,
      venue_amenities: amenities,
    }));
  } else {
    await manageTeam(user.id, body.teamId, {
      name, description: values.description || "", hasGround: values.hasGround,
      groundName, groundArea, amenities,
    });
  }
  return { snapshot: await snapshot(user) };
}

async function manageTeam(actor, teamId, details) {
  const result = await admin.rpc("gameon_manage_captain_team", {
    actor, target_team: teamId, details,
  });
  if (result.error?.code === "P0001") fail(result.error.message, 409);
  return check(result);
}

export async function selectCaptainTeam({ user, body }) {
  await manageTeam(user.id, body.teamId, null);
  return { snapshot: await snapshot(user) };
}
