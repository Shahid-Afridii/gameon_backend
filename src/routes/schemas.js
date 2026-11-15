import { validateDelivery } from "../modules/matches/delivery.rules.js";
import { z } from "zod/v4";
const name = z.string().trim().min(2).max(60);
const phone = z.string().min(10).max(20);
const code = z.string().regex(/^\d{4,8}$/);
const uuid = z.uuid();
const empty = z.strictObject({});
const optionalText = (max) => z.string().trim().max(max).default("");
const ballType = z.enum(["Stitch ball", "Tennis ball", "Cork ball", "Soft tennis ball"]);
const matchDetails = {
  ballType,
  overs: z.array(z.number().int().min(1).max(50)).min(1).max(5),
  schedule: z.array(z.strictObject({
    date: z.iso.date(),
    time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
  })).min(1).max(5),
};
function validateMatchDetails(plan, ctx) {
  if (plan.schedule.length !== plan.overs.length)
    ctx.addIssue({ code: "custom", path: ["schedule"], message: "Pick a date and time for every match." });
  let previous = Date.now();
  for (const [index, slot] of plan.schedule.entries()) {
    const start = Date.parse(`${slot.date}T${slot.time}:00+05:30`);
    if (start <= previous)
      ctx.addIssue({ code: "custom", path: ["schedule", index], message: "Match times must be in the future and in order." });
    previous = Math.max(previous, start);
  }
}
const pushToken = z
  .string()
  .min(20)
  .max(300)
  .regex(/^(ExpoPushToken|ExponentPushToken)\[[A-Za-z0-9_-]+\]$/);
