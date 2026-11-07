import test from "node:test";
import assert from "node:assert/strict";
process.env.PUBLIC_SUPABASE_URL = "https://example.supabase.co";
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-public-key";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-server-key-not-real-123456";
process.env.NODE_ENV = "test";
const { schemas } = await import("../src/routes/schemas.js");
const { admin } = await import("../src/config/supabase.js");
const { requestMatch, reviewMatch, setMatchAvailability } =
  await import("../src/modules/matches/match.service.js");
const id = "b2bd2c31-b538-467d-87e7-d94fd815cb79";

test("match payloads reject impersonation, invalid decisions and non-boolean availability", () => {
  assert.equal(
    schemas.requestMatch.safeParse({ communityId: id, teamId: id, actor: id })
      .success,
    false,
  );
  assert.equal(
    schemas.requestMatch.safeParse({ communityId: id, teamId: "bad" }).success,
    false,
  );
  assert.equal(
    schemas.setMatchAvailability.safeParse({ available: "false" }).success,
    false,
  );
  assert.equal(
    schemas.setMatchAvailability.safeParse({ available: false }).success,
    true,
  );
  assert.equal(
    schemas.reviewMatch.safeParse({ requestId: id, decision: "approved" })
      .success,
    false,
  );
  assert.equal(
    schemas.reviewMatch.safeParse({ requestId: id, decision: "accepted" })
      .success,
    true,
  );
});

test("superadmin cannot change availability or send/respond to match requests", async () => {
  const original = admin.from;
  admin.from = () => ({
    select: () => ({
      eq: () => ({ maybeSingle: async () => ({ data: { id }, error: null }) }),
    }),
  });
  try {
    for (const service of [requestMatch, reviewMatch, setMatchAvailability]) {
      await assert.rejects(
        service({ user: { id }, body: {} }),
        (error) => error.status === 403,
      );
    }
  } finally {
    admin.from = original;
  }
});

test("match operation uses authenticated actor and surfaces stale availability/ownership rejection", async () => {
  const originalFrom = admin.from,
    originalRpc = admin.rpc;
  admin.from = () => ({
    select: () => ({
      eq: () => ({ maybeSingle: async () => ({ data: null, error: null }) }),
    }),
  });
  try {
    for (const [service, operation, message] of [
      [requestMatch, "request", "This team is not available for a match."],
      [reviewMatch, "review", "Only the receiving captain can respond."],
      [
        setMatchAvailability,
        "availability",
        "Only a captain with a completed team can manage matches.",
      ],
    ]) {
      admin.rpc = async (name, args) => {
        assert.equal(name, "gameon_match_action");
        assert.equal(args.actor, id);
        assert.equal(args.operation, operation);
        return { error: { code: "P0001", message } };
      };
      await assert.rejects(
        service({ user: { id }, body: {} }),
        (error) => error.status === 409 && error.message === message,
      );
    }
    admin.rpc = async () => ({ error: { code: "23505" } });
    await assert.rejects(
      requestMatch({ user: { id }, body: {} }),
      /already pending/,
    );
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
  }
});
