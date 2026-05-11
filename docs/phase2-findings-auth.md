# Phase 2 — real tenant + JWT bootstrap + upload bearer + magic-link recruiter auth

> Status as of 2026-05-07.
> Replaces the `InterviewWeb.Plugs.DevTokenAuth` stub end-to-end. Test count
> 107 → 179 (`mix precommit` green). Unblocks Phase 3 embed SDK.

## What was built

| Capability | Where | Status |
|---|---|---|
| `Interview.Auth.Tokens` — single wrapper over `Phoenix.Token` for all three signed token types (bootstrap / upload bearer / recruiter session). Audience-specific salts. `rk_` prefix on recruiter tokens to disambiguate from `tk_` API keys at the plug layer. | `lib/interview/auth/tokens.ex` | ✅ |
| `Interview.Auth.Recruiters` + `User` + `MagicLink` schemas. `request_magic_link/2` (logs URL, returns raw token to caller for tests), `consume_magic_link/1` (atomic `FOR UPDATE` consume; rejects double-consume + expired). | `lib/interview/auth/recruiters.ex`, `recruiters/{user,magic_link}.ex` | ✅ |
| `Interview.Auth.ApiKeys` — `tenant_api_keys` CRUD. Wire format `Authorization: Bearer tk_<secret>`. Stored as `prefix` (lookup) + `key_hash` (sha256). Plaintext returned **once** from `create/3`. `verify/1` does `Plug.Crypto.secure_compare` and rejects revoked keys. Async `last_used_at` touch via `Interview.TaskSupervisor`. | `lib/interview/auth/api_keys.ex`, `api_keys/api_key.ex` | ✅ |
| `Interview.Auth.Bootstrap` — orchestrates mint/peek/consume against `sessions.bootstrap_jti` + `sessions.bootstrap_consumed_at`. **`peek/1` is the LV-disconnected-mount path** (verify-only, no DB write); `consume/1` is the connected mount + the `auth` postMessage path. Both reject the same way for stale/consumed tokens. | `lib/interview/auth/bootstrap.ex` | ✅ |
| `InterviewWeb.Plugs.TenantAuth` — replaces `DevTokenAuth` on `/api/templates*` and the new `/api/sessions*` scope. Accepts EITHER `tk_*` (api key) OR `rk_*` (recruiter session token); assigns `:tenant` and (for the rk path) `:current_recruiter`. | `lib/interview_web/plugs/tenant_auth.ex` | ✅ |
| `InterviewWeb.Plugs.RecruiterAuth` — for routes that *require* a recruiter (api-key CRUD, refresh). Resolves from session cookie (`get_session(:recruiter_token)`) OR `Authorization: Bearer rk_*`. JSON requests → 401 on miss; HTML → 302 to `/auth/sign-in`. | `lib/interview_web/plugs/recruiter_auth.ex` | ✅ |
| `InterviewWeb.UserAuth` — LiveView `on_mount {:ensure_recruiter}` callback. Reads the cookie token via the LV session, resolves recruiter+tenant, assigns `:current_scope`. Halts to `/auth/sign-in` on miss. | `lib/interview_web/live/user_auth.ex` | ✅ |
| `POST /api/sessions` (server-to-server) — TenantAuth-gated. Accepts `template_id` (resolves to `current_version_id`) OR `template_version_id` (validates tenant ownership). Inserts session with frozen `template_version_id`, mints + stores bootstrap. Returns `{id, bootstrap_token, template_version_id}`. | `lib/interview_web/controllers/session_controller.ex` | ✅ |
| `POST /api/sessions/:id/bootstrap` — re-mints (rotates jti). Cross-tenant returns 404. | same controller | ✅ |
| Magic-link surface: `POST /api/auth/magic-links` (always 202, no enumeration), `GET /auth/magic-link/:token` (consume → put_session → redirect to `/recruiter/templates`). Static error page on consumed/expired/invalid. | `lib/interview_web/controllers/magic_link_controller.ex` | ✅ |
| `GET /auth/sign-in` — static HTML form posting back to itself. `POST /auth/sign-in` triggers `request_magic_link/2`. `DELETE /auth/sign-out` clears + drops the session cookie. `POST /api/auth/refresh` rotates the recruiter session token (cookie + JSON body). | `lib/interview_web/controllers/auth_controller.ex` | ✅ |
| Tenant API key CRUD: `GET /api/tenant/api-keys` (list), `POST /api/tenant/api-keys` (create, returns secret once), `DELETE /api/tenant/api-keys/:id` (revoke). RecruiterAuth-gated. | `lib/interview_web/controllers/api_key_controller.ex` | ✅ |
| `CaptureLive` token handshake: URL `?token=<bootstrap>` (fallback path) is consumed in mount; absent token renders `:awaiting_auth` placeholder + the recorder hook in `data-awaiting-auth="true"` mode, which posts `{v:1, type:'ready', channelId}` to the parent. Inbound postMessage `auth` is forwarded to LV via `pushEvent("auth", {token})`. New event `refresh_upload_token` mints a fresh upload bearer. Rejected/consumed tokens render a clean view (still on `:embed` pipeline so the parent frame can display it). | `lib/interview_web/live/capture_live.ex` | ✅ |
| `assets/js/hooks/recorder.js`: `bindPostMessage()` + `channelId` nonce; `authedFetch()` attaches `Authorization: Bearer <upload_jwt>` to every tus PATCH and `capture_complete` POST; on 401 → `pushEvent("refresh_upload_token", …)` then retry once. | `assets/js/hooks/recorder.js` | ✅ |
| `lib/interview_web/tus/plug.ex`: PATCH and HEAD now require `Authorization: Bearer <upload_jwt>` whose `sid` matches the response's session_id. OPTIONS skips bearer (preflight). | tus plug | ✅ |
| `lib/interview_web/controllers/capture_complete_controller.ex`: matching upload-bearer assertion before the existing fence/mismatch checks. Bearer for a different session → 401. | capture_complete controller | ✅ |
| `InterviewWeb.Plugs.EmbedCSP` — per-tenant `frame-ancestors` looked up via `conn.path_params["session_id"]` → `sessions.tenant_id` → `tenants.frame_ancestors`. Empty list → `'self'` (deny external). Unknown session → falls back to app-config (test/harness). | `lib/interview_web/plugs/embed_csp.ex` | ✅ |
| `RecruiterTemplateLive` — `live_session :recruiter, on_mount: [{UserAuth, :ensure_recruiter}]`. Cross-tenant template renders as `not_found` (no information leak). Unauth → redirect to `/auth/sign-in`. | router + LV | ✅ |
| `CaptureSessionController` (`/capture/new` dev shortcut): now mints a bootstrap and redirects to `/capture/:id?token=<bootstrap>` so `mix phx.server` + visit works end-to-end. | controller | ✅ |
| Migrations: `recruiter_users`, `recruiter_magic_links`, `tenant_api_keys`, `alter_sessions_add_bootstrap` (adds `bootstrap_jti`, `bootstrap_consumed_at`). | `priv/repo/migrations/2026050700001{0,1,2,3}_*.exs` | ✅ |
| Seeds: dev recruiter (`dev@example.com`), dev API key (minted on first run; secret printed once). Dev tenant `frame_ancestors` already in seeds (`'self'`, `localhost:5174`, `127.0.0.1:5174`); the dev-time `:embed_frame_ancestors` config in `config/dev.exs` is now only the test/harness fallback. | `priv/repo/seeds.exs` | ✅ |
| **Deleted** `lib/interview_web/plugs/dev_token_auth.ex`. | — | ✅ |
| **Removed** `config :interview, dev_routes: true` from `config/test.exs`. | `config/test.exs` | ✅ |
| Test fixtures: `recruiter!/2`, `api_key!/2` (with `revoked: true` opt), `bootstrap_token!/1`, `upload_bearer!/1`, `recruiter_session_token!/1`. | `test/support/fixtures.ex` | ✅ |
| Tests: 72 new across `tokens_test.exs`, `recruiters_test.exs`, `api_keys_test.exs`, `bootstrap_test.exs`, `tenant_auth_test.exs`, `recruiter_auth_test.exs`, `embed_csp_test.exs`, `session_controller_test.exs`, `magic_link_controller_test.exs`, `auth_controller_test.exs`, `api_key_controller_test.exs`, plus updated tus / capture_complete / capture_live / recruiter_template_live tests. | `test/interview/auth/`, `test/interview_web/plugs/`, `test/interview_web/controllers/`, `test/interview_web/live/` | ✅ |

