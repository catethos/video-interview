# Recruiter playback UI — implementation plan

> Goal: a recruiter signed into the dev tenant can browse interview
> sessions and watch the recorded answers alongside each question.
> Local-storage-first; same surface should swap to Tigris/S3 presigned
> URLs later by changing only the playback controller.

## Scope (v1)

In scope:
- Session list page for the recruiter's tenant.
- Per-session detail page that pairs each question with its `<video>`
  player + duration + (if present) transcript text.
- Playback endpoint that streams the MP4 from local storage behind
  recruiter session auth + tenant scope.

Explicitly out of scope (carry to v2):
- Retake history UI (show only `selected_response_id` for v1; retake
  attempts visible in a JSON debug panel).
- Comments / scoring / sharing.
- Bulk export / CSV.
- Tigris presigned-URL swap. Mentioned in the playback section so the
  controller's seam is obvious, not built.

## Routes

```
live_session :recruiter, on_mount: [{InterviewWeb.UserAuth, :ensure_recruiter}] do
  live "/recruiter/sessions",            RecruiterSessionsLive, :index
  live "/recruiter/sessions/:id",        RecruiterSessionLive,  :show
  get  "/recruiter/playback/:response_id", PlaybackController, :show
end
```

The playback controller sits inside `live_session :recruiter` so the
recruiter session cookie + tenant scope check apply uniformly. The
`<video src>` is the playback URL; the browser sends the cookie
automatically since it's same-origin.

## Auth + tenant scope

Reuses what's already there:
- `InterviewWeb.UserAuth.:ensure_recruiter` assigns
  `:current_scope = %{recruiter: …, tenant: …}` and `:tenant`.
- Every query in this feature filters by `socket.assigns.tenant.id`.
- `PlaybackController` reads the recruiter token from the session
  (same path the LV `on_mount` uses) and rejects on tenant mismatch.

No new auth code. No magic-link or token additions.

## Data shape

No schema changes. All queries land in a new `Interview.Playback` context:

| Function | Returns |
|---|---|
| `list_sessions(tenant_id, opts)` | sessions with template name, version number, total duration sum, question count, `completed_at`, `state`. Ordered `completed_at desc, inserted_at desc`. |
| `get_session(tenant_id, session_id)` | session + template version + ordered questions, each with the selected `question_response` (joined via `session_questions.selected_response_id`) and its `transcript_text`, `duration_ms`, `storage_key`, `state`. |
| `get_response_for_playback(tenant_id, response_id)` | the response row plus its session's tenant_id, used to gate the playback controller. |

Index check: `sessions(tenant_id, completed_at)` already covered by
`tenant_id`; if the list page is slow at scale we can add a composite
later (not v1). `question_responses` is keyed on session_id already.

## Pages

### `RecruiterSessionsLive` (`/recruiter/sessions`)

Layout: `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
Single-column table.

Columns: candidate email · template + version · state badge ·
completed_at · # questions · total duration · "Open" link.

Filters (v1): state (multi-select: `submitted`, `ready`, `failed`,
`expired`); template (single-select). Both update the URL via `patch`
so the back button works.

Stream: `stream(socket, :sessions, …, reset: true)` per
phoenix-liveview guidelines. Empty state via Tailwind `only:block`.

### `RecruiterSessionLive` (`/recruiter/sessions/:id`)

Header: candidate email · template name · version number · state
badge · completed_at · webhook delivery summary
(N submitted / N ready, taken from `webhook_deliveries`).

Body — ordered list of questions. Per question card:

```
1. [prompt markdown rendered]
   ┌─────────────────────────────────────┐
   │   <video controls preload="metadata"/>│
   └─────────────────────────────────────┘
   Duration 1:24 · attempt 2 of 2 (1 retaken)
   [transcript: "…" — collapsed by default, expandable]
