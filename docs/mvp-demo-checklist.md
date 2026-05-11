# MVP demo checklist

> Manual browser tests that gate "MVP works" before Phase 4 loadtest.
> Curl + unit tests cover plumbing; this list covers the things only a
> real browser can verify.

## Setup

```
mix ecto.migrate
mix phx.server
```

- Recorder: `http://localhost:4000`
- Harness (fake customer): `http://localhost:5174`
- DB inspector (handy): `psql -h localhost -U $USER -d interview_dev`

Open the harness and click **New session** before each test unless told
otherwise. The right panel logs every parent-side SDK callback —
that's where most of the assertions land.

---

## 1. Happy path

- [ ] **Permissions prompt** — first record click triggers browser
      camera/mic prompt. Harness log shows `onPermissions {type:
      "permissions_granted"}`.
- [ ] **Record → upload → finalize** — record ~10s, hit stop. Watch the
      log emit `onRecording{started}` → many `onProgress` → `onRecording{stopped}`.
      Check the DB:
      ```sql
      SELECT state, bytes_uploaded, expected_total_bytes,
             upload_completed_at, finalized_at
        FROM question_responses
       WHERE session_id = '<sid>'
       ORDER BY attempt_number;
      ```
      Expect `state` to progress `recording → capture_complete → uploading
      → upload_complete → finalizing → ready`, with
      `bytes_uploaded = expected_total_bytes`.
- [ ] **Real artifact** — look in the local storage dir (configured via
      `Storage.Local`); confirm an MP4 exists for the response and
      `ffprobe <file>` shows a real duration close to your recording.
- [ ] **Submit** — review screen → submit. Harness log shows `onSubmitted`
      then `onReady`. `sessions.state = ready`. Two rows in
      `webhook_deliveries` (`session.submitted` + `session.ready`) in
      state `pending` (dev tenant has no `webhook_url` — expected).

## 2. Network resilience

- [ ] **Mid-recording offline** — DevTools → Network → Offline while
      recording, keep talking, toggle back online after ~10s. IndexedDB
      (Application tab) shows chunks queued. After reconnect, queue
      drains; final MP4 contains the offline-recorded audio.
- [ ] **Refresh mid-upload** — start a long recording, stop, then refresh
      the iframe parent while chunks are still uploading. LV reconnects,
      hook re-claims the captureInstance, tus resumes from server offset.
      No `Session unavailable`; no byte loss.
- [ ] **BFCache restore** — navigate the harness page forward to any
      other URL, then `history.back()`. Recording state survives;
      `pageshow.persisted` path fires.

## 3. Duplicate tab + fencing

- [ ] **Duplicate tab** — click "Open second tab (same session)". Start
      recording in tab 2. Tab 1's UI transitions to the `:fenced`
      render path; tab 1 stops uploading.

## 4. Multi-question + retake

> Seed needs ≥2 questions for this. Edit `priv/repo/seeds.exs` to add a
> second question, then `mix ecto.reset`.

- [ ] **Walk both questions** — header shows `Q1 of 2` → `Q2 of 2` →
      review screen.
- [ ] **Retake** — record Q1, click retake, record again. DB:
      ```sql
      SELECT attempt_number, state FROM question_responses
       WHERE session_id = '<sid>' AND template_question_id = '<qid>';
      ```
      Two rows; attempt 1 = `superseded`, attempt 2 = `ready`.
      `session_questions.selected_response_id` points at attempt 2.

## 5. Browser matrix

- [ ] **Safari macOS** — different `MediaRecorder` codec path
      (MP4 + H.264 + AAC). The finalizer's stream-copy branch is only
      exercised here; Chrome's VP9→H.264 transcode does not cover it.
      Run the full happy-path on Safari.
- [ ] **Mobile UA block** — DevTools → Device toolbar → iPhone, reload
      harness. SDK renders the "complete on a desktop" block; the
      iframe is never created.

## 6. Pop-out escape hatch

- [ ] **Continue in full window** — click the button. A fresh top-level
      tab opens on `localhost:4000/capture/<sid>?token=…` with a *new*
      bootstrap token (audit log shows a second `bootstrap.mint`). The
      embed iframe in the harness unmounts. Continue recording in the
      popout; finalizer still completes.

## 7. Headers + console

- [ ] **CSP / Permissions-Policy** — DevTools Network → `/capture/<sid>`:
      response headers include
      `Content-Security-Policy: frame-ancestors 'self' http://127.0.0.1:5174 http://localhost:5174`,
      `Permissions-Policy: camera=(self), microphone=(self), autoplay=(self)`,
      `Referrer-Policy: strict-origin-when-cross-origin`.
- [ ] **No postMessage drops** — DevTools Console on the harness page:
      no warnings about wrong-origin or dropped messages. Every log line
      matches a real DB state transition.

---

## Out of scope for the MVP gate

These pass through real-browser code but aren't blockers for "ship the
demo":

- Webhook **delivery** to a real URL (dev tenant has no `webhook_url`).
  To eyeball the wire payload, set `tenants.webhook_url =
  "https://webhook.site/<uuid>"` and re-run §1.
- Whisper transcripts (only fires when `OPENAI_API_KEY` is set).
- `request_popout` / `onError` relay from iframe to SDK — Phase-3 carry.
- Multi-hour Safari soak (`docs/safari-soak-checklist.md`) and the
  500-concurrent loadtest — those are the explicit Phase 4 hardening
  items, separately tracked.
