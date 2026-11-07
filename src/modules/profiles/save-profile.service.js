import { snapshot } from "../snapshot/snapshot.service.js";
import { check, fail } from "../../lib/errors.js";
import { text } from "../../lib/validation.js";
export async function saveProfile({ body, user, client }) {
  const values = body.values || {};
  const name = text(values.name, 2, 60, "Name");
  if (!["Player", "Captain"].includes(values.role))
    fail("Choose Player or Captain.");
  const email = String(values.email || "").trim();
  if (
    email &&
    (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
  )
    fail("Enter a valid email address.");
  const teamName =
    values.role === "Captain" ? String(values.teamName || "").trim() : "";
  check(
    await client.rpc("gameon_save_cricket_preferences", {
      display_name: name,
      contact_email: email || null,
      account_role: values.role,
      cricket_specialty: values.cricketRole || null,
      shirt_number: values.jerseyNumber ?? null,
      preferred_balls:
        values.ballTypes ?? (values.ballType ? [values.ballType] : []),
      selected_team: teamName,
    }),
  );
  return { snapshot: await snapshot(user) };
}
