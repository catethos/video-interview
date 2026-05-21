# Candidate UX overhaul — implementation plan

> Goal: bring the candidate-facing capture iframe up to industry-
> standard async video interview UX (HireVue / Willo / Spark Hire /
> VidCruiter parity). Today's surface has functional max-time
> auto-stop but no visible countdown, half-built think-time machinery,
> a recruiter-grade Release-camera button leaking into the candidate
> view, and no introduction / system-check / accessibility surface.
> This plan replaces those gaps with a single coherent flow.

## Scope (v1)

In scope:
- New `:intro` phase: camera/mic permission ask, brief intro copy
  (including the AI-evaluation disclosure), and an "I'm ready" gate
  before Q1.
- New `:permission_denied` phase with browser-specific re-enable steps.
- New `:practice` phase: a mandatory throwaway "tell us your name"
  question with playback, before scored Q1.
- Visible think-time countdown (italic phrase + hairline rule) with
  "Start recording now" skip.
- Manual "Start recording" click required when think-time ends
  (think-time is a soft maximum, per industry-default UX research).
- Visible recording-time countdown (italic numeral inside the video
  frame, hairline underline, last-5s amber).
- Auto-stop at `max_answer_seconds` (existing JS) plus explicit
  manual "Next question" click to advance (unchanged from today).
- Self-preview visible during think-time so candidates can fix
  framing before recording.
- Mic-level indicator + face-framing oval overlay on self-preview.
- Accessibility pass: aria-live (throttled) on countdowns,
  `:focus-visible` outlines, keyboard nav verified, caption track on
  recruiter prompt videos.
- Tab-focus telemetry: `visibilitychange` + `blur` events recorded
  per response; surfaced as "left tab N×" badge in the recruiter
  report (Pulsifi side).
- Remove the `data-action="release"` button from the candidate view.

Explicitly out of scope (carry to a later phase):
- AI bias audit (NYC LL144) — separate workstream.
- EU AI Act conformity assessment — separate workstream.
- Candidate ADA accommodation request path (e.g. opt for text-only
  answers) — separate workstream.
- GDPR retention sweeper (auto-delete recordings after
  `tenants.retention_days`) — separate workstream.
- Webcam proctoring (eye tracking, multi-person detection).
- Pause/resume mid-recording (industry consensus: do not add).
- Per-question retake configuration (lives on the template already,
  not touched here).

## Phase machine

Today (`capture_live.ex:10-18`):

```
:awaiting_auth → :prep → :recording → :draining → :answered → :review → :submitted
                                                                       ↘ :fenced
```

New:

```
:awaiting_auth → :intro → :practice → :prep → :recording → :draining → :answered → :review → :submitted
                  ↓                                                                          ↘ :fenced
            :permission_denied
```

- `:intro` is entered immediately after bootstrap is consumed. Replaces
  the previous "jump straight to Q1" behavior.
- `:practice` runs a single throwaway prompt; recordings under
  `practice_responses` (new table) — NEVER joined to scoring exports.
- `:permission_denied` is a terminal-ish phase (`:intro` → here on
  permission denied). Candidate can retry permission and re-enter
  `:intro` once granted.

## Routes

No new routes. All new behavior is inside the existing
`CaptureLive` mount.

## File-by-file changes

### VI repo

**`lib/interview_web/live/capture_live.ex`**
- Replace `initial_phase/2` so a fresh session starts at `:intro`,
  not `:prep`.
- Add `handle_event("intro_ready", ...)` → transitions `:intro` →
  `:practice` (or `:prep` if practice is disabled by template flag).
- Add `handle_event("permission_denied_retry", ...)` → re-enters
  `:intro` and re-arms permission prompt.
- Add `handle_event("start_thinktime", ...)` → arms a JS-driven
  countdown; the existing `think_time_tick` handler stays for
  the LV-side mirror.
- Add `handle_event("skip_thinktime", ...)` → fast-forward to a state
  where the candidate can click "Start recording".
- Add `handle_event("practice_done", ...)` → `:practice` → `:prep`.
- Add `handle_event("focus_lost", %{"at" => iso8601}, ...)` and
  `handle_event("focus_regained", %{"at" => iso8601}, ...)` →
  persist to new `question_response_focus_events` table when
  `:phase == :recording`.
