import test from "node:test";
import assert from "node:assert/strict";
process.env.PUBLIC_SUPABASE_URL = "https://example.supabase.co";
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = "test-public-key";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-server-key-not-real-123456";
process.env.NODE_ENV = "test";
const { schemas } = await import("../src/routes/schemas.js");
const { admin } = await import("../src/config/supabase.js");
const { inviteTeamPlayer, requestTeamJoin, reviewTeamPlayer, searchPlayers } =
  await import("../src/modules/teams/team-players.service.js");
const id = "b2bd2c31-b538-467d-87e7-d94fd815cb79";

test("player-team schemas reject spoofed senders, malformed IDs and invalid approval", () => {
  assert.equal(
    schemas.inviteTeamPlayer.safeParse({
      teamId: id,
      playerId: id,
      captainId: id,
    }).success,
    false,
  );
  assert.equal(
    schemas.requestTeamJoin.safeParse({ teamId: id, playerId: id }).success,
    false,
  );
  assert.equal(
    schemas.reviewTeamPlayer.safeParse({ requestId: id, decision: "approved" })
      .success,
    false,
  );
  assert.equal(
    schemas.inviteTeamPlayer.safeParse({ teamId: id, playerId: "bad" }).success,
    false,
  );
  assert.equal(schemas.requestTeamJoin.safeParse({ teamId: id }).success, true);
  assert.equal(schemas.searchPlayers.safeParse({ query: "a" }).success, false);
  assert.equal(
    schemas.saveTeam.safeParse({
      values: { name: "My XI", description: "x".repeat(601), hasGround: false },
    }).success,
    false,
  );
  assert.equal(
    schemas.saveTeam.safeParse({
      values: {
        name: "My XI",
        description: "Weekend cricket team",
        hasGround: false,
      },
    }).success,
    true,
  );
});

