# GameOn API

Independent Node.js + JavaScript API for GameOn's current community product. Express 5, Supabase Auth/Postgres, versioned HTTP routes, strict Zod input validation, database RLS and transactional RPCs. No frontend imports, no TypeScript, no server started by importing `app.js`.

## Local development

Use the existing Supabase project URL, publishable key and server-only key in `backend/.env.local`. Local and deployed API writes affect the same data when they share a project. Start with `cp -n .env.example .env.local`. If using static test login, configure development-only codes, an auth secret and allowed test phone numbers in that file.

Run `npm run dev` from the backend folder. This command uses only the local configuration and listens on port `4001`. Verify `http://localhost:4001/health/ready` before testing login. Railway starts the API with `npm start` and its own environment variables. Keep both env files out of Git.

This folder is a standalone backend project with its own package.json, environment file and Railway configuration. Its intended location is `sportsapp/backend`, alongside `sportsapp/frontend`. Run all commands below inside `sportsapp/backend`. Frontend integration has deliberately not been changed.

## 1. Install (does not start the app)

```sh
cd ../backend
nvm use 22
npm install
cp .env.example .env
```

Use Node 22.13+ (Node 22 LTS). Commit the generated `package-lock.json` after installation. Use `npm ci` for subsequent installs. The implementation environment could not resolve registry.npmjs.org, so a fresh dependency installation and lockfile generation could not be completed here. Syntax checks and 10 isolated security tests passed with existing workspace Supabase/Zod packages; HTTP integration, fresh dependency resolution and live database behavior remain to be verified after installation.

## 2. Fill backend `.env`

| Variable                          | Value                                                           |
| --------------------------------- | --------------------------------------------------------------- |
| `PUBLIC_SUPABASE_URL`             | Your existing project URL                                       |
| `PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Your existing publishable key                                   |
| `SUPABASE_SERVICE_ROLE_KEY`       | Supabase server-only service role key, or server secret API key |
| `NODE_ENV`                        | `development` locally; `production` for real users              |
| `PORT`                            | `4000` locally; Railway supplies its own port                   |
| `CORS_ORIGINS`                    | Exact browser origins, separated by commas, no trailing slash   |
| `TRUST_PROXY_HOPS`                | `0` locally; `1` when Railway is the one trusted ingress        |

Find the server key under your Supabase project's API key settings. Keep it only in this backend `.env` and Railway Variables. Do not paste it into chat, Expo env variables, Git, or any `PUBLIC_*` key. No credentials have been copied from the frontend. Public keys alone cannot perform the trusted Auth admin operations used here.

The `PUBLIC_` prefix above follows your requested names; it does not make backend environment files public. `.env` is ignored by Git. Set exact web frontend origins before testing the browser. Native mobile requests without an Origin are supported; authorization is still required.

## 3. Supabase SQL Editor

Run these complete files in order, one at a time:

1. `supabase/migrations/202610300001_community_foundation.sql`
2. `supabase/migrations/202610300002_login_limits.sql`
3. `supabase/migrations/202611050001_backend_api_support.sql`

For a new database, apply the rest of the files in `supabase/migrations/` in filename order. For an existing database, apply only migrations not already run.

If files 1 and 2 were already applied from the frontend project, run only file 3. Reapplying file 1 requires immediately reapplying file 2 because file 2 tightens profile grants. File 3 adds verified phone synchronization and an atomic team-save function; it does not delete existing data. These SQL files have NOT been run on your remote Supabase project, and the new migration has not been exercised against a live database here. Keep RLS enabled. The previous Edge Function is not needed by this backend; leave it in place until frontend integration is tested, then remove the obsolete deployment so two backend implementations do not drift.

### Availability alerts

If **Notify** fails with a SQL migration error, open the Supabase project used by the running API and run `supabase/migrations/202611200008_availability_alert_setup.sql` in SQL Editor. This restores the availability watch table and both RPCs without replacing the community leaderboard or clearing existing watches. It also refreshes the API schema cache.

The alert RPCs use `gameon_active_captain_team` from `supabase/migrations/202611190002_multiple_captain_teams.sql` and `gameon_match_action` from the match migrations. Apply any missing prerequisites in order before testing. To verify delivery, tap **Notify** for an unavailable opposing team, then turn on match availability as that team's captain. The watching captain needs a registered device with push enabled.


### Real phone OTP

Enable Supabase Phone authentication and configure an SMS provider. The backend uses `signInWithOtp`, `verifyOtp` and `phone_change`. Configure provider delivery, CAPTCHA, OTP expiry and provider-side limits before admitting public traffic. SMS provider charges may apply; there is no custom free SMS gateway included. `captchaToken` is supported by `/auth/otp/request` when CAPTCHA is enabled.

Flow: request OTP → verify OTP with phone, code and name → save returned session → authenticated requests. Name is only used to create a missing profile. The server verifies the token against Supabase Auth on each protected request.

Existing static-code accounts use synthetic email identities. They are not automatically linked to real phone identities. Plan an explicit ownership-verified migration or remove only disposable test accounts before switching those same phone numbers to real OTP. Phone uniqueness deliberately prevents silent account takeover.

### Temporary static-code testing

Only for dummy numbers in a private testing environment:

```dotenv
NODE_ENV=development
GAMEON_TEST_LOGIN_ENABLED=true
GAMEON_TEST_PHONES=9000000000,9000000001
GAMEON_AUTH_SECRET=YOUR_RANDOM_SECRET_AT_LEAST_32_CHARACTERS
GAMEON_TEST_USER_CODE=9636
GAMEON_TEST_ADMIN_CODE=5671
```

Generate a secret locally:

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

For existing synthetic-email test users, retain the same `GAMEON_AUTH_SECRET` used by the Edge Function; changing it changes their derived password. The backend refuses to boot with static testing enabled under `NODE_ENV=production`. An allowlisted number and a static code do not prove phone ownership. No automatic first-user admin promotion exists.

To assign an admin: create/sign in the intended test user first, verify their actual user ID in Supabase Authentication, then run this in the SQL Editor with that ID:

```sql
insert into public.gameon_admins(user_id)
values ('REPLACE_WITH_VERIFIED_AUTH_USER_UUID')
on conflict do nothing;
```

Use the test admin code on subsequent login after manually assigning the role. Real OTP admins still verify through SMS; admin rights are read from `gameon_admins`.

## 4. Verify, then start when ready

```sh
npm run check
```

No app or server was started during this implementation. When you want to start the backend yourself:

```sh
npm run dev
```

Local liveness is `GET http://localhost:4001/health/live` and readiness is `GET http://localhost:4001/health/ready`. Readiness checks database access. Test feature flows against the development project to verify its migrations and Auth setup.