## Decision-log changes

PLAN §11 #8 was clarified: token implementation is `Phoenix.Token` with
audience-specific salts, not RFC 7519 JWS. Functionally equivalent for v1
(integrity + freshness via `max_age`), and saves two deps (Joken, JOSE).
Production migration to a real JWS envelope is a follow-up only if a third
party (customer backend, ATS) ever needs to verify our tokens directly —
which §4.2 does not require.

## Gotchas worth knowing for next session

- **LiveView mounts twice for `live(conn, url)`** — once on the HTTP GET
  ("disconnected") and once on the WebSocket connect ("connected"). A
  single-use token consumed in mount would be consumed twice. The pattern
  used here: `Bootstrap.peek/1` on the disconnected mount (verify-only,
  no DB write), `Bootstrap.consume/1` on the connected mount. Both reject
  identically for stale/consumed tokens.
- **`render_hook` does not return the LV's `:reply` payload** — same
  Phase-2-candidate-flow gotcha. The capture-live `auth` event test has
  to read the rendered HTML to verify the auth transition, not the reply.
- **`configure_session(drop: true)` does not clear the in-memory
  session** — only the cookie on the response. Tests that assert
  `get_session/2` after sign-out also need `clear_session(conn)` in the
  controller.
- **`Plug.CSRFProtection.get_csrf_token/0` requires `:protect_from_forgery`
  to have run** — the sign-in form lives in the `:browser` pipeline,
  which already includes it. If you ever move sign-in onto a bare
  pipeline, the form will 500 at render time.
