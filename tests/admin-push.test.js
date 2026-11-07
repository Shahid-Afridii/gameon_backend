import test from "node:test";
import assert from "node:assert/strict";
process.env.PUBLIC_SUPABASE_URL = "https://example.supabase.co";
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-public-key";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-server-key-not-real-123456";
process.env.NODE_ENV = "test";
process.env.GAMEON_TEST_LOGIN_ENABLED = "false";
const { admin } = await import("../src/config/supabase.js");
const { notifyAdmins, notifyUsers, registerPush, unregisterPush } =
  await import("../src/modules/notifications/push.service.js");
const { schemas } = await import("../src/routes/schemas.js");
test("admin push authorization, delivery and failure isolation", async () => {
  const original = admin.from;
  const originalFetch = globalThis.fetch;
  const originalWarn = console.warn;
  let calls = 0;
  try {
    let registration;
    admin.from = (table) => {
      assert.equal(table, "gameon_push_tokens");
      return {
        upsert: async (row) => {
          registration = row;
          return { error: null };
        },
      };
    };
    await registerPush({
      body: { token: "ExpoPushToken[example]" },
      user: { id: "player" },
    });
    assert.deepEqual(registration, {
      token: "ExpoPushToken[example]",
      user_id: "player",
    });
    assert.equal(
      schemas.registerPush.safeParse({ token: "invalid" }).success,
      false,
    );
    admin.from = () => ({ select: async () => ({ data: [] }) });
    globalThis.fetch = async () => {
      calls++;
      throw new Error("unexpected");
    };
    await notifyAdmins();
    assert.equal(calls, 0);
    let deleted;
    admin.from = (table) =>
      table === "gameon_admins"
        ? { select: async () => ({ data: [{ user_id: "admin" }] }) }
        : {
            select: () => ({
              in: async () => ({ data: [{ token: "ExpoPushToken[example]" }] }),
            }),
            delete: () => ({
              in: async (column, values) => {
                deleted = values;
                return { error: null };
              },
            }),
          };
    globalThis.fetch = async (url, options) => {
      assert.equal(url, "https://exp.host/--/api/v2/push/send");
      const [message] = JSON.parse(options.body);
      assert.equal(message.data.type, "join-request");
      assert.equal(message.channelId, "join-requests");
      return {
        ok: true,
        json: async () => ({
          data: [
            { status: "error", details: { error: "DeviceNotRegistered" } },
          ],
        }),
      };
    };
    console.warn = () => {};
    await notifyAdmins();
    assert.deepEqual(deleted, ["ExpoPushToken[example]"]);
    globalThis.fetch = async () => {
      throw new Error("offline");
    };
    await assert.doesNotReject(notifyAdmins());
    let recipients;
    admin.from = () => ({
      select: () => ({
        in: async (key, ids) => {
          recipients = ids;
          return { data: [{ token: "ExpoPushToken[player]" }] };
        },
      }),
    });
    globalThis.fetch = async (url, options) => {
      const [message] = JSON.parse(options.body);
      assert.equal(message.data.type, "team-player-request");
      assert.equal(message.to, "ExpoPushToken[player]");
      return { ok: true, json: async () => ({ data: [{ status: "ok" }] }) };
    };
    await notifyUsers(["recipient", "recipient"], {
      title: "Invitation",
      body: "Join team",
      data: { type: "team-player-request" },
    });
    assert.deepEqual(recipients, ["recipient"]);
    const filters = [];
    admin.from = () => ({
      delete: () => ({
        eq: (k, v) => {
          filters.push([k, v]);
          return {
            eq: async (k, v) => {
              filters.push([k, v]);
              return { error: null };
            },
          };
        },
      }),
    });
    await unregisterPush({
      body: { token: "ExpoPushToken[example]" },
      user: { id: "owner" },
    });
    assert.deepEqual(filters, [
      ["token", "ExpoPushToken[example]"],
      ["user_id", "owner"],
    ]);
  } finally {
    admin.from = original;
    globalThis.fetch = originalFetch;
    console.warn = originalWarn;
  }
});
