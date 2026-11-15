// "wicket" remains supported as the delivery type for a dismissal on a legal ball.
const runOuts = ["runOutStriker", "runOutNonStriker"];
const noBallDismissals = [...runOuts, "hitBallTwice", "obstructingField"];
const wideDismissals = [...runOuts, "stumped", "hitWicket", "obstructingField"];

export function validateDelivery(action, freeHit = false) {
  const { outcome, runs, dismissal, shotZone, boundary, noBallRuns, fielderId, incomingEnd } = action;
  const runOut = runOuts.includes(dismissal);
  const offBat = outcome === "runs" || (outcome === "noBall" && !noBallRuns);
  if (outcome === "wicket" && !dismissal) return "Choose how the batter was dismissed.";
  if (dismissal && outcome === "noBall" && !noBallDismissals.includes(dismissal))
    return "That dismissal is unavailable on a no-ball.";
  if (dismissal && outcome === "wide" && !wideDismissals.includes(dismissal))
    return "That dismissal is unavailable on a wide.";
  if (dismissal && freeHit && !noBallDismissals.includes(dismissal))
    return "That dismissal is unavailable on a free hit.";
  if (outcome === "wicket" && runs > 0) return "Choose runs, byes or leg byes to record completed runs on a run-out.";
  if (dismissal && !runOut && runs !== 0) return "Enter runs only for a run-out dismissal.";
  if ((incomingEnd && !runOut) || (fielderId && ![...runOuts, "caught", "stumped"].includes(dismissal)))
    return "Those details do not apply to this dismissal.";
  if (noBallRuns && outcome !== "noBall") return "Choose a no-ball before adding no-ball extras.";
  if (["bye", "legBye"].includes(outcome) && runs === 0 && !dismissal)
    return "Enter at least one bye or leg bye.";
  if (boundary && (!offBat || boundary !== runs || dismissal))
    return "A boundary must match the runs scored off the bat.";
  if (shotZone === "crease" && !dismissal)
    return "The crease location is available for wickets.";
  if (shotZone && !dismissal && (!offBat || runs === 0))
    return "A shot location requires runs off the bat.";
  return null;
}

export function deliveryTotals(action) {
  const { outcome, runs, dismissal, noBallRuns } = action;
  const legal = outcome !== "wide" && outcome !== "noBall";
  const offBat = (outcome === "runs" || (outcome === "noBall" && !noBallRuns));
  const batterRuns = offBat ? runs : 0;
  const wides = outcome === "wide" ? 1 + runs : 0;
  const noBalls = outcome === "noBall" ? 1 : 0;
  const byes = outcome === "bye" || noBallRuns === "bye" ? runs : 0;
  const legByes = outcome === "legBye" || noBallRuns === "legBye" ? runs : 0;
  const extras = wides + noBalls + byes + legByes;
  const boundary = action.boundary ?? (!dismissal && (batterRuns === 4 || batterRuns === 6) ? batterRuns : 0);
  return {
    legal, runs: batterRuns, extras, boundary,
    breakdown: { wides, noBalls, byes, legByes },
    bowlerRuns: batterRuns + wides + noBalls,
    bowlerWicket: ["bowled", "caught", "lbw", "stumped", "hitWicket"].includes(dismissal),
  };
}
