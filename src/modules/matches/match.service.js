import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { snapshot } from "../snapshot/snapshot.service.js";
import { isAdmin } from "../auth/permissions.js";
import { notifyUsers } from "../notifications/push.service.js";

const action =
  (operation) =>
  async ({ user, body }) => {
    if (await isAdmin(user.id))
      fail("Only team captains can manage match requests.", 403);
    const scheduled = operation === "request_with_plan";
    const result = scheduled
      ? await admin.rpc("gameon_schedule_match", {
          actor: user.id,
          payload: body,
        })
      : operation === "review"
        ? await admin.rpc("gameon_confirm_match", {
            actor: user.id,
            payload: body,
          })
        : await admin.rpc("gameon_match_action", {
            actor: user.id,
            operation,
            payload: body,
          });
    if (result.error?.code === "23505")
      fail("A match request between these teams is already pending.", 409);
    if (
      operation === "request_with_plan" &&
      result.error?.message === "Unknown match operation."
    )
      fail(
        "Run the match challenge migration in Supabase before sending a challenge.",
        503,
      );
    if (result.error?.code === "P0001") fail(result.error.message, 409);
    const reviewed = check(result);
    if (operation === "review" && body.decision === "accepted") {
      const fixture = reviewed?.fixture;
      const plan = fixture?.plan;
      const firstMatch = plan?.schedule?.[0];
      const count = plan?.overs?.length;
      const title = fixture?.communityName
        ? `Match confirmed · ${fixture.communityName}`
        : "Match confirmed";
      const details = fixture
        ? [
            `${fixture.fromTeam} vs ${fixture.toTeam}`,
            firstMatch && `${firstMatch.date} ${firstMatch.time} IST`,
            count && `${plan.overs[0]} overs`,
            count > 1 && `${count} matches`,
            plan?.ballType,
          ]
            .filter(Boolean)
            .join(" · ")
            .slice(0, 220)
        : "The opposing captain accepted your challenge. Open GameOn to view the schedule.";
      const challenger = reviewed?.notifyUser;
      await Promise.all([
        notifyUsers([challenger], {
          title,
          body: details,
          data: { type: "match-confirmed", requestId: body.requestId },
        }),
        notifyUsers(
          (reviewed?.recipientIds || []).filter((id) => id !== challenger),
          {
            title,
            body: details,
            data: { type: "team-match-confirmed", matchId: body.requestId },
          },
        ),
      ]);
    }
    return {
      snapshot: await snapshot(user),
      ...(operation === "review" &&
      body.decision === "accepted" &&
      reviewed?.fixture
        ? { confirmedMatch: { id: body.requestId, ...reviewed.fixture } }
        : {}),
    };
  };
export async function setMatchAvailability({ user, body }) {
  if (await isAdmin(user.id))
    fail("Only team captains can manage match requests.", 403);
  const result = await admin.rpc("gameon_set_availability_and_collect_watches", {
    actor: user.id,
    payload: body,
  });
  if (result.error?.code === "PGRST202")
    return action("availability")({ user, body });
  if (result.error?.code === "P0001") fail(result.error.message, 409);
  const { recipients, teamName } = check(result);
  const watchersByCommunity = new Map();
  for (const { userId, communityId } of recipients) {
    if (!watchersByCommunity.has(communityId)) watchersByCommunity.set(communityId, []);
    watchersByCommunity.get(communityId).push(userId);
  }
  await Promise.all(
    [...watchersByCommunity].map(([communityId, userIds]) => notifyUsers(userIds, {
      title: "Team available for a match",
      body: `${teamName} is now accepting match invitations.`,
      data: { type: "team-available", communityId },
    })),
  );
  return { snapshot: await snapshot(user) };
}
export const requestMatch = action("request_with_plan");
export const reviewMatch = action("review");

export async function matchConversation({ user, body }) {
  if (await isAdmin(user.id))
    fail("Only the two captains can open this match conversation.", 403);
  const { operation, ...payload } = body;
  const result = await admin.rpc("gameon_match_chat_status", {
    actor: user.id,
    operation,
    payload,
  });
  if (result.error?.code === "P0001") {
    fail(
      result.error.message,
      result.error.message.startsWith("Only the two captains") ? 403 : 409,
    );
  }
  const { notifyUser, senderName, ...thread } = check(result);
  if (operation === "message" && notifyUser) {
    await notifyUsers([notifyUser], {
      title: `${senderName || "Captain"} · ${thread.communityName || "GameOn"}`,
      body: body.message.slice(0, 140),
      data: { type: "match-chat-message", requestId: body.requestId },
    });
  }
  return thread;
}

export async function matchInbox({ user }) {
  if (await isAdmin(user.id)) return { threads: [] };
  return {
    threads: check(await admin.rpc("gameon_match_inbox", { actor: user.id })),
  };
}

export async function touchMatchPresence({ user }) {
  check(await admin.rpc("gameon_touch_match_presence", { actor: user.id }));
  return { recorded: true };
}

export async function listConfirmedMatches({ user }) {
  const matches = check(
    await admin.rpc("gameon_list_confirmed_matches", { actor: user.id }),
  );
  return { matches };
}

export async function matchHeadToHead({ user, body }) {
  const result = await admin.rpc("gameon_match_head_to_head", {
    actor: user.id,
    club_id: body.communityId,
    opponent_id: body.teamId,
  });
  if (result.error?.code === "42501") fail(result.error.message, 403);
  return check(result);
}

export async function cancelMatch({ user, body }) {
  const result = await admin.rpc("gameon_cancel_match", {
    actor: user.id,
    payload: body,
  });
  if (result.error?.code === "P0001") {
    fail(
      result.error.message,
      result.error.message.startsWith("Only either team captain") ? 403 : 409,
    );
  }
  return { cancellation: check(result), snapshot: await snapshot(user) };
}

export async function withdrawMatchRequest({ user, body }) {
  const result = await admin.rpc("gameon_withdraw_match_request", {
    actor: user.id,
    request_id: body.requestId,
  });
  if (result.error?.code === "P0001") {
    fail(
      result.error.message,
      result.error.message.startsWith("Only the captain who sent") ? 403 : 409,
    );
  }
  check(result);
  return { snapshot: await snapshot(user) };
}