- New `render_intro/1`, `render_permission_denied/1`,
  `render_practice/1` private functions.
- Update `render_recorder/1` to remove the
  `data-action="release"` button.
- Update `render_question/1` to add the think-time countdown line
  (`<p class="font-display italic ...">` with `phx-hook="ThinkTimeCountdown"`
  so the JS ticks the visible numerals without round-tripping the LV).
- Update `render_recorder/1` to add the recording countdown inside
  the video frame (absolute-positioned span anchored bottom-right
  inside `.preview-shutter`).
- Update telemetry / debug pane (gated behind `<details>`) to expose
  the new phases for QA, no behavior change.

**`lib/interview/capture.ex`** (context)
- Add `record_focus_event/3` (response_id, kind, at) that inserts a
  row into `question_response_focus_events`. Idempotent on
  `(response_id, occurred_at, kind)` to tolerate hook re-fires.
- Add `count_focus_losses/1` (response_id) → integer; called from
  the scoring-export builder.

**`lib/interview/external_integration/scoring_export.ex`**
- Add `focus_lost_count` to the transcript entry shape. Default 0.
- Source from `Capture.count_focus_losses/1` per response.

**`lib/interview_web/controllers/scoring_export_controller.ex`**
- Pass through the new field unchanged (existing shape encoder
  already passes through map keys).

**`assets/js/hooks/recorder.js`** + **`assets/js/recorder/core.js`**
- Remove the `"release"` event binding and the
  `releaseCamera()` candidate-action exposure (keep
  `releaseCamera()` internal for unmount cleanup only).
- Add a `MicLevel` `AnalyserNode` tied to the current MediaStream.
  The level updates a DOM element directly via `requestAnimationFrame`
  (no LV round-trip — pushing per-frame audio levels through
  Phoenix WebSocket would be wasteful). LV is told only "audio is
  detected" / "audio appears silent for >5s" as `mic_state`
  state-change events.
- Add `setupFocusTelemetry(hook)`: listen for
  `document.visibilitychange` and `window.blur`/`focus`; push
  `focus_lost` / `focus_regained` to the LV with ISO timestamps;
  enabled only while `:recording`. Coalesce repeated events
  within 250ms (some browsers fire blur+visibilitychange in pairs).

**`assets/js/hooks/think_time_countdown.js`** (new)
- Standalone hook attached to the countdown phrase element. Owns
  its own `setInterval`. Replaces the dead `think_time_tick`
  cycle that today does nothing visible.
- Emits `think_time_done` to LV when it hits zero (LV does NOT
  auto-advance; it shows the "Start recording" button).
- Cleans up on unmount.

**`priv/repo/migrations/<ts>_create_question_response_focus_events.exs`** (new)
```elixir
create table(:question_response_focus_events, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :response_id, references(:question_responses, type: :binary_id,
                                on_delete: :delete_all), null: false
  add :kind, :string, null: false  # "lost" | "regained"
  add :occurred_at, :utc_datetime_usec, null: false
  timestamps(updated_at: false)
end

create index(:question_response_focus_events, [:response_id])
create unique_index(:question_response_focus_events,
                    [:response_id, :occurred_at, :kind])
```

**`priv/repo/migrations/<ts+1>_add_is_practice_to_template_questions.exs`** (new)
- Add `is_practice :boolean, default: false, null: false` to
  `template_questions`. Practice rides the existing question /
  response / upload machinery — same `claim_instance`, same tus
  upload, same finalizer — instead of a parallel table. The
  scoring export filters `WHERE NOT is_practice`. Cleaner than
  a separate table because there's zero new code path for the
  recording itself; only the export-builder filter changes.
- On template draft creation, the entry-point LiveView (or a
  `Templates.ensure_practice_question/1` helper called from there)
  inserts a `is_practice: true` row at `position = 0` with a fixed
  `prompt_text` ("Say your name to test your camera and mic.")
  and `max_answer_seconds: 30`. Recruiter never sees this in the
  editor (filter `WHERE NOT is_practice` in the question-list query).

