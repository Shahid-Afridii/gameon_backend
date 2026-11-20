import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { notifyUsers } from "../notifications/push.service.js";

const waveDateFormat = new Intl.DateTimeFormat("en-IN", {
  day: "numeric",
  month: "short",
  timeZone: "UTC",
});

function dashboardResult(result) {
  if (result.error?.code === "42501") fail(result.error.message, 403);
  if (result.error?.code === "P0001") fail(result.error.message, 409);
  return check(result);
}

export async function communityDashboard({ user, body }) {
  return dashboardResult(await admin.rpc("gameon_community_dashboard", {
    actor: user.id,
    club_id: body.communityId,
  }));
}

export async function watchTeamAvailability({ user, body }) {
  const result = await admin.rpc("gameon_watch_availability", {
    actor: user.id,
    club_id: body.communityId,
    opponent_id: body.teamId,
    watching: body.watching,
  });
  if (["PGRST202", "PGRST205", "42P01", "42883"].includes(result.error?.code)) {
    fail("Availability alerts are not set up in Supabase. Apply the availability alert migration and its prerequisites.", 503);
  }
  return { watching: dashboardResult(result) };
}

export async function communityMatchWaves({ user, body }) {
  const { communityId, ...change } = body;
  const { notification, ...feed } = dashboardResult(
    await admin.rpc("gameon_community_match_waves", {
      actor: user.id,
      club_id: communityId,
      change,
    }),
  );

  if (notification) {
    const { teamName, communityName, date, updated, recipientIds } = notification;
    const matchDate = waveDateFormat.format(new Date(`${date}T00:00:00Z`));
    const message = {
      title: `${updated ? "Match wave updated" : "Match wave"} · ${communityName}`,
      body: updated
        ? `${teamName} changed their match wave date to ${matchDate}.`
        : `${teamName} is inviting teams to play on ${matchDate}.`,
      data: { type: "community-match-wave", communityId },
    };
    for (let offset = 0; offset < recipientIds.length; offset += 100) {
      await notifyUsers(recipientIds.slice(offset, offset + 100), message);
    }
  }

  return feed;
}
