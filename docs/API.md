# API contract

Base URL: `https://YOUR_API_DOMAIN/api/v1`.
Protected routes require `Authorization: Bearer <Supabase access_token>`. JSON mutations require `Content-Type: application/json`. No service key or Supabase `apikey` header should be sent from the app to this API.

Errors use `{ "error": "Safe message", "requestId": "generated-id" }`; rate limiter responses may omit requestId. Unknown properties are rejected. IDs must be UUIDs. Public signup does not allow admin assignment.

| Method | Path                     | JSON body                                                   | Response                                                |
| ------ | ------------------------ | ----------------------------------------------------------- | ------------------------------------------------------- |
| POST   | `/auth/otp/request`      | `{phone, captchaToken?}`                                    | `{sent:true}`                                           |
| POST   | `/auth/otp/verify`       | `{phone, code, name}`                                       | `{session}`                                             |
| POST   | `/auth/test-login`       | `{phone, code, name}`                                       | `{session}`; non-production allowlist only              |
| POST   | `/auth/refresh`          | `{refreshToken}`                                            | `{session}`                                             |
| POST   | `/auth/logout`           | none; authenticated                                         | `{signedOut:true}`                                      |
| GET    | `/me/snapshot`           | none; authenticated                                         | Snapshot directly                                       |
| PATCH  | `/me/profile`            | `{values:{name,email,role,teamName}}`                       | `{snapshot}`                                            |
| PUT    | `/me/team`               | `{values:{name,hasGround,groundName,groundArea,amenities}}` | `{snapshot}`                                            |
| POST   | `/communities`           | `{values:{name,city,description,rules,category}}`           | `{communityId,snapshot}`                                |
| POST   | `/join-requests`         | `{communityId,accepted:true}`                               | `{snapshot}`                                            |
| POST   | `/join-requests/review`  | `{requestId,decision}`                                      | `{snapshot}`                                            |
| POST   | `/join-requests/seen`    | `{communityId?}`                                            | `{snapshot}`                                            |
| POST   | `/memberships/leave`     | `{communityId}`                                             | `{snapshot}`                                            |
| POST   | `/account/phone/request` | `{phone}`                                                   | `{sent:true}`; authenticated real phone user            |
| POST   | `/account/phone/verify`  | `{phone,code}`                                              | `{session,changed:true}`; authenticated                 |
| DELETE | `/me/account`            | `{}`                                                        | `{deleted:true}`; authenticated non-admin               |
| POST   | `/actions`               | `{action,...payload}`                                       | Existing cloudAction contract; same validation and auth |

Phone is an Indian ten-digit number or +91 form. Codes are strings. `role` is `Captain` or `Player`; `category` is `Corporate` or `Local`; `decision` is `approved` or `rejected`. Community rules are newline-separated strings, 1–12 rules with at most 250 characters per rule. `city` is stored as the community's location.

Admin-only: create community, approve/reject, mark requests seen. A completed Captain with their own team can request membership after accepting rules. A captain can leave their own memberships. A captain with active memberships must leave communities before removing their role/team. Team saves use the authenticated `gameon_save_team` transaction.

## Frontend integration

The frontend calls Node using `EXPO_PUBLIC_API_URL`. It contains no Supabase client or database credentials. Login returns tokens held in memory; refresh uses `/auth/refresh`, and logout uses `/auth/logout`. Data changes use `/actions` with bearer authorization. Screens refresh on focus, app foreground and native push events. Authenticated admin devices register with the registerPush action; unregisterPush removes only the requesting user’s token. See frontend/docs/ADMIN-PUSH.md for setup.

Local and Railway API addresses are selected using the frontend `.env.local` and `.env.production` profiles. Database keys remain exclusively in backend environment variables.

Current screens retain static test login and phone change. Production requires integrating the real OTP request/verify endpoints and configuring an SMS provider. The bridge supports login, snapshot, saveProfile, saveTeam, createCommunity, requestJoin, reviewRequest, markSeen, leaveCommunity, changePhone and deleteAccount with server validation and authorization.
