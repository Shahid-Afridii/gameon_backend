import { admin } from "../../config/supabase.js";
import { check, fail } from "../../lib/errors.js";
import { isFixtureCaptain, scoringAccess, updateScore } from "./scoring.engine.js";

function scoreResult(result) {
  if (result.error?.code === "42501") fail(result.error.message, 403);
  if (result.error?.code === "P0001") fail(result.error.message, 409);
  return check(result);
}

export async function matchScore({ user, body }) {
  const identity = { actor: user.id, fixture_id: body.requestId, slot_index: body.matchIndex };
  const match = {
    ...scoreResult(await admin.rpc("gameon_read_match_score", identity)),
    actorId: user.id,
  };
  const setup = !match.state?.innings.length;
  if (match.isCaptain && setup) {
    const manual = await admin.from("gameon_manual_players")
      .select("id,team_id,name,cricket_role,jersey_number")
      .in("team_id", match.teams.map(({ id }) => id)).is("linked_player_id", null)
      .order("name").order("id");
    if (!["42P01", "PGRST205"].includes(manual.error?.code)) {
      for (const player of check(manual)) {
        match.teams.find(({ id }) => id === player.team_id).roster.push({
          id: player.id, name: player.name, cricketRole: player.cricket_role,
          jerseyNumber: player.jersey_number, manual: true,
        });
      }
    }
  }
  // Presence is an enhancement: a missing/outdated viewer migration must never block scoring.
  const viewerPresence = await admin.rpc("gameon_touch_score_viewer", identity);
  const viewerCount = viewerPresence.error ? 1 : viewerPresence.data;
  const visible = {
    ownTeamId: match.ownTeamId,
    isCaptain: match.isCaptain,
    overs: match.overs,
    viewerCount,
    supportsMatchRestart: true,
    teams: match.teams.map(({ id, name, captainId, roster }) => ({
      id, name, captainId,
      captainName: roster.find((player) => player.id === captainId)?.name ?? null,
      ...(match.isCaptain && (setup || id === match.ownTeamId) ? { roster } : {}),
    })),
  };
  const playerDetails = new Map(match.teams.flatMap(({ roster }) =>
    roster.map((player) => [player.id, {
      ...(Object.hasOwn(player, "jerseyNumber") ? { jerseyNumber: player.jerseyNumber } : {}),
      ...(Object.hasOwn(player, "cricketRole") ? { cricketRole: player.cricketRole } : {}),
    }]),
  ));
  const response = (state, revision) => {
    // Fill in profile details for lineups saved before these fields were available.
    const lineups = state && Object.fromEntries(Object.entries(state.lineups).map(([teamId, eleven]) => [
      teamId,
      eleven.map((player) => ({ ...player, ...playerDetails.get(player.id) })),
    ]));
    const { restart, ...publicState } = state ?? {};
    return {
      ...visible,
      state: state && { ...publicState, lineups },
      ...(restart && isFixtureCaptain(match) ? {
        restart: { undoUntil: restart.undoUntil, serverNow: Date.now() },
      } : {}),
      revision,
      access: scoringAccess(match, state),
    };
  };
  if (body.operation === "read") return response(match.state, match.revision);
  if (match.ownTeamId === null) fail("Spectators can only view the scorecard.", 403);
  if (match.revision !== body.revision) fail("The score changed. Refresh before trying again.", 409);

  const state = updateScore(match, body.change);
  const revision = scoreResult(await admin.rpc("gameon_save_match_score", {
    ...identity, expected_revision: body.revision, next_state: state,
  }));
  return response(state, revision);
}
