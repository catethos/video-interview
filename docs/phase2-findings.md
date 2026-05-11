# Phase 2 — candidate multi-question flow + retake, findings

> Status as of 2026-05-07.
> Phase-2 candidate-flow code lives across `lib/interview/capture.ex`,
> `lib/interview_web/live/capture_live.ex`, `assets/js/hooks/recorder.js`,
> and `test/support/fixtures.ex`.
> Tests: `mix precommit` green, 58 tests (was 44 at Phase 1 exit).
>
> Phase 2 has more outstanding work — recruiter authoring UI, importers,
> tenant/JWT, transcript job. See "Carries into next session" and the
> remaining unchecked rows in PLAN §7 Phase 2.

## What was built

| Capability | Where | Status |
|---|---|---|
| `Interview.Capture` helpers: `list_questions/1`, `ensure_session_questions/1`, `get_session_question/2`, `list_session_questions/1`, `get_template_version!/1`, `max_attempts_for/2`, `max_attempt_number/2`, `list_responses_for/2`, `submit_session/1` | `lib/interview/capture.ex` | ✅ |
| `mark_ready/2` applies template_version `retake_policy` (`first_only` / `last`) → `session_questions.selected_response_id`; under `last`, supersedes the prior `ready` response (PLAN §3.2). `best` remains deferred. | `lib/interview/capture.ex` | ✅ |
| `rollup_session/1` now gates on `state == "submitted"` and required-only — `in_progress` sessions are not promoted by `mark_ready` alone (PLAN §3.2 state machine: pending → in_progress → submitted → ready) | `lib/interview/capture.ex` | ✅ |
| `submit_session/1` — required questions must have a response in `[capture_complete, uploading, upload_complete, finalizing, ready]`; immediately re-runs `rollup_session` so a Submit click that arrives after every finalize already finished promotes straight to `ready` | `lib/interview/capture.ex` | ✅ |
| `CaptureLive` multi-question phase machine: `:prep → :recording → :draining → :answered → :review → :submitted | :fenced`; `current_index`/`total_questions` derived from the session's frozen `template_version_id`; review screen with per-question status; Submit button | `lib/interview_web/live/capture_live.ex` | ✅ |
| Camera stream stays live across questions (PLAN §5.1); LiveView pushes `set_question` per transition with `{questionIndex, attemptNumber, maxAnswerSeconds, minAnswerSeconds}`; recorder.js applies via `handleEvent` so `phx-update="ignore"` can stay on the recorder div (the `<video>` element keeps its `srcObject`) | `lib/interview_web/live/capture_live.ex`, `assets/js/hooks/recorder.js` | ✅ |
| Per-question UI: required-vs-optional Skip; Re-record gated by `max_attempts_override ?? retake_policy.max_attempts`; soft-floor warning if `durationMs < min_answer_seconds * 1000` (advance still allowed — soft floor, not a hard gate) | `lib/interview_web/live/capture_live.ex` | ✅ |
| `armAutoStop` triggers `stopRecording({reason: "max_answer_seconds"})` at the per-question hard cap; `recorder_stopped` event carries `durationMs` for the soft-floor check | `assets/js/hooks/recorder.js` | ✅ |
| `capture_complete_acked` payload carries a fresh `{queuedChunks, queuedBytes}` IDB drain snapshot taken immediately before `sendCaptureComplete`; LiveView logs a warning if non-empty (closes the Phase 1 carry-forward instrumentation) | `assets/js/hooks/recorder.js`, `lib/interview_web/live/capture_live.ex` | ✅ |
| `Interview.Fixtures.graph_with_questions!/2` — N-question setup with version retake_policy override, used by the new tests | `test/support/fixtures.ex` | ✅ |
| LiveView tests: iteration walks all questions, required-skip rejected, retake creates `attempt+1` and supersedes prior on `ready`, `max_attempts` blocks retake, submit gate blocks while a required question is unanswered, submit promotes to `ready` once finalizers ran | `test/interview_web/live/capture_live_test.exs` | ✅ |
| Capture context tests: rollup only fires from `submitted`, `submit_session` gate, `first_only` vs `last` retake policy, `ensure_session_questions` idempotency, `max_attempts_override` wins | `test/interview/capture_test.exs` | ✅ |