const scoreFixture = { requestId: uuid, matchIndex: z.number().int().min(0).max(4) };
// Seeded player IDs are PostgreSQL UUIDs without RFC version and variant bits.
const rosterPlayerId = z.guid();
const scoreChange = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("lineup"), players: z.array(rosterPlayerId).length(11) }),
  z.discriminatedUnion("method", [
    z.strictObject({ kind: z.literal("toss"), method: z.literal("coin"), headsTeamId: uuid }),
    z.strictObject({ kind: z.literal("toss"), method: z.literal("manual"), winnerTeamId: uuid }),
  ]),
  z.strictObject({ kind: z.literal("tossDecision"), decision: z.enum(["bat", "bowl"]) }),
  z.strictObject({ kind: z.literal("retoss") }),
  z.strictObject({ kind: z.literal("start") }),
  z.strictObject({ kind: z.literal("select"), position: z.enum(["striker", "nonStriker", "bowler"]), playerId: rosterPlayerId }),
  z.strictObject({
    kind: z.literal("delivery"),
    outcome: z.enum(["runs", "wide", "noBall", "bye", "legBye", "wicket"]),
    runs: z.number().int().min(0).max(6),
    shotZone: z.enum(["thirdMan", "point", "cover", "longOff", "longOn", "midwicket", "squareLeg", "fineLeg", "crease"]).optional(),
    dismissal: z.enum(["bowled", "caught", "lbw", "stumped", "hitWicket", "runOutStriker", "runOutNonStriker", "hitBallTwice", "obstructingField"]).optional(),
    boundary: z.union([z.literal(0), z.literal(4), z.literal(6)]).optional(),
    noBallRuns: z.enum(["bye", "legBye"]).optional(),
    fielderId: rosterPlayerId.optional(),
    incomingEnd: z.enum(["striker", "nonStriker"]).optional(),
  }).superRefine((delivery, ctx) => {
    const message = validateDelivery(delivery);
    if (message) ctx.addIssue({ code: "custom", message });
  }),
  z.strictObject({ kind: z.literal("undo"), deliveryIndex: z.number().int().nonnegative().optional() }),
  z.strictObject({ kind: z.literal("nextInnings") }),
  z.strictObject({ kind: z.literal("endAsDraw"), reason: z.enum(["rain", "other"]) }),
  z.strictObject({ kind: z.literal("endMatch"), reason: z.enum(["completed", "weather", "other"]) }),
  z.strictObject({ kind: z.literal("assignScorer"), playerId: rosterPlayerId }),
]);
export const schemas = {
  matchScore: z.discriminatedUnion("operation", [
    z.strictObject({ ...scoreFixture, operation: z.literal("read") }),
    z.strictObject({
      ...scoreFixture, operation: z.literal("update"), revision: z.number().int().min(0).max(2147483646),
      change: scoreChange,
    }),
  ]),
  teamPoll: z.strictObject({
    operation: z.enum(['list', 'create', 'vote']),
    teamId: uuid,
    pollId: uuid.optional(),
    title: z.string().trim().min(3).max(120).optional(),
    matchDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    answer: z.enum(['yes', 'no']).optional(),
  }).superRefine((value, ctx) => {
    if (value.operation === 'create' && (!value.title || !value.matchDate)) ctx.addIssue({code: 'custom', message: 'Add a title and match date.'});
    if (value.operation === 'vote' && (!value.pollId || !value.answer)) ctx.addIssue({code: 'custom', message: 'Choose Yes or No.'});
  }),
  inviteTeamPlayer: z.strictObject({ teamId: uuid, playerId: uuid }),
  requestTeamJoin: z.strictObject({ teamId: uuid }),
  reviewTeamPlayer: z.strictObject({
    requestId: uuid,
    decision: z.enum(["accepted", "declined"]),
  }),
  searchPlayers: z.strictObject({ query: z.string().trim().min(2).max(60) }),
  // Seeded cricket profiles are valid PostgreSQL UUIDs but may not carry RFC version bits.
  playerPerformance: z.strictObject({ playerId: rosterPlayerId }),
  setMatchAvailability: z.strictObject({ available: z.boolean() }),
  requestMatch: z.strictObject({
    communityId: uuid,
    teamId: uuid,
    plan: z.strictObject({
      ...matchDetails,
      guestEmail: z.email().max(254).optional(),
      venue: z.discriminatedUnion("kind", [
        z.strictObject({ kind: z.enum(["home", "away"]) }),
        z.strictObject({ kind: z.literal("neutral"), location: z.string().trim().min(3).max(250) }),
      ]),
    }).superRefine(validateMatchDetails),
  }),
  matchInbox: empty,
  listConfirmedMatches: empty,
  matchHeadToHead: z.strictObject({ communityId: uuid, teamId: uuid }),
  touchMatchPresence: empty,
  matchConversation: z.discriminatedUnion("operation", [
    z.strictObject({ operation: z.literal("list"), requestId: uuid }),
    z.strictObject({ operation: z.literal("message"), requestId: uuid, message: z.string().trim().min(1).max(1000) }),
    z.strictObject({ operation: z.literal("propose"), requestId: uuid, version: z.number().int().min(0).max(2147483647),
      changes: z.strictObject(matchDetails).superRefine(validateMatchDetails) }),
    z.strictObject({ operation: z.literal("decide"), requestId: uuid, proposalId: uuid, decision: z.enum(["accepted", "declined"]) }),
  ]),
  withdrawMatchRequest: z.strictObject({ requestId: uuid }),
  cancelMatch: z.strictObject({ requestId: uuid, reason: z.string().trim().min(3).max(500) }),
  reviewMatch: z.strictObject({
    requestId: uuid,
    decision: z.enum(["accepted", "declined"]),
  }),
  registerPush: z.strictObject({ token: pushToken }),
  unregisterPush: z.strictObject({ token: pushToken }),
  login: z.strictObject({ phone, code, name }),
  snapshot: empty,
  saveProfile: z.strictObject({
    values: z.strictObject({
      name,
      email: z.union([z.email().max(254), z.literal("")]).default(""),
      role: z.enum(["Player", "Captain"]),
      cricketRole: z
        .enum(["Batsman", "Bowler", "All-rounder", "Wicketkeeper-batsman"])
        .nullable()
        .default(null),
      teamName: optionalText(60),
      jerseyNumber: z.number().int().min(0).max(99).nullable().default(null),
      ballTypes: z
        .array(ballType)
        .max(4)
        .refine((items) => new Set(items).size === items.length)
        .optional(),
      ballType: ballType.nullable().default(null),
    }),
  }),
  saveTeam: z.strictObject({
    values: z.strictObject({
      name,
      description: optionalText(600),
      hasGround: z.boolean(),
      groundName: optionalText(100),
      groundArea: optionalText(250),
      amenities: z.array(z.string().trim().min(1).max(60)).max(20).default([]),
    }),
  }),
  createCommunity: z.strictObject({
    values: z.strictObject({
      name: z.string().trim().min(3).max(80),
      city: z.string().trim().min(2).max(100),
      description: z.string().trim().min(10).max(1000),
      rules: z.string().min(1).max(3100),
      category: z.enum(["Corporate", "Local"]),
    }),
  }),
  requestJoin: z.strictObject({ communityId: uuid, accepted: z.literal(true) }),
  reviewRequest: z.strictObject({
    requestId: uuid,
    decision: z.enum(["approved", "rejected"]),
  }),
  markSeen: z.strictObject({ communityId: uuid.nullable().optional() }),
  leaveCommunity: z.strictObject({ communityId: uuid }),
  changePhone: z.strictObject({ phone, code }),
  deleteAccount: empty,
};
export const otpRequest = z.strictObject({
  phone,
  captchaToken: z.string().max(4096).optional(),
});
export const otpVerify = z.strictObject({ phone, code, name });
export const refresh = z.strictObject({
  refreshToken: z.string().min(10).max(8192),
});
export const phoneChangeRequest = z.strictObject({ phone });
export const phoneChangeVerify = z.strictObject({ phone, code });