- **TenantAuth `tk_*` vs `rk_*` parsing** — the disambiguation is
  prefix-only at the plug layer. The `Tokens.verify_recruiter_session/1`
  function accepts either `rk_<...>` or the bare token (cookie-stripped
  form), so the cookie path stores the bare form (without `rk_`) and the
  bearer path uses the prefixed form.
- **Async `last_used_at` touch** — `ApiKeys.touch_used_async/1` spawns a
  Task in production but runs inline under `:test` (gated on
  `config :interview, :async_touch?, false` in `config/test.exs`). This
  prevents Postgrex sandbox-owner-exited noise from a Task that survives
  the test owner.
- **EmbedCSP plug's `path_params` lookup runs in the request path**.
  For an unknown session id (`bogus`) we fall back to the app-config
  list, which keeps the inline-not-found test passing. If you ever
  remove the fallback, make sure the not-found test still has a
  `frame-ancestors` header.
- **`Bootstrap.peek` short-circuits if jti doesn't match** — even on
  the disconnected mount, the rejected view renders. So a customer's
  re-loaded page (where the token was already consumed by the prior
  WebSocket mount) will see the rejected view on the next GET, with
  no DB write attempted.
- **`update_change(:email, &normalize_email/1)`** in
  `Recruiters.User.changeset/2` lowercases + trims before validation,
  so any caller (importers, tests, manual ops) gets the same canonical
  email regardless of input casing.

## Carries into next session

Inputs the next session should pick up:

- **Phase 3 embed SDK** (PLAN §7 Phase 3) — this session unblocks it.
  The candidate iframe now expects either `?token=<bootstrap>` in the
  URL or a `{v:1, type:'auth', channelId, bootstrapToken}` postMessage
  reply to its outbound `{v:1, type:'ready', channelId}`. The SDK
  (`@you/interview-embed`) goes here.
- **Recruiter-recorded video prompts + image/PDF attachments** —
  PLAN §3.4 Phase 2 carry-forward. Reuse the candidate
  MediaRecorder + IDB + tus pipeline; new asset endpoints. The
  authoring LV has hooks for `prompt_asset_id` /
  `attachment_asset_id` already.
- **Whisper transcript Oban job** per `question_response`
  (PLAN §11 #9). Independent of auth.
- **Drag-handle reorder polish** (Phase-2-authoring carry).
- **Think-time countdown UI gap** (Phase-2-candidate-flow carry).
- **JSON-as-import body on `/api/templates/:id/import`** if customers
  ask. The `cond` branch in `template_controller.ex` already has the
  hook.
- **Asset-reference existence checks in importers** before they hit
  Ecto. Gated on the asset pipeline existing.
- **Swoosh + SMTP for real magic-link delivery**. Currently the URL
  only logs via `Logger.info`. Phase 4 hardening or sooner if the
  recruiter dashboard goes live.
- **Recruiter signup / self-serve tenant creation** — out of v1 scope
  per PLAN §11 #8 (SAML/OIDC out of scope), but the code path
  (`Recruiters.request_magic_link/2` → `:not_found` for unknown email)
  is the natural extension point.
- **Drop `sessions.signed_token` column** once verified unused — the
  new bootstrap fields supersede it. Separate migration.

Carries forward from prior sessions still open:

- **Loadtest driver hardening**: re-HEAD on transport errors (Phase 1
  carry-forward).
- **Safari multi-question soak** on real hardware (Phase 2
  candidate-flow carry).
- **Fly transcode bench** (`shared-cpu-2x`, `dedicated-cpu-2x`) —
  PLAN §12.3 / §12.7 finalizer sizing.
- **`pageshow.persisted` BFCache between questions** (Phase 2
  candidate-flow carry).

## Phase-2 auth exit checklist

Rows from PLAN §7 Phase 2 this session covered:

- [x] Tenant model + JWT bootstrap tokens (single-use, ≤5 min) +
      upload bearer tokens (≤60 min, refreshable).

Closes one of the four still-open Phase-2 rows. The remaining three
(recruiter-recorded video prompts, image/PDF attachments, Whisper
transcripts) are independent and carry forward to the next session.

## Verification

```
mix precommit          # 179 tests, 0 failures
mix run priv/repo/seeds.exs   # mints dev recruiter + prints dev API key bearer
```

Manual end-to-end (Phoenix-running):

1. Create session via api key:
   `curl -X POST http://localhost:4000/api/sessions \
        -H 'Authorization: Bearer tk_<...>' \
        -H 'content-type: application/json' \
        -d '{"template_id":"<dev_template_id>"}'`
   → `{id, bootstrap_token, template_version_id}`.
2. `open "http://localhost:4000/capture/<id>?token=<bootstrap>"` — recorder loads.
3. Reload → "Session unavailable" (token consumed). Re-mint via
   `POST /api/sessions/:id/bootstrap`.
4. `curl -X POST .../api/auth/magic-links -d '{"email":"dev@example.com"}'`
   → 202 + URL in server logs → visit → cookie set → recruiter dashboard loads.
5. Inspect `/capture/:id?token=…` response headers:
   `content-security-policy: frame-ancestors 'self' http://localhost:5174 http://127.0.0.1:5174`
   reflecting the seeded dev tenant.
