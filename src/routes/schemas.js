import { z } from "zod/v4";
const name = z.string().trim().min(2).max(60);
const phone = z.string().min(10).max(20);
const code = z.string().regex(/^\d{4,8}$/);
const uuid = z.uuid();
const empty = z.strictObject({});
const optionalText = (max) => z.string().trim().max(max).default("");
const pushToken = z
  .string()
  .min(20)
  .max(300)
  .regex(/^(ExpoPushToken|ExponentPushToken)\[[A-Za-z0-9_-]+\]$/);
export const schemas = {
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
  setMatchAvailability: z.strictObject({ available: z.boolean() }),
  requestMatch: z.strictObject({ communityId: uuid, teamId: uuid }),
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
        .array(
          z.enum([
            "Stitch ball",
            "Tennis ball",
            "Cork ball",
            "Soft tennis ball",
          ]),
        )
        .max(4)
        .refine((items) => new Set(items).size === items.length)
        .optional(),
      ballType: z
        .enum(["Stitch ball", "Tennis ball", "Cork ball", "Soft tennis ball"])
        .nullable()
        .default(null),
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
