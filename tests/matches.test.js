import test from "node:test";
import assert from "node:assert/strict";
process.env.PUBLIC_SUPABASE_URL = "https://example.supabase.co";
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-public-key";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-server-key-not-real-123456";
process.env.NODE_ENV = "test";
const { schemas } = await import("../src/routes/schemas.js");
const { admin } = await import("../src/config/supabase.js");
const { matchScore } = await import("../src/modules/matches/scoring.service.js");
const {
  cancelMatch,
  listConfirmedMatches,
  matchHeadToHead,
  matchConversation,
  matchInbox,
  requestMatch,
  reviewMatch,
  setMatchAvailability,
  touchMatchPresence,
  withdrawMatchRequest,
} = await import("../src/modules/matches/match.service.js");
const id = "b2bd2c31-b538-467d-87e7-d94fd815cb79";
const plan = {
  ballType: "Tennis ball",
  overs: [10, 16],
  schedule: [
    { date: "2099-11-09", time: "09:00" },
    { date: "2099-11-09", time: "11:30" },
  ],
  guestEmail: "captain@example.com",
  venue: { kind: "home" },
};

test("match payloads reject impersonation, invalid decisions and non-boolean availability", () => {
  assert.equal(
    schemas.requestMatch.safeParse({
      communityId: id,
      teamId: id,
      plan,
      actor: id,
    }).success,
    false,
  );
  assert.equal(
    schemas.requestMatch.safeParse({ communityId: id, teamId: "bad", plan })
      .success,
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

test("match challenges require a venue, supported ball and overs for each match", () => {
  const request = { communityId: id, teamId: id };
  assert.equal(schemas.requestMatch.safeParse(request).success, false);
  assert.deepEqual(
    schemas.requestMatch.parse({ ...request, plan }).plan.overs,
    [10, 16],
  );
  assert.equal(
    schemas.requestMatch.parse({
      ...request,
      plan: {
        ...plan,
        venue: { kind: "neutral", location: "  City oval  " },
      },
    }).plan.venue.location,
    "City oval",
  );

  for (const invalidPlan of [
    { ...plan, overs: [] },
    { ...plan, overs: [10, 51] },
    { ...plan, overs: [10.5] },
    { ...plan, overs: [1, 2, 3, 4, 5, 6] },
    { ...plan, ballType: "Golf ball" },
    { ...plan, schedule: plan.schedule.slice(0, 1) },
    { ...plan, schedule: [...plan.schedule].reverse() },
    { ...plan, schedule: [plan.schedule[0], plan.schedule[0]] },
    {
      ...plan,
      schedule: [{ date: "2020-01-01", time: "09:00" }, plan.schedule[1]],
    },
    {
      ...plan,
      schedule: [{ date: "2099-02-29", time: "09:00" }, plan.schedule[1]],
    },
    {
      ...plan,
      schedule: [{ ...plan.schedule[0], time: "25:00" }, plan.schedule[1]],
    },
    { ...plan, guestEmail: "not-an-email" },
    { ...plan, venue: { kind: "neutral", location: " " } },
    { ...plan, venue: { kind: "home", location: "Forged location" } },
  ])
    assert.equal(
      schemas.requestMatch.safeParse({ ...request, plan: invalidPlan }).success,
      false,
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
      [
        requestMatch,
        "request_with_plan",
        "This team is not available for a match.",
      ],
      [reviewMatch, "review", "Only the receiving captain can respond."],
      [
        setMatchAvailability,
        "availability",
        "Only a captain with a completed team can manage matches.",
      ],
    ]) {
      const body =
        service === requestMatch ? { communityId: id, teamId: id, plan } : {};
      admin.rpc = async (name, args) => {
        assert.equal(
          name,
          service === requestMatch
            ? "gameon_schedule_match"
            : service === reviewMatch
              ? "gameon_confirm_match"
              : "gameon_match_action",
        );
        assert.equal(args.actor, id);
        assert.equal(
          args.operation,
          service === setMatchAvailability ? operation : undefined,
        );
        assert.deepEqual(args.payload, body);
        return { error: { code: "P0001", message } };
      };
      await assert.rejects(
        service({ user: { id }, body }),
        (error) => error.status === 409 && error.message === message,
      );
    }
    admin.rpc = async () => ({ error: { code: "23505" } });
    await assert.rejects(
      requestMatch({ user: { id }, body: {} }),
      /already pending/,
    );
    admin.rpc = async () => ({
      error: { code: "P0001", message: "Unknown match operation." },
    });
    await assert.rejects(
      requestMatch({
        user: { id },
        body: { communityId: id, teamId: id, plan },
      }),
      {
        status: 503,
        message: /migration/,
      },
    );
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
  }
});

test("only the participating captains receive the plan, including both sets of overs", async () => {
  const { snapshot } =
    await import("../src/modules/snapshot/snapshot.service.js");
  const original = admin.from;
  const savedPlan = {
    ...plan,
    venue: { kind: "home", name: "City Oval", location: "Kovai" },
  };
  const tables = {
    gameon_profiles: [
      { id: "sender", role: "Captain", completed: true },
      { id: "receiver", role: "Captain", completed: true },
      { id: "player", role: "Player", completed: true },
    ],
    gameon_teams: [
      {
        id: "home",
        captain_id: "sender",
        has_ground: true,
        ground_name: "City Oval",
        ground_area: "Kovai",
      },
      { id: "away", captain_id: "receiver" },
    ],
    gameon_communities: [{ id: "club" }],
    gameon_memberships: [
      { community_id: "club", team_id: "home" },
      { community_id: "club", team_id: "away" },
    ],
    gameon_team_players: [{ team_id: "away", player_id: "player" }],
    gameon_match_requests: [
      {
        id: "new",
        community_id: "club",
        from_team_id: "home",
        to_team_id: "away",
        plan: savedPlan,
      },
      {
        id: "legacy",
        community_id: "club",
        from_team_id: "home",
        to_team_id: "away",
      },
    ],
  };
  admin.from = (table) => {
    let rows = tables[table] ?? [];
    const query = {
      select: () => query,
      range: () => query,
      order: () => query,
      eq: (key, value) => {
        rows = rows.filter((row) => row[key] === value);
        return query;
      },
      maybeSingle: async () => ({ data: rows[0] ?? null }),
      single: async () => ({ data: rows[0] }),
      then: (resolve, reject) =>
        Promise.resolve({ data: rows }).then(resolve, reject),
    };
    return query;
  };
  try {
    const recipient = await snapshot({ id: "receiver" });
    const request = recipient.matchRequests.find(({ id }) => id === "new");
    assert.equal(request.incoming, true);
    assert.deepEqual(request.plan, savedPlan);
    assert.equal(
      recipient.matchRequests.find(({ id }) => id === "legacy").plan,
      null,
    );
    assert.equal(
      recipient.membersByCommunity.club.find(({ id }) => id === "home")
        .groundArea,
      "Kovai",
    );

    const player = await snapshot({ id: "player" });
    assert.deepEqual(player.matchRequests, []);
    assert.equal(
      player.membersByCommunity.club.find(({ id }) => id === "home").groundArea,
      undefined,
    );
  } finally {
    admin.from = original;
  }
});

test("conversation payloads require authenticated actor and validate structured edits", async () => {
  const { ballType, overs, schedule } = plan;
  const propose = {
    operation: "propose",
    requestId: id,
    version: 0,
    changes: { ballType, overs, schedule },
  };
  assert.equal(schemas.matchConversation.safeParse(propose).success, true);
  assert.equal(
    schemas.matchConversation.safeParse({ ...propose, actor: id }).success,
    false,
  );
  assert.equal(
    schemas.matchConversation.safeParse({
      ...propose,
      changes: { ballType, overs, schedule, venue: {} },
    }).success,
    false,
  );
  assert.equal(
    schemas.matchConversation.safeParse({
      operation: "message",
      requestId: id,
      message: " ",
    }).success,
    false,
  );

  const originalFrom = admin.from;
  const originalRpc = admin.rpc;
  admin.from = () => ({
    select: () => ({
      eq: () => ({ maybeSingle: async () => ({ data: null }) }),
    }),
  });
  try {
    admin.rpc = async (name, args) => {
      assert.equal(name, "gameon_match_chat_status");
      assert.equal(args.actor, id);
      assert.equal(args.operation, "propose");
      assert.deepEqual(args.payload, {
        requestId: id,
        version: 0,
        changes: propose.changes,
      });
      return {
        error: {
          code: "P0001",
          message: "Only the two captains can open this match conversation.",
        },
      };
    };
    await assert.rejects(matchConversation({ user: { id }, body: propose }), {
      status: 403,
    });
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
  }
});

test("confirmation targets the challenger and all community members and survives a push delivery failure", async () => {
  const originalFrom = admin.from;
  const originalRpc = admin.rpc;
  const originalFetch = globalThis.fetch;
  const pushed = [];
  const targets = [];
  admin.from = (table) => {
    const query = {
      select: () => query,
      eq: () => query,
      order: () => query,
      range: () => query,
      in: (_column, users) => {
        assert.equal(table, "gameon_push_tokens");
        targets.push(users);
        return Promise.resolve({ data: [{ token: "ExpoPushToken[fixture]" }] });
      },
      maybeSingle: async () => ({ data: null }),
      single: async () => ({ data: { role: "Captain", completed: true } }),
      then: (resolve, reject) =>
        Promise.resolve({ data: [] }).then(resolve, reject),
    };
    return query;
  };
  admin.rpc = async (name, args) => {
    assert.equal(name, "gameon_confirm_match");
    assert.equal(args.actor, id);
    assert.deepEqual(args.payload, { requestId: id, decision: "accepted" });
    return {
      data: {
        notifyUser: "challenger",
        recipientIds: ["challenger", "teammate", "other-club-player"],
        fixture: {
          communityName: "Kovai Cricket",
          fromTeam: "Falcons",
          toTeam: "Knights",
          plan,
        },
      },
    };
  };
  globalThis.fetch = async (_url, options) => {
    pushed.push(JSON.parse(options.body)[0]);
    return { ok: false };
  };
  try {
    const result = await reviewMatch({
      user: { id },
      body: { requestId: id, decision: "accepted" },
    });
    assert.ok(result.snapshot);
    assert.deepEqual(targets, [
      ["challenger"],
      ["teammate", "other-club-player"],
    ]);
    assert.equal(pushed[0].title, "Match confirmed · Kovai Cricket");
    assert.match(pushed[0].body, /Falcons vs Knights.*09:00 IST.*Tennis ball/);
    assert.deepEqual(pushed[0].data, {
      type: "match-confirmed",
      requestId: id,
    });
    assert.deepEqual(pushed[1].data, {
      type: "team-match-confirmed",
      matchId: id,
    });
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
    globalThis.fetch = originalFetch;
  }
});

test("captain inbox is scoped to the authenticated user and chat push names the sender and club", async () => {
  const originalFrom = admin.from;
  const originalRpc = admin.rpc;
  const originalFetch = globalThis.fetch;
  let push;
  const unreadThread = {
    requestId: id,
    communityName: "Kovai Cricket",
    captainName: "Adithya",
    unread: 2,
  };
  admin.from = (table) => ({
    select: () => ({
      eq: () => ({ maybeSingle: async () => ({ data: null }) }),
      in: async (_field, recipients) => {
        assert.equal(table, "gameon_push_tokens");
        assert.deepEqual(recipients, ["opponent"]);
        return { data: [{ token: "ExpoPushToken[fixture]" }] };
      },
    }),
  });
  admin.rpc = async (rpc, args) => {
    assert.equal(args.actor, id);
    if (rpc === "gameon_match_inbox") return { data: [unreadThread] };
    assert.equal(rpc, "gameon_match_chat_status");
    assert.equal(args.operation, "message");
    assert.deepEqual(args.payload, { requestId: id, message: "10 overs?" });
    return {
      data: {
        messages: [{ id, readByOpponent: true }],
        notifyUser: "opponent",
        senderName: "Adithya",
        communityName: "Kovai Cricket",
        opponentLastSeenAt: "2026-11-09T05:11:00Z",
        opponentOnline: true,
      },
    };
  };
  globalThis.fetch = async (_url, options) => {
    push = JSON.parse(options.body)[0];
    return { ok: true, json: async () => ({ data: [{ status: "ok" }] }) };
  };
  try {
    assert.deepEqual(await matchInbox({ user: { id } }), {
      threads: [unreadThread],
    });
    const thread = await matchConversation({
      user: { id },
      body: { operation: "message", requestId: id, message: "10 overs?" },
    });
    assert.equal(thread.notifyUser, undefined);
    assert.equal(thread.senderName, undefined);
    assert.equal(thread.messages[0].readByOpponent, true);
    assert.equal(thread.opponentLastSeenAt, "2026-11-09T05:11:00Z");
    assert.equal(thread.opponentOnline, true);
    assert.equal(push.title, "Adithya · Kovai Cricket");
    assert.equal(push.body, "10 overs?");
    assert.deepEqual(push.data, { type: "match-chat-message", requestId: id });
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
    globalThis.fetch = originalFetch;
  }
});

test("presence records only the authenticated actor with no client-supplied identity or time", async () => {
  assert.equal(schemas.touchMatchPresence.safeParse({}).success, true);
  assert.equal(
    schemas.touchMatchPresence.safeParse({
      actor: id,
      lastActiveAt: "2099-11-09",
    }).success,
    false,
  );
  const originalRpc = admin.rpc;
  admin.rpc = async (name, args) => {
    assert.equal(name, "gameon_touch_match_presence");
    assert.deepEqual(args, { actor: id });
    return { data: null, error: null };
  };
  try {
    assert.deepEqual(await touchMatchPresence({ user: { id } }), {
      recorded: true,
    });
  } finally {
    admin.rpc = originalRpc;
  }
});

test("confirmed fixtures are fetched for the authenticated club member", async () => {
  assert.equal(schemas.listConfirmedMatches.safeParse({}).success, true);
  assert.equal(
    schemas.listConfirmedMatches.safeParse({ actor: id }).success,
    false,
  );
  const originalRpc = admin.rpc;
  const matches = [{ id, fromTeam: "Falcons", toTeam: "Knights" }];
  admin.rpc = async (name, args) => {
    assert.equal(name, "gameon_list_confirmed_matches");
    assert.deepEqual(args, { actor: id });
    return { data: matches };
  };
  try {
    assert.deepEqual(await listConfirmedMatches({ user: { id } }), { matches });
  } finally {
    admin.rpc = originalRpc;
  }
});

test("cancellation requires a reason and the RPC receives only the authenticated captain", async () => {
  assert.deepEqual(
    schemas.cancelMatch.parse({
      requestId: id,
      reason: "  Ground unavailable  ",
    }),
    { requestId: id, reason: "Ground unavailable" },
  );
  for (const body of [
    { requestId: id, reason: " " },
    { requestId: id, reason: "x".repeat(501) },
    { requestId: id, reason: "Ground unavailable", actor: id },
  ])
    assert.equal(schemas.cancelMatch.safeParse(body).success, false);

  const originalRpc = admin.rpc;
  const body = { requestId: id, reason: "Ground unavailable" };
  admin.rpc = async (name, args) => {
    assert.equal(name, "gameon_cancel_match");
    assert.deepEqual(args, { actor: id, payload: body });
    return {
      error: {
        code: "P0001",
        message: "Only either team captain can cancel this match.",
      },
    };
  };
  try {
    await assert.rejects(cancelMatch({ user: { id }, body }), { status: 403 });
    admin.rpc = async () => ({
      error: {
        code: "P0001",
        message: "Only a confirmed match can be cancelled.",
      },
    });
    await assert.rejects(cancelMatch({ user: { id }, body }), { status: 409 });
  } finally {
    admin.rpc = originalRpc;
  }
});

test("withdrawal scopes the RPC to the sender and surfaces closed challenges", async (t) => {
  const body = { requestId: id };
  assert.deepEqual(schemas.withdrawMatchRequest.parse(body), body);
  assert.equal(schemas.withdrawMatchRequest.safeParse({ ...body, actor: id }).success, false);
  assert.equal(schemas.withdrawMatchRequest.safeParse({ requestId: "invalid" }).success, false);

  const actor = "19fa4765-5d11-44c6-aac4-668352842e31";
  const rpc = t.mock.method(admin, "rpc");
  for (const [status, message] of [
    [403, "Only the captain who sent the challenge can withdraw it."],
    [409, "Only a pending challenge can be withdrawn."],
  ]) {
    rpc.mock.mockImplementationOnce(async (name, args) => {
      assert.equal(name, "gameon_withdraw_match_request");
      assert.deepEqual(args, { actor, request_id: id });
      return { error: { code: "P0001", message } };
    });
    await assert.rejects(withdrawMatchRequest({ user: { id: actor }, body }), { status, message });
  }
  assert.equal(rpc.mock.callCount(), 2);
});

test("saved playing XIs receive profile details without exposing the opposing roster", async (t) => {
  const state = {
    innings: [{ teamId: "home" }],
    lineups: {
      home: [{ id, name: "Home captain" }],
      away: [{ id: "away-batter", name: "Away batter" }],
    },
  };
  t.mock.method(admin, "rpc", async (name, args) => {
    if (name === "gameon_touch_score_viewer") {
      assert.deepEqual(args, { actor: id, fixture_id: id, slot_index: 0 });
      return { data: 3 };
    }
    assert.equal(name, "gameon_read_match_score");
    assert.deepEqual(args, { actor: id, fixture_id: id, slot_index: 0 });
    return { data: {
      ownTeamId: "home", isCaptain: true, overs: 10, revision: 3, state,
      teams: [
        { id: "home", name: "Home", captainId: id, roster: [{ id, name: "Home captain", jerseyNumber: 0, cricketRole: "All-rounder" }] },
        { id: "away", name: "Away", captainId: "away-batter", roster: [{ id: "away-batter", name: "Away batter", jerseyNumber: 27, cricketRole: "Wicketkeeper-batsman" }] },
      ],
    } };
  });
  const score = await matchScore({
    user: { id },
    body: { requestId: id, matchIndex: 0, operation: "read" },
  });
  assert.equal(score.state.lineups.home[0].jerseyNumber, 0);
  assert.equal(score.state.lineups.away[0].jerseyNumber, 27);
  assert.equal(score.state.lineups.home[0].cricketRole, "All-rounder");
  assert.equal(score.state.lineups.away[0].cricketRole, "Wicketkeeper-batsman");
  assert.deepEqual(score.teams[1], {
    id: "away", name: "Away", captainId: "away-batter", captainName: "Away batter",
  });
  assert.equal(score.teams[0].captainId, id);
  assert.equal(score.teams[0].captainName, "Home captain");
  assert.equal(score.viewerCount, 3);
  assert.equal(state.lineups.home[0].jerseyNumber, undefined);
});

test("club spectators can view a started scorecard but cannot update it", async (t) => {
  const state = {
    innings: [{ teamId: "home" }],
    lineups: { home: [], away: [] },
    scorers: { home: id },
  };
  const rpc = t.mock.method(admin, "rpc", async (name) => {
    if (name === "gameon_touch_score_viewer") return { data: 2 };
    assert.equal(name, "gameon_read_match_score");
    return { data: {
      ownTeamId: null, isCaptain: false, overs: 10, revision: 3, state,
      teams: [
        { id: "home", name: "Home", captainId: "home-captain", roster: [] },
        { id: "away", name: "Away", captainId: "away-captain", roster: [] },
      ],
    } };
  });
  const request = { user: { id }, body: { requestId: id, matchIndex: 0, operation: "read" } };
  const score = await matchScore(request);
  assert.deepEqual(score.state.innings, state.innings);
  assert.deepEqual(score.teams, [
    { id: "home", name: "Home", captainId: "home-captain", captainName: null },
    { id: "away", name: "Away", captainId: "away-captain", captainName: null },
  ]);
  assert.equal(score.access.canScore, false);
  assert.equal(score.access.canAdvance, false);
  assert.equal(score.viewerCount, 2);
  await assert.rejects(matchScore({
    ...request,
    body: { ...request.body, operation: "update", revision: 3, change: { kind: "undo" } },
  }), { status: 403 });
  assert.equal(rpc.mock.callCount(), 4);
});

test("head-to-head uses the authenticated captain and rejects unauthorized matchups", async (t) => {
  const body = { communityId: id, teamId: id };
  const history = { played: 2, ownWins: 1, opponentWins: 0, ties: 1, lastMeeting: null };
  assert.equal(schemas.matchHeadToHead.safeParse(body).success, true);
  assert.equal(schemas.matchHeadToHead.safeParse({ ...body, actor: id }).success, false);
  let allowed = true;
  t.mock.method(admin, "rpc", async (name, args) => {
    assert.equal(name, "gameon_match_head_to_head");
    assert.deepEqual(args, { actor: id, club_id: body.communityId, opponent_id: body.teamId });
    return allowed ? { data: history } : { error: { code: "42501", message: "Club captain required." } };
  });
  const context = { user: { id }, body };
  assert.deepEqual(await matchHeadToHead(context), history);
  allowed = false;
  await assert.rejects(matchHeadToHead(context), { status: 403 });
});
