# End-to-end tutorial

> Walk through the whole product, recruiter side and candidate side, on
> a fresh local checkout. No customer integration assumed — uses the
> built-in dev tenant + seeds.
>
> The four phases:
>
>   1. Author a template (recruiter UI).
>   2. Mint a session (API, or the `/capture/new` shortcut).
>   3. Record an answer (candidate UI).
>   4. Watch the recording back (recruiter UI).
>
> Customer-facing embed integration (postMessage, webhooks, frame
> ancestors) is in `docs/integration.md`. Manual browser regressions are
> in `docs/mvp-demo-checklist.md`. This doc is the gentler "drive every
> screen once" walkthrough.

## 0. One-time setup

```bash
mix setup           # deps + db create + db migrate + asset build
mix run priv/repo/seeds.exs
mix phx.server
```

`seeds.exs` is idempotent. It creates:

- Tenant `dev` (slug `dev`) with `frame_ancestors` allowlisting the
  local harness origins.
- `Dev Template` with one published version and one question.
- Recruiter user `dev@example.com` (role `owner`).
- A tenant API key — the secret prints **once** to stdout. Copy it
  somewhere if you plan to call the JSON API.

The server is now at `http://localhost:4000`.

## 1. Sign in as a recruiter

There is no password. Sign-in is magic-link.

```bash
curl -X POST http://localhost:4000/api/auth/magic-links \
     -H "Content-Type: application/json" \
     -d '{"email":"dev@example.com"}'
```

The Phoenix server log prints a line like:

```
magic_link_url=http://localhost:4000/auth/magic-link/<token> email=dev@example.com
```

Open that URL. The link is single-use, ≤15 min TTL, and on success
sets the recruiter session cookie and redirects you back to the app.

(Same form lives at `GET /auth/sign-in` if you'd rather click instead
of curl.)

## 2. Edit a template

Open `http://localhost:4000/recruiter/templates`. You'll see one row
per template for your tenant; click **Edit** to drop into the editor.
The same page has a **New template** form for creating one from
scratch.

The editor (`/recruiter/templates/:id`) shows:

- **Versions** — one published v1 plus a fresh draft (the page opens a
  draft on first visit so you always have somewhere mutable to edit).
- **Retake policy** — `max_attempts` and `mode` (`first_only` or
  `last`). Edits autosave on blur/change.
- **Questions** — autosave per field. Buttons to add, reorder (↑/↓),
  delete.

Try it:

1. Edit Q1's prompt to something you'll recognize on playback (e.g.
   "Walk me through your last shipping decision.").
2. Click **+ Add question** to make a Q2. Set its prompt.
3. Hit **Publish draft as v2**. The page reloads; "current" badge
   moves to v2; v1 stays around (sessions in flight keep their frozen
   `template_version_id`).

Schema notes — sessions reference an immutable `template_version`,
never a template. Editing v2 in the future will not touch any
already-recorded answer.

## 3. Mint a session for a candidate

Two paths:

### 3a. Dev shortcut (single-question demo)

```
http://localhost:4000/capture/new
```

The `CaptureSessionController` finds the `dev` tenant + `Dev Template`,
inserts a fresh `sessions` row, mints a bootstrap token, and redirects
to `/capture/<sid>?token=<bootstrap>`. This is the fastest way to "be a
candidate" without leaving the recorder origin.

(It also pins to the seeded `Dev Template` only — if you renamed or
deleted it the shortcut errors out.)

### 3b. Real flow (API)

This is what a customer backend would do. Use the API key secret
printed by `seeds.exs`:

```bash
curl -X POST http://localhost:4000/api/sessions \
     -H "Authorization: Bearer tk_<your-secret>" \
     -H "Content-Type: application/json" \
     -d '{"template_id":"<template-id>",
          "candidate_email":"alice@example.com"}'
```

