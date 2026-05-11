# Embedding the interview recorder

> Integration guide for `@you/interview-embed`. Audience: a customer
> engineer dropping the recorder into their own web app.

## 1. The two-line integration

Paste these two tags into the page where the candidate should record. The
SDK is ~5 KB, no dependencies, single file.

```html
<div id="interview-mount" style="width:100%;height:600px"></div>

<script src="https://cdn.yourdomain.com/embed.v1.js"></script>
<script>
  YourInterview.mount('#interview-mount', {
    sessionId: '<from POST /api/sessions>',
    bootstrapToken: '<from POST /api/sessions>',
    onSubmitted: (e) => { /* candidate hit submit */ },
    onReady:     (e) => { /* recordings finalized; safe to fetch playback */ },
    onError:     (e) => { /* surface to the candidate */ },
  })
</script>
```

`iframeSrc` defaults to the origin where the SDK was loaded from — paste
the script tag from your CDN/recorder origin and you're done. Override it
explicitly only if the SDK and the recorder live on different hosts.

## 2. Mint a bootstrap token (server-to-server)

The bootstrap token is single-use, expires in ≤ 5 minutes, and is bound
to the session. Mint it from your backend, then hand it to the page. Do
**not** call `POST /api/sessions` from the browser — your tenant API key
must never reach a customer device.

```bash
curl -X POST https://interview.yourdomain.com/api/sessions \
     -H "Authorization: Bearer tk_<your_tenant_api_key>" \
     -H "Content-Type: application/json" \
     -d '{"template_id": "<your_template_id>", "candidate_email": "..."}'
```

Response:

```json
{
  "id": "01HX...",
  "bootstrap_token": "...",
  "template_version_id": "01HX..."
}
```

Render the page with `id` as `sessionId` and `bootstrap_token` as
`bootstrapToken`. If the candidate reloads, mint a fresh bootstrap via
`POST /api/sessions/{id}/bootstrap` (rotates the jti) and pass it again.

## 3. Required parent-side `Permissions-Policy`

The iframe inherits `camera`, `microphone`, and `autoplay` only if the
parent document delegates them. Without this, the browser silently denies
`getUserMedia()` and the candidate sees an unrecoverable permissions error.

```
Permissions-Policy: camera=(self "https://interview.yourdomain.com"),
                    microphone=(self "https://interview.yourdomain.com"),
                    autoplay=(self "https://interview.yourdomain.com")
```

If your CSP blocks inline scripts, the recorder iframe is exempt — the
policy applies to your page only.

## 4. Per-tenant `frame-ancestors` allowlist

The recorder iframe is locked to your origins by `Content-Security-Policy:
frame-ancestors ...` served from the recorder. Update the allowlist via
the recruiter dashboard (or the tenants admin API) **before** embedding.
Wildcards (`https://*.example.com`) require an explicit admin override —
any subdomain you don't control becomes a clickjacking vector.

## 5. Callbacks

```js
YourInterview.mount('#interview-mount', {
  sessionId, bootstrapToken,
  onPermissions: ({ type })       => {/* permissions_granted | permissions_denied */},
  onRecording:   ({ type, position, durationMs }) => {/* recording_started | recording_stopped */},
  onProgress:    ({ sessionId, percent })         => {/* aggregate upload progress */},
  onSubmitted:   ({ sessionId })  => {/* sessions.state = submitted */},
  onReady:       ({ sessionId })  => {/* sessions.state = ready    */},
  onError:       ({ code, message }) => {/* surface to candidate, log to your APM */},
})
```

All callbacks are best-effort. Trust the webhook (Phase 4) for the
authoritative state transition, not the postMessage event — the candidate
can close the tab between `submitted` and `ready`.

## 6. The "Continue in full window" escape hatch

Third-party iframes have unreliable storage (partitioned IndexedDB, no
guaranteed quota floor) and can lose the recorder if the parent page is
navigated. The SDK exposes `popout()` so the candidate can move the
session to a top-level tab on the recorder origin, where storage is
durable.

