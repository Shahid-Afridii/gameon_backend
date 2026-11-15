import { admin } from "../../config/supabase.js";
import { check } from "../../lib/errors.js";
import { isAdmin } from "../auth/permissions.js";
import { readAll } from "../../lib/read-all.js";
export async function snapshot(user) {
  const privileged = await isAdmin(user.id);
  const profile = check(
    await admin.from("gameon_profiles").select("*").eq("id", user.id).single(),
  );
  const [
    communitiesResult,
    teamsResult,
    requestsResult,
    membershipsResult,
    profilesResult,
  ] = await Promise.all([
    readAll("gameon_communities", "*", "id"),
    readAll("gameon_teams", "*", "id"),
    privileged
      ? readAll("gameon_join_requests", "*", "id")
      : readAll("gameon_join_requests", "*", "id", { captain_id: user.id }),
    readAll("gameon_memberships", "*", "team_id"),
    readAll(
      "gameon_profiles",
      "id,name,role,cricket_role,jersey_number,ball_types,ball_type",
      "id",
    ),
  ]);
  const communities = check(communitiesResult),
    teams = check(teamsResult),
    requests = check(requestsResult),
    memberships = check(membershipsResult),
    profiles = check(profilesResult);
  const ownTeam = teams.find((t) => t.captain_id === user.id);
  const matchResults = ownTeam
    ? await Promise.all([
        readAll("gameon_match_requests", "*", "id", {
          from_team_id: ownTeam.id,
        }),
        readAll("gameon_match_requests", "*", "id", { to_team_id: ownTeam.id }),
      ])
    : [];
  const matchRequests = matchResults
    .flatMap((result) => check(result))
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  const teamPlayers = check(
    await readAll("gameon_team_players", "*", "team_id"),
  );
  const playerTeamIds = teamPlayers
    .filter((row) => row.player_id === user.id)
    .map((row) => row.team_id);
  const myTeamIds = new Set([
    ...(ownTeam ? [ownTeam.id] : []),
    ...playerTeamIds,
  ]);
  const visiblePolls = check(await readAll('gameon_team_polls', 'id,team_id,closes_at', 'id'));
  const openPollCount = visiblePolls.filter(poll =>
    (privileged || myTeamIds.has(poll.team_id)) && Date.parse(poll.closes_at) > Date.now()
  ).length;
  const playerRequestResults = await Promise.all([
    readAll("gameon_team_player_requests", "*", "id", { player_id: user.id }),
    ...(ownTeam
      ? [
          readAll("gameon_team_player_requests", "*", "id", {
            team_id: ownTeam.id,
          }),
        ]
      : []),
  ]);
  const playerRequests = [
    ...new Map(
      playerRequestResults
        .flatMap((result) => check(result))
        .map((r) => [r.id, r]),
    ).values(),
  ].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  const joined = [
    ...new Set(
      memberships
        .filter((m) => myTeamIds.has(m.team_id))
        .map((m) => m.community_id),
    ),
  ];
  const teamSummary = (t) => ({
    id: t.id,
    name: t.name,
    description: t.description || "",
    captainName: profiles.find((p) => p.id === t.captain_id)?.name || "Captain",
    hasGround: t.has_ground === true,
    matchAvailable: t.match_available === true,
    playerCount: teamPlayers.filter((row) => row.team_id === t.id).length,
  });
  const memberCounts = {},
    membersByCommunity = {};
  for (const community of communities) {
    const admitted = memberships.filter((m) => m.community_id === community.id);
    const canPlanMatch =
      !privileged &&
      profile.role === "Captain" &&
      profile.completed &&
      admitted.some((m) => m.team_id === ownTeam?.id);
    memberCounts[community.id] = admitted.length;
    if (privileged || joined.includes(community.id))
      membersByCommunity[community.id] = admitted.map((m) => {
        const team = teams.find((t) => t.id === m.team_id),
          captain = profiles.find((p) => p.id === team?.captain_id);
        return {
          id: m.team_id,
          name: captain?.name || "Captain",
          role: "Captain",
          team: team?.name || "Team",
          isYou: team?.captain_id === user.id,
          matchAvailable: team?.match_available === true,
          hasGround: team?.has_ground === true,
          ...(canPlanMatch && team?.has_ground && {
            groundName: team.ground_name,
            groundArea: team.ground_area,
          }),
        };
      });
  }
  return {
    openPollCount,
    session: {
      id: user.id,
      phone: profile.phone,
      name: profile.name,
      role: privileged ? "superadmin" : "user",
    },
    profile: {
      ...profile,
      cricketRole: profile.cricket_role || null,
      jerseyNumber: profile.jersey_number ?? null,
      ballType: profile.ball_type || null,
      ballTypes:
        profile.ball_types ?? (profile.ball_type ? [profile.ball_type] : []),
      email: profile.email || "",
      teamName: ownTeam?.name || profile.team_name || "",
    },
    team: ownTeam
      ? {
          id: ownTeam.id,
          name: ownTeam.name,
          description: ownTeam.description || "",
          matchAvailable: ownTeam.match_available === true,
          hasGround: ownTeam.has_ground,
          groundName: ownTeam.ground_name,
          groundArea: ownTeam.ground_area,
          amenities: ownTeam.amenities,
        }
      : null,
    matchRequests: matchRequests.map((r) => ({
      id: r.id,
      communityId: r.community_id,
      fromTeamId: r.from_team_id,
      toTeamId: r.to_team_id,
      fromTeam: teams.find((t) => t.id === r.from_team_id)?.name || "Team",
      toTeam: teams.find((t) => t.id === r.to_team_id)?.name || "Team",
      incoming: r.to_team_id === ownTeam?.id,
      status: r.status,
      createdAt: r.created_at,
      plan: r.plan ?? null,
      cancellation: r.cancellation ?? null,
      hasProposal: Boolean(r.proposal),
    })),
    joined,
    memberCounts,
    membersByCommunity,
    availableTeams: teams.map((t) => ({ name: t.name })),
    teamDirectory: teams.map(teamSummary),
    myTeams: teams
      .filter((t) => myTeamIds.has(t.id))
      .map((t) => ({
        ...teamSummary(t),
        isCaptain: t.captain_id === user.id,
        roster: [
          {
            id: t.captain_id,
            name:
              profiles.find((p) => p.id === t.captain_id)?.name || "Captain",
            role: "Captain",
            cricketRole:
              profiles.find((p) => p.id === t.captain_id)?.cricket_role || null,
            jerseyNumber:
              profiles.find((p) => p.id === t.captain_id)?.jersey_number ??
              null,
            ballTypes:
              profiles.find((p) => p.id === t.captain_id)?.ball_types ??
              (profiles.find((p) => p.id === t.captain_id)?.ball_type
                ? [profiles.find((p) => p.id === t.captain_id).ball_type]
                : []),
            isYou: t.captain_id === user.id,
          },
          ...teamPlayers
            .filter((row) => row.team_id === t.id)
            .map((row) => ({
              id: row.player_id,
              name:
                profiles.find((p) => p.id === row.player_id)?.name || "Player",
              role: "Player",
              cricketRole:
                profiles.find((p) => p.id === row.player_id)?.cricket_role ||
                null,
              jerseyNumber:
                profiles.find((p) => p.id === row.player_id)?.jersey_number ??
                null,
              ballTypes:
                profiles.find((p) => p.id === row.player_id)?.ball_types ??
                (profiles.find((p) => p.id === row.player_id)?.ball_type
                  ? [profiles.find((p) => p.id === row.player_id).ball_type]
                  : []),
              isYou: row.player_id === user.id,
            })),
        ],
      })),
    teamPlayerRequests: playerRequests.map((r) => {
      const t = teams.find((t) => t.id === r.team_id);
      const applicant = profiles.find((p) => p.id === r.player_id);
      return {
        id: r.id,
        teamId: r.team_id,
        teamName: t?.name || "Team",
        playerId: r.player_id,
        playerName: applicant?.name || "Player",
        playerProfile:
          t?.captain_id === user.id && applicant
            ? {
                id: applicant.id,
                name: applicant.name,
                role: "Player",
                cricketRole: applicant.cricket_role || null,
                jerseyNumber: applicant.jersey_number ?? null,
                ballTypes:
                  applicant.ball_types ??
                  (applicant.ball_type ? [applicant.ball_type] : []),
                isYou: applicant.id === user.id,
              }
            : null,
        kind: r.kind,
        status: r.status,
        createdAt: r.created_at,
        incoming:
          r.kind === "invite"
            ? r.player_id === user.id
            : t?.captain_id === user.id,
      };
    }),
    communities: communities.map((c) => ({
      ...c,
      city: c.location,
      area: c.location,
      tagline: "",
      illustration: "cricket",
    })),
    joinRequests: requests.map((r) => ({
      id: r.id,
      communityId: r.community_id,
      teamId: r.team_id,
      captainName:
        profiles.find((p) => p.id === r.captain_id)?.name || "Captain",
      teamName: teams.find((t) => t.id === r.team_id)?.name || "Team",
      status: r.status,
      seen: r.seen,
      createdAt: Date.parse(r.created_at),
      reviewedAt: r.reviewed_at ? Date.parse(r.reviewed_at) : null,
      isYou: r.captain_id === user.id,
    })),
  };
}
