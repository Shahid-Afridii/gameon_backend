# Teams, players and invitations

Apply `supabase/migrations/202611060002_team_players.sql` in Supabase SQL Editor after the existing migrations. Restart the Node API and reload the frontend. No new environment variables or native dependencies are needed.

## App flow

- My Teams appears next to Profile for normal accounts.
- Captains create/edit a team (including a description), search completed Player profiles by name, and send invitations.
- Players browse teams and request membership. A player can belong to multiple teams.
- For an invitation, only the invited player accepts/declines. For a join request, only that team's captain accepts/declines.
- Acceptance creates membership in the same database transaction as the review. Captains and accepted teammates see the roster with Captain/Player roles. Pending invitations do not grant roster or community access.
- Accepted players can access communities their teams have already joined. Community membership applications and match actions remain captain-only.
- Profile's Join a team opens Explore. Selecting a team name on a profile no longer pretends to create team membership.

## Notifications

All signed-in accounts can register their own Expo push token. Invitation/join request notifications go only to the recipient; review notifications go to the original sender. Tap opens My Teams → Requests. Push failure does not undo the saved request. In-app Requests and its tab badge remain the source of truth.

Remote push needs an installed Android/iOS development or release build on a physical device with notification permission, and the existing Expo/FCM credentials. Web and Expo Go use in-app requests. A device that never registered a token cannot receive push.

## Verification with two accounts

1. Captain: My Teams → Create/Edit team → save a name and description.
2. Player: complete a Player profile and allow notifications on the installed app.
3. Captain: Add player → search name → Invite. Player receives the invitation and sees it in Requests.
4. Player: Accept. Both accounts' My Teams roster shows the captain and player with their roles.
5. With a second player, Explore → Request to join. Captain accepts in Requests; second player appears in the roster.
6. Decline a request: no membership is created. A second pending request for the same player/team is blocked, including reversed invitation/join requests.
7. An unrelated account cannot see another team's roster or approve another user's request. Phone numbers and emails are absent from directory and roster responses.

## API actions

`searchPlayers`, `inviteTeamPlayer`, `requestTeamJoin`, `reviewTeamPlayer`; existing `saveTeam` now accepts `description`. The snapshot exposes `teamDirectory`, `myTeams` and `teamPlayerRequests`. Request/roster tables have RLS enabled and no client grants; mutations use a service-only RPC with explicit actor/recipient validation.

Automated checks cover API validation, actor binding, permission rejection, duplicate-error handling, push recipient targeting/failure isolation and accepted-player snapshot privacy. The SQL migration and physical-device push delivery still require the above live verification.
