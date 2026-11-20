import { communityDashboard, communityMatchWaves, watchTeamAvailability } from "../modules/communities/community-dashboard.service.js";
import { matchScore } from "../modules/matches/scoring.service.js";
import { playerPerformance } from "../modules/profiles/player-performance.service.js";
import { teamPoll } from "../modules/teams/team-polls.service.js";
import {
  addManualTeamPlayer,
  inviteManualTeamPlayer,
  teamStats,
  inviteTeamPlayer,
  requestTeamJoin,
  reviewTeamPlayer,
  searchPlayers,
} from "../modules/teams/team-players.service.js";
import {
  setMatchAvailability,
  requestMatch,
  reviewMatch,
  cancelMatch,
  withdrawMatchRequest,
  matchConversation,
  matchInbox,
  listConfirmedMatches,
  matchHeadToHead,
  touchMatchPresence,
} from "../modules/matches/match.service.js";
import {
  registerPush,
  unregisterPush,
} from "../modules/notifications/push.service.js";
import { Router } from "express";
import { env } from "../config/environment.js";
import { fail } from "../lib/errors.js";
import { validate } from "../middleware/validate.js";
import { authenticate } from "../middleware/authenticate.js";
import {
  schemas,
  otpRequest,
  otpVerify,
  refresh,
  phoneChangeRequest,
  phoneChangeVerify,
} from "./schemas.js";
import { login } from "../modules/auth/test-login.service.js";
import {
  requestOtp,
  verifyOtp,
  refreshSession,
  logout,
  requestPhoneChange,
  verifyPhoneChange,
} from "../modules/auth/auth.service.js";
import { snapshot } from "../modules/snapshot/snapshot.service.js";
import { saveProfile } from "../modules/profiles/save-profile.service.js";
import { saveTeam, selectCaptainTeam } from "../modules/teams/save-team.service.js";
import { createCommunity } from "../modules/communities/create-community.service.js";
import { leaveCommunity } from "../modules/communities/leave-community.service.js";
import { requestJoin } from "../modules/requests/request-join.service.js";
import { reviewRequest } from "../modules/requests/review-request.service.js";
import { markSeen } from "../modules/requests/mark-seen.service.js";
import { changePhone } from "../modules/accounts/change-phone.service.js";
import { deleteAccount } from "../modules/accounts/delete-account.service.js";
export const operations = {
  communityDashboard,
  communityMatchWaves,
  watchTeamAvailability,
  matchScore,
  teamPoll,
  addManualTeamPlayer,
  inviteManualTeamPlayer,
  teamStats,
  inviteTeamPlayer,
  requestTeamJoin,
  reviewTeamPlayer,
  searchPlayers,
  playerPerformance,
  setMatchAvailability,
  requestMatch,
  reviewMatch,
  cancelMatch,
  withdrawMatchRequest,
  matchConversation,
  matchInbox,
  listConfirmedMatches,
  matchHeadToHead,
  touchMatchPresence,
  registerPush,
  unregisterPush,
  saveProfile,
  saveTeam,
  selectCaptainTeam,
  createCommunity,
  leaveCommunity,
  requestJoin,
  reviewRequest,
  markSeen,
  changePhone,
  deleteAccount,
};
const context = (req) => ({ ...req.identity, body: req.body, req });
const handle = (service) => async (req, res) =>
  res.json(await service(context(req)));
export function createApiRouter() {
  const router = Router();
  router.post("/auth/otp/request", validate(otpRequest), async (req, res) =>
    res.json(await requestOtp(req.body, req)),
  );
  router.post("/auth/otp/verify", validate(otpVerify), async (req, res) =>
    res.json(await verifyOtp(req.body, req)),
  );
  router.post("/auth/refresh", validate(refresh), async (req, res) =>
    res.json(await refreshSession(req.body)),
  );
  router.post("/auth/test-login", validate(schemas.login), async (req, res) =>
    res.json(await login(req.body, req)),
  );
  router.post("/auth/logout", authenticate, async (req, res) =>
    res.json(await logout(req.identity.token)),
  );
  router.post(
    "/account/phone/request",
    authenticate,
    validate(phoneChangeRequest),
    handle(requestPhoneChange),
  );
  router.post(
    "/account/phone/verify",
    authenticate,
    validate(phoneChangeVerify),
    handle(verifyPhoneChange),
  );
  router.get("/me/snapshot", authenticate, async (req, res) =>
    res.json(await snapshot(req.identity.user)),
  );
  const routes = [
    ["post", "/teams/players/manual", "addManualTeamPlayer"],
    ["post", "/teams/players/manual/invite", "inviteManualTeamPlayer"],
    ["post", "/teams/stats", "teamStats"],
    ["post", "/teams/players/invite", "inviteTeamPlayer"],
    ["post", "/teams/players/join", "requestTeamJoin"],
    ["post", "/teams/players/review", "reviewTeamPlayer"],
    ["post", "/teams/players/search", "searchPlayers"],
    ["post", "/players/performance", "playerPerformance"],
    ["patch", "/me/team/availability", "setMatchAvailability"],
    ["post", "/match-requests", "requestMatch"],
    ["post", "/match-requests/review", "reviewMatch"],
    ["post", "/match-requests/cancel", "cancelMatch"],
    ["post", "/match-requests/withdraw", "withdrawMatchRequest"],
    ["post", "/match-requests/conversation", "matchConversation"],
    ["post", "/match-requests/inbox", "matchInbox"],
    ["post", "/match-requests/score", "matchScore"],
    ["post", "/match-requests/confirmed", "listConfirmedMatches"],
    ["post", "/match-requests/head-to-head", "matchHeadToHead"],
    ["post", "/match-requests/presence", "touchMatchPresence"],
    ["patch", "/me/profile", "saveProfile"],
    ["put", "/me/team", "saveTeam"],
    ["post", "/me/team/select", "selectCaptainTeam"],
    ["post", "/communities", "createCommunity"],
    ["post", "/communities/dashboard", "communityDashboard"],
    ["post", "/communities/match-waves", "communityMatchWaves"],
    ["post", "/communities/watch-availability", "watchTeamAvailability"],
    ["post", "/join-requests", "requestJoin"],
    ["post", "/join-requests/review", "reviewRequest"],
    ["post", "/join-requests/seen", "markSeen"],
    ["post", "/memberships/leave", "leaveCommunity"],
    ["delete", "/me/account", "deleteAccount"],
  ];
  for (const [method, path, action] of routes)
    router[method](
      path,
      authenticate,
      validate(schemas[action]),
      handle(operations[action]),
    );
  // Bridge keeps the existing app's action payload/response contract for the later frontend switch.
  router.post("/actions", async (req, res) => {
    if (!req.body || typeof req.body !== "object" || Array.isArray(req.body))
      fail("Send a request object.");
    const { action, ...payload } = req.body;
    if (typeof action !== "string" || !Object.hasOwn(schemas, action))
      fail("Unknown action.");
    req.body = payload;
    validate(schemas[action])(req, res, () => {});
    if (action === "login") return res.json(await login(req.body, req));
    await authenticate(req, res, () => {});
    if (action === "snapshot")
      return res.json(await snapshot(req.identity.user));
    if (action === "changePhone" && !env.GAMEON_TEST_LOGIN_ENABLED)
      fail("Use verified phone change endpoints.", 403);
    return res.json(await operations[action](context(req)));
  });
  return router;
}
