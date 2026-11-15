import { randomInt } from "node:crypto";
import { deliveryTotals, validateDelivery } from "./delivery.rules.js";
import { fail } from "../../lib/errors.js";

const otherTeam = (teams, teamId) => teams.find((team) => team.id !== teamId);
const newInnings = (teamId) => ({
  teamId, runs: 0, wickets: 0, balls: 0, extras: 0, striker: null,
  nonStriker: null, bowler: null, previousBowler: null, dismissed: [], deliveries: [],
});
const inningsComplete = (state, innings) =>
  innings.balls >= state.overs * 6 || innings.wickets >= 10 ||
  (state.innings.length === 2 && innings.runs > state.innings[0].runs);

function rewindInnings(current, deliveryIndex, lastUndo) {
  if (!Number.isInteger(deliveryIndex) || deliveryIndex < 0)
    fail("Choose a delivery from this innings to undo.");
  const selected = current.deliveries[deliveryIndex];
  if (!selected) fail("Choose a delivery from this innings to undo.");
  const deliveries = current.deliveries.slice(0, deliveryIndex);
  if (lastUndo?.teamId === current.teamId && deliveryIndex === current.deliveries.length - 1) {
    return { ...lastUndo, deliveries };
  }

  // Use the recorded delivery to restore the players at the crease before that ball.
  // Older deliveries may lack a non-striker; leave that slot for the scorer to confirm.
  const restored = {
    ...newInnings(current.teamId),
    striker: selected.batterId,
    nonStriker: selected.nonStrikerId ?? null,
    bowler: selected.bowlerId,
    deliveries,
  };
  for (const ball of deliveries) {
    restored.runs += ball.runs + ball.extras;
    restored.extras += ball.extras;
    restored.balls += Number(ball.legal);
    restored.freeHit = ball.outcome === "noBall" || (!ball.legal && Boolean(restored.freeHit));
    if (ball.dismissedId) restored.dismissed.push(ball.dismissedId);
    if (ball.legal && restored.balls % 6 === 0) restored.previousBowler = ball.bowlerId;
  }
  restored.wickets = restored.dismissed.length;
  return restored;
}

export function scoringAccess(match, state) {
  const innings = state?.innings.at(-1);
  if (!innings) return { canScore: false, canAdvance: false, canEndAsDraw: false, canEndMatch: false, scorers: {} };
  const legacyTeam = match.teams.find(({ id }) => id === state.scorerTeamId);
  const activeId = state.scorers?.[innings.teamId]
    || (!state.scorers && legacyTeam?.captainId)
    || match.teams.find(({ id }) => id === innings.teamId).captainId;
  const scorers = Object.fromEntries(match.teams.map((team) => {
    const playerId = team.id === innings.teamId ? activeId : state.scorers?.[team.id] || team.captainId;
    const player = team.roster.find(({ id }) => id === playerId)
      || match.teams.find((side) => side.captainId === playerId)?.roster.find(({ id }) => id === playerId);
    return [team.id, { id: playerId, name: player?.name || "Scorer unavailable" }];
  }));
  const ended = Boolean(state.result);
  const canScore = !ended && match.ownTeamId !== null && activeId === match.actorId;
  return {
    canScore,
    canAdvance: !ended && (canScore || (match.isCaptain && match.ownTeamId === innings.teamId)),
    canEndMatch: canScore && !(state.innings.length === 2 && inningsComplete(state, innings)),
    canEndAsDraw: !ended && match.isCaptain && match.teams.some(({ id, captainId }) =>
      id === match.ownTeamId && captainId === match.actorId
    ) && !(state.innings.length === 2 && inningsComplete(state, innings)),
    scorers,
  };
}