```html
<button id="popout">Continue in full window</button>
<script>
  const handle = YourInterview.mount('#interview-mount', {
    sessionId, bootstrapToken,
    onPopoutRequested: async ({ sessionId }) => {
      // Mint a NEW bootstrap from your backend. Never reuse the embed's
      // token — it's already been consumed by the iframe.
      const r = await fetch(`/api/internal/sessions/${sessionId}/bootstrap`, { method: "POST" });
      const j = await r.json();
      return { bootstrapToken: j.bootstrap_token };
    },
    onSubmitted: ...
  });

  // popout() must run from a user-gesture handler — browsers block popups
  // opened from anything else.
  document.getElementById('popout').addEventListener('click', () => handle.popout());
</script>
```

The pop-out URL opens with `noopener,noreferrer`; the embed iframe is
torn down so the popped-out tab is the sole writer for the session.

## 7. Lifecycle

```
+-------+   load    +--------------+  ready  +-----+  auth   +-------+
| host  | --------> | iframe       | ------> | SDK | ------> | iframe|
| page  |           | (capture LV) |         |     |         |       |
+-------+           +--------------+ <------ +-----+         +-------+
                            |  recording_started/stopped, upload_progress,
                            |  permissions_*, session_submitted, session_ready
                            v
                        host page (callbacks fire)
```

- `ready` from the iframe carries a random `channelId` nonce.
- Every subsequent message (in either direction) must carry that nonce.
- Origin, source window, and nonce are validated on both sides.

## 8. Webhooks

The webhook payload mirrors the postMessage events:

```json
{
  "v": 1,
  "type": "session.submitted" | "session.ready" | "session.failed" | "session.deleted",
  "tenant_id": "...",
  "session_id": "...",
  "external_id": "...",
  "occurred_at": "2026-…",
  "delivered_at": "2026-…",
  "data": {}
}
```

`v` is the payload schema version. Receivers should treat an absent `v`
as `v=1`.

Per-event `data` fields:

- `session.submitted` — `submitted_at` (ISO 8601), `responses_count` (int)
- `session.ready` — `completed_at` (ISO 8601), `responses_count` (int),
  `duration_total_ms` (int, sum of canonical answer durations)
- `session.failed` — `reason` (string)
- `session.deleted` — `reason` (`"retention"` | `"user_request"`)

Headers on every POST:

- `Content-Type: application/json`
- `User-Agent: interview-webhook/1`
- `X-Interview-Event: session.<type>`
- `X-Interview-Delivery-Id: <uuid>` — stable per (session, event_type)
- `X-Interview-Signature: sha256=<hex>` — HMAC-SHA256 over the raw body
  using your tenant's `webhook_secret`.

Verification (Node.js):

```js
const crypto = require("node:crypto");
const expected = "sha256=" + crypto
  .createHmac("sha256", process.env.WEBHOOK_SECRET)
  .update(rawBody)
  .digest("hex");
if (!crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(req.headers["x-interview-signature"]))) {
  return res.status(401).end();
}
```

Retries: any non-2xx that is **not** `408`/`429` is treated as a permanent
failure (drop and alert). 408/429/5xx and transport errors retry with
exponential backoff up to 14 attempts (~24h). The receiver sees the same
`delivered_at` and the same `X-Interview-Delivery-Id` on every retry —
de-dupe on those.

The schema is **append-only**: new fields may be added but never removed.
Receivers should ignore unknown fields.

## 9. Unsupported browsers

The SDK renders a "please complete this in desktop Chrome or Edge"
message instead of mounting the iframe when it detects any of:

- A mobile user agent (iOS Safari, Chrome Android, etc.).
- Firefox desktop.
- Safari desktop.

Firefox and Safari are deferred to v1.1 (PLAN decision #14); the
recording engine is currently tuned for Chrome/Edge only. To customise
the UX:

```js
YourInterview.mount('#mount', {
  ...,
  onUnsupportedBrowser: ({ email }) => {/* forward to your "send-me-the-link" endpoint */},
});
```

The handle's `unsupportedBrowser` flag is `true` in this case;
`mobile` is `true` only on mobile UAs (a strict subset). `unmount()`
clears the host element.

## 10. Browser support

**Desktop Chrome 100+ and Edge 100+ only** for v1. Firefox, Safari
macOS, and all mobile are out of scope; the SDK detects them and shows
a "please complete on a desktop Chrome or Edge browser" message instead
of mounting the iframe. Firefox + Safari are deferred to v1.1.