Response carries `id`, `bootstrap_token`, and `template_version_id`.
Open `/capture/<id>?token=<bootstrap_token>` in a browser. Bootstrap
tokens are single-use; if the candidate reloads, mint another via
`POST /api/sessions/<id>/bootstrap`.

In production the candidate never sees these URLs — the SDK in
`docs/integration.md` mounts the recorder in an iframe with the
session id and bootstrap token passed through `mount()`.

## 4. Record an answer (candidate UI)

Open the capture URL in a real browser. (Headless / mobile UAs are
intentionally rejected — see `docs/mvp-demo-checklist.md` §5.)

Per question the flow is:

1. **Permissions prompt** on first record. Camera + mic + autoplay must
   all be granted.
2. **Prep / countdown** — optional `think_time_seconds` ticks down.
3. **Record** — MediaRecorder runs. Bytes are buffered in IndexedDB
   and uploaded via tus PATCHes to `/uploads/tus/...` in the background.
4. **Stop** — the JS hook flushes any remaining IDB chunks and posts
   `capture_complete` to `/sessions/:sid/responses/:rid/capture_complete`.
   The server transitions the row through `capture_complete → uploading
   → upload_complete → finalizing → ready`.
5. **Retake** — if the template's `max_attempts` allows it, the
   candidate can re-record. The retake policy decides which attempt
   becomes the playable one (`first_only` keeps the earliest, `last`
   keeps the latest and supersedes the prior selection).

After the last question the candidate sees the **review** screen and
clicks **Submit**. The session moves `submitted → ready` once every
required question has a `ready` response.

Quick sanity check from psql while a session is in flight:

```sql
SELECT attempt_number, state, bytes_uploaded, expected_total_bytes,
       finalized_at, storage_key
  FROM question_responses
 WHERE session_id = '<sid>'
 ORDER BY template_question_id, attempt_number;
```

You should see at least one row per question end up in `state =
ready` with a non-null `storage_key`.

The actual MP4 lands under the configured storage root. In dev:

```
priv/uploads/artifact/<storage_key>
```

`ffprobe` it to confirm playable frames and a duration roughly
matching what you recorded.

## 5. Watch the recordings (recruiter UI)

Sign in as recruiter (step 1) if you aren't already, then:

```
http://localhost:4000/recruiter/sessions
```

This is the playback dashboard added by `docs/playback-plan.md`:

- One row per session for your tenant.
- Filters: state (chip toggles) and template (dropdown). Filters live
  in the URL — back-button works, links are shareable.
- Click **Open** to drill into a session.

The session detail page shows one card per question with:

- The prompt as authored.
- A `<video controls preload="metadata">` whose `src` is
  `/recruiter/playback/<response_id>` — the browser handles seeking
  via HTTP `Range`; the controller streams the file from disk and
  responds `206` for ranged requests.
- Duration, attempt number, current state.
- Transcript text (collapsible) when the Whisper worker has filled it
  in. (Whisper only runs when `OPENAI_API_KEY` is set.)
- A debug expander listing every attempt with its storage key — only
  rendered for tenants whose slug starts with `dev`.

If you record on Q1, retake it once, and skip Q2, you should see Q1's
card pointing at the `selected_response` per the retake policy and
Q2's card with the empty-state copy ("No playable response yet.").

## 6. What's not covered here

- **Webhook delivery** — dev tenant has no `webhook_url`, so
  `webhook_deliveries` rows stay `pending`. To watch a real POST: set
  `tenants.webhook_url = "https://webhook.site/<uuid>"` and re-run a
  capture.
- **Customer embed** — the iframe SDK, parent-side
  `Permissions-Policy`, `frame-ancestors` allowlist, `popout()` — see
  `docs/integration.md`.
- **Browser matrix + soak** — `docs/mvp-demo-checklist.md` and
  `docs/safari-soak-checklist.md`.
- **Tigris/S3 playback swap** — `Interview.Storage` adapter behaviour
  is in place; the playback controller streams from local disk today.
  When the S3 adapter lands, the controller's body becomes a redirect
  to a presigned URL.
