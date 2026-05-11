# Phase 3 — embed SDK (`@you/interview-embed`)

> Status as of 2026-05-08.
> Builds the customer-facing SDK + parent-side postMessage protocol on
> top of the auth handshake landed in phase2-findings-auth.md. Tests
> 183 → 190 (Elixir) + 8 new JS unit tests. `mix precommit` green.
> Closes PLAN §7 Phase 3.

## What was built

| Capability | Where | Status |
|---|---|---|
| `@you/interview-embed` SDK source — single-file IIFE, no deps, ~5 KB minified. Public API: `YourInterview.mount(target, opts)` returning `{iframe, unmount, popout, start, pause, resume, setLocale, mobile}`. `iframeSrc` defaults to the script's own origin (`document.currentScript.src`) so a paste-in `<script src=…/embed.v1.js>` is the whole integration. | `assets/embed/index.js` | ✅ |
| esbuild profile `:embed` builds the SDK to `priv/static/embed.v1.js`. Wired into `assets.build` / `assets.deploy` and the dev `watchers` so iteration is fast. `static_paths` extended with `embed.v1.js` so `Plug.Static` serves `/embed.v1.js` directly. | `config/config.exs`, `config/dev.exs`, `mix.exs`, `lib/interview_web.ex` | ✅ |
| postMessage protocol v1 (parent side, PLAN §4.3): captures iframe `contentWindow` + URL origin + the `channelId` nonce sent in `ready`; posts `auth` to the **specific iframe origin** (never `'*'`); validates every inbound message against (source, origin, channelId, schema); silently drops unknowns. `bootstrapTokenInUrl: true` opts into the `?token=` fallback (auth postMessage is then skipped). | `assets/embed/index.js` | ✅ |
| postMessage protocol v1 (iframe side): the recorder hook captures the parent's origin from the first valid inbound v=1 message and locks it; subsequent outbound posts target that origin. Hook now emits `permissions_granted/denied` (on `getUserMedia`), `recording_started` / `recording_stopped` (on recorder lifecycle), and `upload_progress` (on every `reportProgress` tick). | `assets/js/hooks/recorder.js` | ✅ |
| LV-driven outbound messages (`session_submitted`, `session_ready`): `CaptureLive` `push_event "post_to_parent"` payloads that the hook relays via `window.parent.postMessage(payload, parentOrigin || '*')`. Submit emits both events when `submit_session/1` rolls up to `ready` synchronously; mount on a session already at `submitted`/`ready` re-emits so a candidate revisiting the page sees the host's success UI. | `lib/interview_web/live/capture_live.ex` | ✅ |
| Pop-out escape hatch (PLAN §5.5): SDK `popout()` opens a placeholder window synchronously (preserves the user-gesture), then awaits the customer-supplied `onPopoutRequested` callback for a fresh bootstrap, navigates the popup with `noopener,noreferrer`, and tears the embed iframe down. Handles the popup-blocked case via `onError({code: "popup_blocked"})`. | `assets/embed/index.js` | ✅ |
| Demo harness page reworked to drive the SDK end-to-end. Pulls `embed.v1.js` cross-origin from `http://localhost:4000`, mounts via `YourInterview.mount`, wires every callback to a debug log, and exercises `popout()` with a real `onPopoutRequested` (re-bootstraps via the harness's existing `/session/:id/bootstrap` endpoint). | `priv/harness/index.html` | ✅ |
| Integration docs for customer engineers — install, mint a bootstrap, mount, required `Permissions-Policy`, per-tenant `frame-ancestors`, pop-out flow, callbacks, webhook preview. | `interview/docs/integration.md` | ✅ |
| 8 JS unit tests (Node `node:test`, no deps): `ready` handshake captures channelId; auth posts to the iframe origin (not `'*'`); messages from the wrong source / origin / channelId are dropped; every protocol type fires its callback; unknown types are no-oped; messages before `ready` are dropped; URL-fallback skips the `auth` post. Run with `node --test assets/embed/__tests__/sdk.test.js`. | `assets/embed/__tests__/sdk.test.js` | ✅ |
| 4 new Elixir tests: parent_origin captured from auth payload; blank/`null` origin ignored; submit emits both `session_submitted` and `session_ready` push_events; harness page references `embed.v1.js` and calls `YourInterview.mount`; embed bundle smoke test (size budget, surface check). | `test/interview_web/live/capture_live_test.exs`, `test/interview_web/harness_router_test.exs`, `test/interview_web/embed_bundle_test.exs` | ✅ |
| **Deleted** `priv/sdk/embed.v1.js` (Phase-0 stub; replaced by the built bundle at `priv/static/embed.v1.js`). | — | ✅ |

## Decision-log changes

None. Phase 3 implements PLAN §3.1 / §4.1 / §4.3 / §4.4 / §5.5 / §7
Phase 3 / §11 #8 as written.

## Gotchas worth knowing for next session

- **`document.currentScript` is null after async eval** — only set during
  the synchronous evaluation of a `<script src=...>` tag. The SDK
  captures `DEFAULT_IFRAME_SRC = scriptOrigin()` at IIFE eval time so
  it's still available at `mount()` call time. If a customer dynamically
  injects the script (e.g. via `import()`), `currentScript` is null and
  `iframeSrc` MUST be passed explicitly. Documented in
  `interview/docs/integration.md`.
- **postMessage `event.origin === "null"`** is what browsers send for
  `file://` and sandbox-without-allow-same-origin frames. The hook
  treats `"null"` as "no origin captured" so we don't lock onto a
  bogus value; falls back to `'*'` for outbound posts in that case.
  The LV's `capture_parent_origin/2` makes the same exclusion.
- **Pop-out gesture must be synchronous to `window.open`** — Chrome/Safari
  block popups that open after an `await`. The SDK opens an empty popup
  synchronously, then navigates it once `onPopoutRequested` resolves.
  Customers MUST call `handle.popout()` from the click handler, not from
  a `setTimeout` or a Promise chain rooted off-gesture.
- **The minified bundle is 5,070 bytes** (PLAN §3.1 budget: ~5 KB). Adding
  a UUID lib, a fetch polyfill, or a Promise polyfill would blow this.
  Stay vanilla; `crypto.randomUUID()` and native `Promise` are part of
  the desktop browser support matrix in §8.4.
- **`render_hook` doesn't return the LV's `:reply` payload** — the
  Phase-2-auth gotcha applies to the new `auth` event tests too. Use
  `:sys.get_state(view.pid).socket.assigns` to assert state mutations
  triggered by the hook event, or `assert_push_event/3` for outbound
  push_events.
- **`assert_push_event` on `post_to_parent` is the seam between LV and
  hook** — it's the *only* server-side handle on the postMessage
  protocol. JS tests cover the parent half. The actual cross-frame
  message flow is exercised manually via the harness page; there's no
  Elixir-side end-to-end browser test for it.
- **Iframe `allow=` is parent-controlled** — the iframe element's
  `allow="camera; microphone; autoplay; fullscreen"` only takes effect
  if the parent's `Permissions-Policy` *also* delegates the same
  features to the iframe origin. Forgetting the parent-side
  `Permissions-Policy` was the most likely "permissions denied" bug in
  Phase-0 testing; it's now the second item in the integration docs.
- **ES2017 target, not ES2022** — the recorder bundle (`js/app.js`)
  targets ES2022 because LiveView ships modern JS, but the customer-
  embedded SDK has to load on whatever ancient enterprise browser the
  customer's app supports. ES2017 covers async/await + spread; older
  browsers fail loudly when `MediaRecorder` is also missing, so it's
  the same support floor.
- **`embed_esbuild` watcher in dev** — there's now a second esbuild
  process running under `mix phx.server`. Kill it via the standard
  `mix phx.server` shutdown; if the dev experience hangs, check
  `lsof -i :4000` and the watcher PIDs.
- **Postgres-side parent_origin is observability-only** — it's stored
  in `socket.assigns.parent_origin` so tests can assert capture, but
  the actual targetOrigin enforcement happens in the JS hook. Don't
  assume the LV alone gates outbound messages; the hook is the writer.

## Carries into next session

Inputs the next session should pick up:

- **Webhook delivery (PLAN §7 Phase 4)**. The postMessage
  `session_submitted/ready` events are best-effort — the candidate can
  close the tab between transitions. Webhooks are the durable
  notification surface. Schema documented in
  `interview/docs/integration.md` §8.
- **`session_ready` emit on async finalizer completion**. Today the LV
  emits `session_ready` only when `submit_session/1` synchronously
  rolls the state to `ready` (the test path) or when the candidate's
  page is connected and assigns are reloaded. Production finalizers
  are async, so a candidate watching the page misses the `ready`
  event. Wire `Phoenix.PubSub` `session:<id>` (PLAN §3.3 already
  references this topic) and have CaptureLive subscribe + emit on
  state-change broadcasts.
- **JS test runner** in `mix precommit`. Tests pass with `node --test
  assets/embed/__tests__/sdk.test.js` but `mix precommit` doesn't run
  them. Add a Mix.Task wrapper that gracefully skips when Node is
  absent (CI may not have it; local devs do).
- **Visual indicator of pop-out availability** — the SDK exposes
  `popout()` but doesn't render any UI. Customers wire their own
  button. Consider a default in-iframe banner (rendered by the LV's
  `pauseForQuota` path, PLAN §5.1) that links to the customer's
  pop-out handler via a `request_popout` postMessage event.
- **`onError` from the iframe → SDK** — the hook emits some local
  errors via `pushEvent("recorder_error", …)` but doesn't relay
  them to the parent SDK. Wire a `post_to_parent` for the codes
  that are interesting to the host (`mobile_unsupported`,
  `quota_pause`, `claim_failed`).
- **Recruiter-recorded video prompts + image/PDF attachments** —
  Phase-2 carry. Independent of Phase 3.
- **Whisper transcript Oban job** — Phase-2 carry. Independent.
- **Drag-handle reorder polish** — Phase-2-authoring carry.
- **Think-time countdown UI** — Phase-2-candidate-flow carry.
- **`pageshow.persisted` BFCache between questions** — Phase-2
  candidate-flow carry.
- **Loadtest driver: re-HEAD on transport errors** — Phase 1 carry.
- **Safari multi-question soak on real hw** — Phase 2 candidate-flow
  carry.
- **Fly transcode bench (`shared-cpu-2x`, `dedicated-cpu-2x`)** —
  PLAN §12.3 / §12.7 finalizer sizing.
- **Drop `sessions.signed_token`** once verified unused (carry from
  auth session).
- **Swoosh for real magic-link email** (carry from auth session).
- **JSON-as-import body** on `/api/templates/:id/import` (auth carry).
- **Asset-reference existence checks in importers** (auth carry).
- **CDN hosting of the SDK bundle** is out of scope this phase but
  is the production deploy concern: the bundle today is served from
  `priv/static/embed.v1.js` via `Plug.Static`; production should
  CDN-front it with long cache + `embed.v1.js` versioned filename.

## Phase-3 exit checklist

Rows from PLAN §7 Phase 3 this session covered:

- [x] `@you/interview-embed` JS package, ~5KB. (5,070 bytes minified.)
- [x] iframe injection with correct `allow=` and parent
      `Permissions-Policy` documentation.
- [x] postMessage protocol v1: origin + `event.source` + `channelId`
      nonce + schema validation.
- [x] Per-tenant `frame-ancestors` CSP from stored config (no JWT echo,
      no wildcards by default). _Already shipped in Phase 2 auth; this
      session validated it via the harness on the cross-origin path._
- [x] "Continue in full window" escape hatch with single-use pop-out
      bootstrap token + `noopener,noreferrer`.
- [x] Demo host page on a separate origin; integration docs.

All Phase-3 boxes ticked.

## Verification

```
mix precommit                                    # 190 Elixir tests, 0 failures
node --test assets/embed/__tests__/sdk.test.js   # 8 SDK unit tests
mix esbuild embed --minify                       # bundle ≈ 5,070 bytes
```

Manual end-to-end (Phoenix-running):

1. `mix esbuild embed` (one-time; the dev watcher does this in `mix
   phx.server`).
2. `mix phx.server` — Phoenix on `:4000`, harness on `:5174`.
3. Open `http://localhost:5174/`. The page mounts the iframe via the
   SDK; the debug log streams `onReady` / `onPermissions` /
   `onRecording` / `onProgress` / `onSubmitted`.
4. "Continue in full window" opens a top-level recorder tab on
   `localhost:4000` with a fresh bootstrap; the embed unmounts.
5. DevTools network tab: `embed.v1.js` is fetched cross-origin from
   `localhost:4000`, no CORS errors. iframe's CSP header reads
   `frame-ancestors 'self' http://localhost:5174 http://127.0.0.1:5174`
   from the seeded dev tenant.
