import { admin } from "../../config/supabase.js";
import { env } from "../../config/environment.js";
import { check } from "../../lib/errors.js";

// All authenticated users may receive their own team invitations and updates.
export async function registerPush({ body, user }) {
  check(
    await admin
      .from("gameon_push_tokens")
      .upsert({ token: body.token, user_id: user.id }, { onConflict: "token" }),
  );
  return { registered: true };
}
export async function unregisterPush({ body, user }) {
  check(
    await admin
      .from("gameon_push_tokens")
      .delete()
      .eq("token", body.token)
      .eq("user_id", user.id),
  );
  return { removed: true };
}
export async function notifyUsers(userIds, message) {
  try {
    const recipients = [...new Set(userIds.filter(Boolean))];
    if (!recipients.length) return;
    const tokens = check(
      await admin
        .from("gameon_push_tokens")
        .select("token")
        .in("user_id", recipients),
    );
    for (let offset = 0; offset < tokens.length; offset += 100) {
      const batch = tokens.slice(offset, offset + 100);
      const response = await fetch("https://exp.host/--/api/v2/push/send", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(env.EXPO_ACCESS_TOKEN
            ? { Authorization: `Bearer ${env.EXPO_ACCESS_TOKEN}` }
            : {}),
        },
        body: JSON.stringify(
          batch.map(({ token }) => ({
            to: token,
            ...message,
            sound: "default",
            channelId: "join-requests",
            priority: "high",
          })),
        ),
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new Error("Push service unavailable");
      const result = await response.json();
      if (!Array.isArray(result.data)) throw new Error("Invalid push response");
      const invalid = result.data.flatMap((ticket, i) =>
        ticket.details?.error === "DeviceNotRegistered" && batch[i]
          ? [batch[i].token]
          : [],
      );
      if (invalid.length)
        check(
          await admin.from("gameon_push_tokens").delete().in("token", invalid),
        );
      if (result.data.some((ticket) => ticket.status === "error"))
        console.warn("GameOn push: some notifications were rejected.");
    }
  } catch {
    console.warn(
      "GameOn push delivery failed; saved requests remain available in the app.",
    );
  }
}
// Push delivery never rolls back a saved request.
export async function notifyAdmins() {
  try {
    const admins = check(await admin.from("gameon_admins").select("user_id"));
    await notifyUsers(
      admins.map((a) => a.user_id),
      {
        title: "New team join request",
        body: "A team is waiting for your approval. Open GameOn to review.",
        data: { type: "join-request" },
      },
    );
  } catch {
    console.warn(
      "GameOn admin push delivery failed; pending requests remain in the app.",
    );
  }
}