**`lib/interview/templates/version.ex`**
- Add `practice_enabled, :boolean, default: true` so a recruiter
  can opt out of the practice question per template version
  (default on, matches industry).

**`lib/interview_web/live/recruiter_template_live.ex`**
- Add a single checkbox in the version settings: "Require a
  practice question before the real interview" (default on).

### Pulsifi-demo repo

**`apps/backend/src/modules/scoring/service.ts`**
- Schema for the pipeline input row already has open shape; add
  `focus_lost_count` to the JSON-stringified `interview_transcript`
  entries.

**`apps/backend/src/db/schema.ts`**
- No schema changes — `p3_result` is JSONB, so the new
  `focus_lost_count` field rides through to the report unchanged.

**`apps/frontend/src/routes/recruiter/ScoringReportPage.tsx`**
- Read `focus_lost_count` off the P3 row (`q.p3Entry`).
- Render small italic badge next to the question score: "left tab
  2× during this answer". Hidden when count is 0.

## Tests

### Elixir

**`test/interview_web/live/capture_live_test.exs`** (extend)
- `:awaiting_auth` → `:intro` on bootstrap consume.
- `:intro` → `:practice` on `intro_ready`.
- `:intro` → `:permission_denied` on `permission` payload `state: "denied"`.
- `:permission_denied` → `:intro` on `permission_denied_retry`.
- `:practice` → `:prep` on `practice_done`.
- Think-time countdown LV-side mirror updates `think_time_remaining`
  on `think_time_tick`.
- `focus_lost` during `:recording` inserts a focus event row.
- `focus_lost` outside `:recording` is silently dropped.
- Idempotent: same `(response_id, occurred_at, kind)` inserts once.

**`test/interview/capture_test.exs`** (extend)
- `record_focus_event/3` happy path.
- `count_focus_losses/1` counts only `kind: "lost"` (regained
  events are paired diagnostics, not weighted).

**`test/interview/external_integration/scoring_export_test.exs`** (extend)
- Export payload includes `focus_lost_count: 0` when none recorded.
- Export payload reflects the actual count when events exist.

### JS

The repo has no Jest/Vitest harness today (per `assets/` layout).
Hook behavior is validated via:
- Manual smoke per browser (Chrome/Firefox/Safari, macOS + iOS).
- LV-side assertions on the events the hook is expected to push.

### Manual cross-browser pass

- Chrome (macOS + Android), Firefox (macOS), Safari (macOS + iOS).
- Permission denied → re-grant flow works.
- Network drop during `:recording` → recovery (existing tus retry
  path; just verify the countdown doesn't drift).
- Tab switch during `:recording` → `focus_lost` recorded; tab
  return → `focus_regained` recorded; pairs visible in DB.
- Refresh during think-time → re-enters `:prep` at correct question
  (existing assign-reset path handles this).
- Refresh during recording → existing fence behavior (the candidate
  hits `:fenced`; unchanged).

## Open / deferred decisions

1. **Practice question prompt text** — fixed string ("Say your name to
   test your camera and mic") or recruiter-editable per template?
   v1: fixed string. Recruiter-editable is a future polish.
2. **Mic-level threshold for "audio working" check during practice** —
   v1: visual indicator only, no hard gate. If the candidate's mic
   reads silent for 5s, show a soft warning. No block.
3. **Caption auto-generation on recruiter prompt videos** — Whisper
   side or recruiter-uploads-VTT? v1: recruiter uploads. Whisper
   auto-gen is a follow-up if recruiter friction is too high.
4. **Tab-focus telemetry retention** — keep forever or expire with the
   response? v1: cascade on response delete (FK with
   `on_delete: :delete_all`).

## Rollout

This is a single feature branch off `feature/external-integration-v1`.
Commit boundaries match the task list:
1. Design doc (this file).
2. Phase 1a: intro + permission-denied + remove Release button.
3. Phase 1b: countdowns + manual advance + self-preview.
4. Phase 2: practice + mic-level + framing guide.
5. Phase 2: accessibility pass.
6. Phase 3: tab-focus telemetry + Pulsifi dashboard surface.
7. Cross-browser + final review.

Each commit must pass `mix test`, `mix credo`, and `mix sobelow` clean.
No `--no-verify`. No skipping hooks.