```

The `<video>` `src` is `/recruiter/playback/<response_id>`. No client-
side state — the browser handles seeking via HTTP Range requests
served by `PlaybackController`.

Markdown rendering: same path as the candidate UI uses for prompts
(already in the codebase if Phase 2 shipped it; otherwise minimal
allowlist via the existing helper).

Debug expander at the bottom: raw question_responses rows (all
attempts) + transcript metadata. Only visible when
`current_recruiter.email` ends in the dev tenant.

## Playback controller

```elixir
get "/recruiter/playback/:response_id", PlaybackController, :show
```

Flow:
1. Verify recruiter token from session (same path as LV on_mount).
2. `Playback.get_response_for_playback/2` — must match recruiter's
   tenant; else 404 (deliberately not 403 — don't leak existence).
3. Response must be in `ready` state and have a non-nil `storage_key`;
   else 404.
4. Resolve path: `Interview.Storage.artifact_path(storage_key)`.
5. Stream the file with `Range` support:
   - Use `Plug.Conn.send_file/5` with `offset`/`length` parsed from
     the `Range` header.
   - Set `Content-Type: video/mp4`, `Accept-Ranges: bytes`,
     `Content-Length`, `Cache-Control: private, max-age=60`.

Tigris/S3 swap (deferred): the same controller body becomes
`redirect(to: Storage.presigned_url(storage_key, ttl: 60))`. The seam
is `Interview.Storage.playback_url/2`, which on `Local` returns the
controller's own URL and on `S3` returns a presigned URL. Not built
in v1; the controller streams directly today.

## Files added / changed

New:
- `lib/interview/playback.ex` — context.
- `lib/interview_web/live/recruiter_sessions_live.ex` — list.
- `lib/interview_web/live/recruiter_session_live.ex` — detail.
- `lib/interview_web/controllers/playback_controller.ex`.
- `test/interview_web/live/recruiter_sessions_live_test.exs`.
- `test/interview_web/live/recruiter_session_live_test.exs`.
- `test/interview_web/controllers/playback_controller_test.exs`.

Changed:
- `lib/interview_web/router.ex` — three new routes inside
  `live_session :recruiter`.
- (maybe) `lib/interview/fixtures.ex` — add `with_artifact!/1` helper
  to put a fake MP4 on disk under the test response.

## Tests

| Test | File | Asserts |
|---|---|---|
| Sessions index renders only this tenant's sessions | `recruiter_sessions_live_test.exs` | other-tenant rows are not in the rendered HTML. |
| Filter by state narrows the list | same | url patch updates the stream. |
| Session detail renders one card per question | `recruiter_session_live_test.exs` | DOM has N `<video>` tags; each `src` is the playback URL for the selected response. |
| Session detail 404s for another tenant's session | same | mount redirects (or live raises). |
| Playback returns 200 + correct headers for a ready response | `playback_controller_test.exs` | content-type, accept-ranges, content-length. |
| Playback 404 for response in non-ready state | same | response in `uploading` is hidden. |
| Playback 404 for another tenant's response | same | tenant scoping enforced. |
| Playback honours Range header | same | `Range: bytes=0-99` returns 206 + correct slice. |

Targeting 6–8 new tests; suite stays well under 5 s.

## Manual demo path

1. `mix phx.server`.
2. `mix run priv/repo/seeds.exs` — prints a recruiter magic link.
3. Click the magic link → recruiter dashboard.
4. Navigate to `/recruiter/sessions`. The seeded session from the
   harness flow should appear; click in.
5. Each question shows the recorded video. Hit play, scrub, confirm
   `<video>` works.

If no real recordings exist yet, the manual flow is: record one via
the harness (§MVP demo checklist §1), wait for `state=ready`, then
follow the steps above.

## Effort

~½ day for the playback controller + sessions list + detail LV with
basic filters, no transcripts. +2-3 h to wire transcript display and
the retake history JSON debug panel. Most of the time is in the
detail-page polish (markdown rendering, layout); the data plumbing is
straightforward Ecto + LV streams.

## Carries (not blocking v1)

- Presigned-URL swap when Tigris adapter lands.
- Comments / scoring panel.
- Multi-attempt UI (retake history visible inline, not in a debug
  panel).
- Audit-log entry on each playback (cheap; one row per `<video>`
  load).
- Download original MP4 button with `Content-Disposition: attachment`.