test("team operations pass authenticated actor and reject unauthorized/stale requests before notifications", async () => {
  const originalFrom = admin.from,
    originalRpc = admin.rpc;
  admin.from = () => ({
    select: () => ({
      eq: () => ({ maybeSingle: async () => ({ data: null }) }),
    }),
  });
  try {
    for (const [service, operation, message] of [
      [inviteTeamPlayer, "invite", "Only the team captain can invite players."],
      [
        requestTeamJoin,
        "join",
        "Only a completed player profile can join a team.",
      ],
      [
        reviewTeamPlayer,
        "review",
        "Only the recipient can answer this request.",
      ],
    ]) {
      admin.rpc = async (name, args) => {
        assert.equal(name, "gameon_team_player_action");
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
      requestTeamJoin({ user: { id }, body: { teamId: id } }),
      /pending request/,
    );
    admin.from = () => ({
      select: () => ({
        eq: () => ({ maybeSingle: async () => ({ data: { user_id: id } }) }),
      }),
    });
    await assert.rejects(
      inviteTeamPlayer({ user: { id }, body: {} }),
      (error) => error.status === 403,
    );
  } finally {
    admin.from = originalFrom;
    admin.rpc = originalRpc;
  }
});

test("non-captains cannot search the player directory", async () => {
  const original = admin.from;
  admin.from = (table) => ({
    select: () => ({
      eq: () => ({
        maybeSingle: async () => ({ data: null }),
        single: async () => ({ data: { role: "Player", completed: true } }),
      }),
    }),
  });
  try {
    await assert.rejects(
      searchPlayers({ user: { id }, body: { query: "Shahid" } }),
      (error) => error.status === 403,
    );
  } finally {
    admin.from = original;
  }
});

const { snapshot } =
  await import("../src/modules/snapshot/snapshot.service.js");
test("accepted players see their roster and team communities; other rosters and requests stay private", async () => {
  const original = admin.from;
  const tables = {
    gameon_admins: [],
    gameon_profiles: [
      {
        id: "player",
        name: "Player One",
        role: "Player",
        completed: true,
        phone: "9000000000",
      },
      { id: "captain", name: "Captain One", role: "Captain", completed: true },
      { id: "other", name: "Other Player", role: "Player", completed: true },
    ],
    gameon_teams: [
      {
        id: "team",
        captain_id: "captain",
        name: "Kovai XI",
        description: "Weekend cricket",
      },
      { id: "private", captain_id: "other", name: "Other XI" },
    ],
    gameon_team_players: [
      { team_id: "team", player_id: "player" },
      { team_id: "private", player_id: "other" },
    ],
    gameon_team_player_requests: [
      {
        id: "mine",
        team_id: "team",
        player_id: "player",
        kind: "invite",
        status: "accepted",
        created_at: "2026-11-06",
      },
      {
        id: "private",
        team_id: "private",
        player_id: "other",
        kind: "join",
        status: "pending",
        created_at: "2026-11-06",
      },
    ],
    gameon_memberships: [{ team_id: "team", community_id: "community" }],
    gameon_communities: [
      { id: "community", name: "Coimbatore cricket", location: "Coimbatore" },
    ],
    gameon_join_requests: [],
  };
  admin.from = (table) => {
    let data = [...(tables[table] || [])];
    const query = {
      select: () => query,
      order: () => query,
      range: () => query,
      eq: (key, value) => {
        data = data.filter((row) => row[key] === value);
        return query;
      },
      maybeSingle: async () => ({ data: data[0] || null }),
      single: async () => ({ data: data[0] }),
      then: (resolve, reject) =>
        Promise.resolve({ data }).then(resolve, reject),
    };
    return query;
  };
  try {
    const result = await snapshot({ id: "player" });
    assert.deepEqual(result.joined, ["community"]);
    assert.equal(result.myTeams.length, 1);
    assert.equal(result.myTeams[0].id, "team");
    assert.deepEqual(
      result.myTeams[0].roster.map(({ name, role }) => ({ name, role })),
      [
        { name: "Captain One", role: "Captain" },
        { name: "Player One", role: "Player" },
      ],
    );
    assert.equal(result.teamPlayerRequests.length, 1);
    assert.equal(result.teamPlayerRequests[0].id, "mine");
    assert.equal(result.membersByCommunity.community.length, 1);
    assert.equal(JSON.stringify(result.myTeams).includes("9000000000"), false);
    assert.equal(
      result.myTeams.some((team) => team.id === "private"),
      false,
    );
    tables.gameon_team_players = [{ team_id: 'private', player_id: 'other' }];
    tables.gameon_team_player_requests[0].status = 'pending';
    const pending = await snapshot({ id: 'player' });
    assert.deepEqual(pending.myTeams, []);
    assert.deepEqual(pending.joined, []);
    assert.equal(pending.membersByCommunity.community, undefined);
    assert.equal(pending.teamPlayerRequests[0].incoming, true);
    assert.equal(pending.teamPlayerRequests[0].playerProfile, null);
    const captainView = await snapshot({ id: 'captain' });
    const preview = captainView.teamPlayerRequests.find((request) => request.id === 'mine').playerProfile;
    assert.equal(preview.id, 'player');
    assert.equal(preview.name, 'Player One');
    assert.equal(Object.hasOwn(preview, 'phone'), false);
    assert.equal(Object.hasOwn(preview, 'email'), false);
    assert.equal(captainView.myTeams[0].roster.length, 1);

  } finally {
    admin.from = original;
  }
});

test('admin accounts in Player mode reach normal team join and invitation review validation', async () => {
  const originalFrom=admin.from, originalRpc=admin.rpc;
  admin.from=()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:{user_id:id}})})})});
  try {
    for (const [service, operation] of [[requestTeamJoin,'join'],[reviewTeamPlayer,'review']]) {
      admin.rpc=async(name,args)=>{
        assert.equal(name,'gameon_team_player_action');
        assert.equal(args.actor,id);assert.equal(args.operation,operation);
        return {error:{code:'P0001',message:'Database role and recipient validation reached'}};
      };
      await assert.rejects(service({user:{id},body:{}}), /Database role and recipient validation reached/);
    }
  } finally {admin.from=originalFrom;admin.rpc=originalRpc;}
});