## 5. Railway

1. Push this backend to GitHub; include `package-lock.json` after a successful local `npm install`.
2. Create a Railway service from that repository. For a repository containing both frontend and backend, set Root Directory to `/backend`; for a separate backend-only repository use `/`.
3. Add backend environment values in Railway Variables. Use `NODE_ENV=production`, `GAMEON_TEST_LOGIN_ENABLED=false`, `TRUST_PROXY_HOPS=1`, and your deployed browser origin(s). Do not upload `.env`.
4. Start command: `npm start`. Healthcheck: `/health/ready`. These are also defined in `railway.json`.
5. Generate a public HTTPS domain. The app binds `0.0.0.0` and uses Railway's `PORT`.
6. Verify health and the staging captain/admin flow before switching the frontend.

For a private static-code prototype deployment, explicitly use `NODE_ENV=development`, the test allowlist and test secrets. That deployment is a testing environment, not a public product release.

## Folder structure

| Path                       | Responsibility                                                              |
| -------------------------- | --------------------------------------------------------------------------- |
| `src/server.js`            | Process startup, port and graceful shutdown                                 |
| `src/app.js`               | Express setup, security headers, CORS, errors, HTTP limits                  |
| `src/config/`              | Validated environment and Supabase clients                                  |
| `src/middleware/`          | Verified bearer identity and input validation                               |
| `src/routes/`              | Versioned routes and strict request schemas                                 |
| `src/modules/auth/`        | OTP, refresh, sign-out, permissions, persistent login limits, gated testing |
| `src/modules/profiles/`    | Profile transactions                                                        |
| `src/modules/teams/`       | Captain team/ground updates                                                 |
| `src/modules/communities/` | Community creation and leaving                                              |
| `src/modules/requests/`    | Join requests, approval/rejection, seen state                               |
| `src/modules/accounts/`    | Account deletion and test-only phone changes                                |
| `src/modules/snapshot/`    | App-compatible private state projection                                     |
| `src/lib/`                 | Shared database errors, input helpers, bounded directory reads              |
| `supabase/migrations/`     | Reviewed SQL to apply manually                                              |

Feature files use explicit names such as `save-team.service.js` and `review-request.service.js`. Route handlers handle HTTP; services handle use cases; Postgres handles atomic invariants. User-scoped clients retain RLS for writes. Service-role access is confined to trusted identity/projection operations with explicit ownership checks. No empty architectural layers or placeholder business features are included.

See `docs/API.md` for payloads and frontend integration notes.

## Operational limits

The snapshot contract preserves the current frontend behavior. Directory reads are internally paginated and capped at 10,000 rows per table, rather than silently truncating at Supabase's default page. Before scaling beyond the current community MVP, replace snapshots with resource endpoints and cursor pagination. Responses expose only the requesting profile, permitted requests, public team names/counts, and member names within communities the caller joined or administers; they never return other users' phones or emails.

A mutation may commit before its follow-up snapshot fails. Refresh state before retrying; do not assume a failed HTTP response rolled the database transaction back. Approval is an atomic idempotent database RPC; community/team uniqueness is enforced in Postgres.

General API rate limits are per process; use a shared store/edge limiter before running multiple replicas. Phone/IP OTP limits are persisted in Postgres across replicas. Proxy trust assumes exactly one trusted ingress: reassess it if adding a CDN/proxy. Request logs contain generated request ID, method, status and duration, not bodies, tokens, phones or URL query strings. Upstream calls time out after 15 seconds. No custom WebSocket service is required: the frontend can retain Supabase Realtime with its RLS-filtered authenticated session.

Account deletion blocks superadmins pending an ownership transfer. It currently covers Auth and cascading database rows; no Storage assets exist in this module. Global sign-out revokes refresh sessions; already-issued access tokens can remain usable until their configured expiry, so keep Auth token lifetime appropriate to the product.

References: [Supabase phone login](https://supabase.com/docs/guides/auth/phone-login), [Railway healthchecks](https://docs.railway.com/deployments/healthchecks).