export function updateScore(match, action) {
  const { state, ownTeamId } = match;
  if (state?.result) fail("This match has already ended.", 409);
  if (action.kind === "lineup") {
    if (!match.isCaptain) fail("Only the team captain can save the playing XI.", 403);
    if (state?.innings.length) fail("The playing XI is locked once scoring starts.", 409);
    const team = match.teams.find(({ id }) => id === ownTeamId);
    const eleven = team.roster.filter(({ id }) => action.players.includes(id));
    if (eleven.length !== 11) fail("Choose 11 different players from your team.");
    return {
      lineups: { ...state?.lineups, [ownTeamId]: eleven },
      innings: [],
    };
  }

  if (["toss", "tossDecision", "retoss", "start"].includes(action.kind)) {
    if (!match.isCaptain) fail("Only the captains can set up the match toss.", 403);
    if (state?.innings.length) fail("This match has already started.", 409);
    if (!match.teams.every(({ id }) => state?.lineups[id]?.length === 11))
      fail("Both captains must save their playing XI first.");

    const captain = match.teams.find(({ id }) => id === ownTeamId)
      ?.roster.find(({ id }) => id === match.actorId);
    const recordedBy = { captainId: match.actorId, teamId: ownTeamId, captainName: captain?.name ?? null };

    if (action.kind === "toss") {
      if (state.toss) fail("The toss result is already saved.", 409);
      const conductedAt = new Date().toISOString();
      if (action.method === "manual") {
        if (!match.teams.some(({ id }) => id === action.winnerTeamId))
          fail("Choose one of the two teams as the toss winner.");
        return {
          ...state,
          toss: { method: "manual", winnerTeamId: action.winnerTeamId, conductedBy: recordedBy, conductedAt },
        };
      }
      const { headsTeamId } = action;
      if (!match.teams.some(({ id }) => id === headsTeamId))
        fail("Assign Heads to one of the two teams.");
      const tailsTeamId = otherTeam(match.teams, headsTeamId).id;
      const landed = randomInt(2) === 0 ? "heads" : "tails";
      const winnerTeamId = landed === "heads" ? headsTeamId : tailsTeamId;
      return {
        ...state,
        toss: { method: "coin", headsTeamId, tailsTeamId, landed, winnerTeamId, conductedBy: recordedBy, conductedAt },
      };
    }

    if (!state.toss) fail("Complete the toss first.");
    if (action.kind === "retoss") {
      const conductorId = state.toss.conductedBy?.captainId;
      const canRetoss = conductorId ? conductorId === match.actorId : state.toss.winnerTeamId === ownTeamId;
      if (!canRetoss) fail("Only the captain who recorded the toss can request a retoss.", 403);
      return {
        ...state,
        toss: null,
        tossHistory: [
          ...(state.tossHistory || []),
          { ...state.toss, voidedBy: recordedBy, voidedAt: new Date().toISOString() },
        ],
      };
    }

    if (action.kind === "tossDecision") {
      const conductorId = state.toss.conductedBy?.captainId;
      const sharedPhone = state.toss.method === "coin" && conductorId && conductorId === match.actorId;
      if (state.toss.winnerTeamId !== ownTeamId && !sharedPhone)
        fail("Only the toss winner or the captain who ran the app toss can record the decision.", 403);
      if (state.toss.decision) fail("The toss decision is already saved.", 409);
      return {
        ...state,
        toss: {
          ...state.toss,
          decision: action.decision,
          decisionRecordedBy: recordedBy,
        },
      };
    }

    if (!state.toss.decision) fail("The toss-winning captain must choose to bat or bowl first.");
    const { winnerTeamId, decision } = state.toss;
    const battingTeamId = decision === "bat" ? winnerTeamId : otherTeam(match.teams, winnerTeamId).id;
    return {
      ...state,
      scorers: {},
      overs: match.overs,
      innings: [newInnings(battingTeamId)],
    };
  }

  if (!state?.innings.length) fail("Start the match before scoring.", 409);
  const current = state.innings.at(-1);
  const access = scoringAccess(match, state);
  const chasing = state.innings.length === 2;
  const first = state.innings[0];
  const complete = inningsComplete(state, current);

  if (action.kind === "endAsDraw") {
    if (chasing && complete) fail("This match has already finished.", 409);
    if (!access.canEndAsDraw) fail("Only a participating captain can end the match as a draw.", 403);
    return {
      ...state,
      result: { type: "draw", reason: action.reason, recordedBy: match.actorId, recordedAt: new Date().toISOString() },
    };
  }

  if (action.kind === "endMatch") {
    if (!access.canEndMatch) fail("Only the assigned scorer can end this match.", 403);
    return {
      ...state,
      result: {
        type: "ended",
        reason: action.reason,
        recordedBy: match.actorId,
        recordedAt: new Date().toISOString(),
      },
    };
  }

  if (action.kind === "assignScorer") {
    if (!match.isCaptain) fail("Only your captain can assign a scorer.", 403);
    if (chasing && (ownTeamId !== current.teamId || complete))
      fail("Your team no longer has an innings to score.", 409);
    const team = match.teams.find(({ id }) => id === ownTeamId);
    if (!team.roster.some(({ id }) => id === action.playerId))
      fail("Choose a scorer from your own team.");
    return {
      ...state,
      scorers: {
        [current.teamId]: access.scorers[current.teamId].id,
        ...state.scorers,
        [ownTeamId]: action.playerId,
      },
    };
  }

  const bowlingTeam = otherTeam(match.teams, current.teamId);
  if (action.kind === "nextInnings") {
    if (!access.canAdvance) fail("Only the first innings scorer or batting captain can hand off scoring.", 403);
    if (chasing || !complete) fail("Finish the first innings before switching sides.");
    return {
      ...state, innings: [first, newInnings(bowlingTeam.id)],
      scorers: state.scorers || {}, undo: null,
    };
  }
  if (!access.canScore) fail("Only the assigned scorer can record balls for this innings.", 403);
  if (action.kind === "undo") {
    const index = action.deliveryIndex ?? current.deliveries.length - 1;
    const restored = rewindInnings(current, index, state.undo);
    return {
      ...state,
      innings: [...state.innings.slice(0, -1), restored],
      undo: null,
    };
  }

  const batting = state.lineups[current.teamId];
  const bowling = state.lineups[bowlingTeam.id];
  if (complete) fail("This innings has ended.");

  const next = { ...current };
  const innings = [...state.innings.slice(0, -1), next];

  if (action.kind === "select") {
    if (action.position === "bowler") {
      const lastBall = next.deliveries.at(-1);
      const overHasStarted = lastBall && (!lastBall.legal || next.balls % 6 !== 0);
      if ((next.bowler && overHasStarted) || next.previousBowler === action.playerId || !bowling.some(({ id }) => id === action.playerId))
        fail("Choose a bowler who did not bowl the previous over.");
    } else {
      if ((next[action.position] && next.deliveries.length) || !batting.some(({ id }) => id === action.playerId) ||
          [next.striker, next.nonStriker, ...next.dismissed].includes(action.playerId))
        fail("Choose an available batter for this position.");
    }
    next[action.position] = action.playerId;
    return { ...state, innings };
  }

  if (!next.striker || !next.nonStriker || !next.bowler)
    fail("Choose both batters and the bowler before scoring.");
  const invalid = validateDelivery(action, Boolean(next.freeHit));
  if (invalid) fail(invalid);
  if (action.fielderId && !bowling.some(({ id }) => id === action.fielderId))
    fail("Choose a fielder from the bowling XI.");

  const totals = deliveryTotals(action);
  const { legal, runs, extras } = totals;
  const wicket = Boolean(action.dismissal);
  if (wicket && chasing && current.runs + runs + extras > first.runs)
    fail("The winning run ended the match before the dismissal. Record the runs without a wicket.");
  const dismissalPosition = action.dismissal === "runOutNonStriker" ? "nonStriker" : "striker";
  const dismissedId = wicket ? next[dismissalPosition] : null;
  next.runs += runs + extras;
  next.extras += extras;
  next.balls += Number(legal);
  next.freeHit = action.outcome === "noBall" || (!legal && Boolean(next.freeHit));
  next.deliveries = [...next.deliveries, {
    outcome: action.outcome, ...totals,
    batterId: next.striker, nonStrikerId: next.nonStriker, bowlerId: next.bowler,
    ...(action.shotZone ? { shotZone: action.shotZone } : {}),
    ...(wicket ? { dismissal: action.dismissal, dismissedId, fielderId: action.fielderId } : {}),
  }];
  if (wicket) {
    next.wickets++;
    next.dismissed = [...next.dismissed, dismissedId];
    const incomingEnd = action.incomingEnd ||
      (action.runs % 2 ? (dismissalPosition === "striker" ? "nonStriker" : "striker") : dismissalPosition);
    const survivor = next[dismissalPosition === "striker" ? "nonStriker" : "striker"];
    next.striker = incomingEnd === "striker" ? null : survivor;
    next.nonStriker = incomingEnd === "nonStriker" ? null : survivor;
  } else if (action.runs % 2 && !totals.boundary) {
    [next.striker, next.nonStriker] = [next.nonStriker, next.striker];
  }

  if (legal && next.balls % 6 === 0) {
    [next.striker, next.nonStriker] = [next.nonStriker, next.striker];
    next.previousBowler = next.bowler;
    next.bowler = null;
  }
  const { deliveries, ...undo } = current;
  return { ...state, innings, undo };
}
