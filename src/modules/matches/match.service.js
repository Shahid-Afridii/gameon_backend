import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { snapshot } from "../snapshot/snapshot.service.js";
import { isAdmin } from "../auth/permissions.js";

const action =
  (operation) =>
  async ({ user, body }) => {
    if (await isAdmin(user.id))
      fail("Only team captains can manage match requests.", 403);
    const result = await admin.rpc("gameon_match_action", {
      actor: user.id,
      operation,
      payload: body,
    });
    if (result.error?.code === "23505")
      fail("A match request between these teams is already pending.", 409);
    if (result.error?.code === "P0001") fail(result.error.message, 409);
    check(result);
    return { snapshot: await snapshot(user) };
  };
export const setMatchAvailability = action("availability");
export const requestMatch = action("request");
export const reviewMatch = action("review");