## Partial / known gaps

- **Think-time countdown is not user-visible.** `:think_time_remaining`
  and a `think_time_tick` handler are scaffolded in `CaptureLive`, but
  no `Process.send_after(self(), :think_tick, 1000)` ever fires — the
  handler is currently dead code. The candidate sees
  `think_time_seconds` rendered as static metadata (e.g. "Think-time:
  30s") in the question card, but there is no enforced wait and no
  countdown UI before "Start recording" becomes pressable. To close
  this: on `:prep` entry with a `think_time_seconds` set, schedule a
  1s tick; in `handle_info(:think_tick, …)` decrement and re-schedule
  while > 0; gate the `start` button (or just display the count and
  let the candidate decide). ~20 lines.
- **`pageshow.persisted` BFCache path between questions** — the new
  `:prep`/`:answered`/`:review` phases have no active recorder, so a
  Back-navigate-and-return would now (in principle) hit BFCache. The
  Phase 1 finding ("Chrome declines BFCache for active recorders")
  doesn't apply during these idle phases. Not exercised this session;
  carry to the Safari multi-question soak.

## Numbers gathered

This session was code-only — no fresh load test or transcode bench.
Phase 1 numbers (50/100 uploader load test, ~9× realtime VP9→H264 on
Apple Silicon `veryfast`) still stand and should be re-validated when
the work calls for it.

The drain-check instrumentation (PLAN §5.1 invariant: `capture_complete`
must follow IDB drain) is wired but **not yet triggered in practice** —
every `capture_complete` observed in dev/test arrived with
`queuedChunks=0`, matching the PLAN-correct path. The Phase 1 finding
("buffer-progress event landed at capture-complete time with
`bytesBuffered=716689`") is now actively monitored: `recorder.js`'s
`snapshotDrain` samples IDB *immediately before* sending the explicit
EOF, so any future occurrence will produce a server-side warning log
with `response_id` and exact `queued_bytes` / `queued_chunks`.

## Decision-log changes

No PLAN §11 decisions overturned. Two clarifications worth recording:

1. **`sessions.state` strictly progresses via `submitted`.** Phase 1's
   `rollup_session/1` could promote `in_progress → ready` directly when
   all responses were ready, which short-circuited the state machine in
   PLAN §3.2. Phase 2 corrects this: rollup only fires from
   `submitted`, and the candidate clicking "Submit" is the gate. One
   Phase 1 test ("promotes the session to ready when all responses are
   ready") was reframed accordingly.
2. **Retake policy semantics, locked**:
   - `first_only` — `selected_response_id` is set on the first `ready`
     attempt and never updated. Subsequent retakes still create new
     `question_responses` rows but are not selected.
   - `last` — `selected_response_id` always points to the most recent
     `ready` attempt; the previous selection's `state` is moved to
     `superseded` so retention/UI no longer treat it as a candidate
     answer.
   - `best` — deferred per PLAN §3.2 note.

   Cap is `max_attempts_override ?? retake_policy.max_attempts`,
   enforced both in the LiveView (Re-record button only renders when
   `used < cap`) and on the server (the retake handler re-checks before
   advancing).

## Gotchas worth knowing for next session

- **`session_questions` rows are now created lazily** on `CaptureLive`
  mount via `Capture.ensure_session_questions/1`. If a future code
  path creates sessions through a different route (e.g. a `POST
  /api/sessions` endpoint from a customer backend), call
  `ensure_session_questions/1` there too. The retake-policy logic in
  `mark_ready` materialises a missing row on demand, but the candidate
  UX assumes the rows already exist for `current_index`/review
  rendering.
- **`SessionQuestion.inserted_at` is `:naive_datetime`** (the default
  `timestamps()` macro), not `:utc_datetime_usec` like Session/Response.
  `ensure_session_questions/1` truncates `NaiveDateTime.utc_now/0` to
  seconds for `insert_all`. If you change this column type, also update
  the `insert_all` call.
- **`phx-update="ignore"` stays on the recorder div.** Removing it
  re-renders the `<video>` element on every assigns change and loses
  its `srcObject`. All per-question state changes are pushed via
  `handleEvent("set_question", …)` — never via data-* attribute
  updates.
- **`render_hook` does not return the LiveView's `:reply` payload.**
  In tests, `render_hook(view, "claim_instance", …)` returns the
  rendered HTML, not the `%{ok: true, responseId: …}` reply that the
  real JS hook receives. The Phase 2 test helper (`simulate_answer`)
  reads the response back from the DB via
  `Capture.get_response_by_attempt/3` instead.

## Carries into next session

Inputs the next session should pick up:

- **Recruiter authoring UI + importers + REST API** (PLAN §3.4 / Phase
  2 checklist): LiveView template builder with drag-handle reorder,
  autosave drafts, "Publish"; YAML and markdown-with-frontmatter
  importers; JSON API. All three normalise to the same intermediate
  `TemplateVersion` struct, validated by one validator with line-number
  / JSON-pointer error messages.
- **Tenant model proper + JWT bootstrap (single-use, ≤5 min) + upload
  bearer (≤60 min, refreshable)** (PLAN §4.2). Gates the Phase 3
  embed SDK.
- **Whisper transcript Oban job** per `question_response` (PLAN §11
  decision #9). Independent of the above; can slot in.
- **Recruiter-recorded video prompts + image/PDF attachments** —
  reuse the candidate MediaRecorder + IDB + tus pipeline; stored as
  `prompt_assets`. Best done after authoring UI lands so there's a
  place to attach them.
- **Close the think-time countdown gap** above (or carry as Phase-2
  candidate-flow polish).

Carries forward from Phase 1 still open:

- **Loadtest driver hardening**: re-HEAD on transport errors so the
  cascading-409 noise drops out (the ~1.5% transport-error rate at 100
  uploaders is the real signal). Investigate Bandit keep-alive
  behaviour under burst.
- **Safari multi-question soak** on real hardware: per-question
  recorder lifecycle (camera stays live, MediaRecorder start/stop per
  answer) is new ground for Safari. PLAN §10's "Safari MP4 chunks
  produce a usable artifact" risk row is still open for the
  multi-question case. Carry as Phase-2-exit validation.
- **Fly transcode bench** (`shared-cpu-2x`, `dedicated-cpu-2x`) — the
  input that locks PLAN §12.3 / §12.7 finalizer sizing. Ops task
  gated on a Fly account, not code.
- **`pageshow.persisted` BFCache path between questions** — see
  "Partial / known gaps" above.

## Phase-2 candidate-flow exit checklist

These are the Phase 2 rows from PLAN §7 this session covered. The
remaining unchecked Phase 2 rows (authoring UI, importers, video
prompts, attachments, tenant/JWT, REST API, Whisper) are the next
session's scope.

- [x] Candidate flow: per-question progress, review screen, submit
      step, optional skip for non-required questions.
- [~] Per-question think-time countdown — scaffolded but countdown UI
      not wired (see "Partial / known gaps").
- [x] `min_answer_seconds` soft floor + `max_answer_seconds` hard cap.
- [x] Retake flow: new `attempt_number` + new `captureInstanceId` +
      new tus session; prior attempt marked `superseded` once new
      attempt reaches `ready`; `session_questions.selected_response_id`
      updated per `retake_policy` / `max_attempts_override`.
- [x] Phase 1 carry-forward — instrument `capture_complete` to verify
      IDB has drained for the current attempt before EOF send.
- [x] `mix precommit` green (58 tests).
