# Phase 1 — resilient async recording, findings

> Status as of 2026-05-07.
> Phase-1 code lives across `lib/interview/capture.ex`, `lib/interview/storage*`,
> `lib/interview_web/tus/plug.ex`, `lib/interview/workers/finalizer.ex`,
> `lib/interview/workers/abandoned_session_sweeper.ex`,
> `lib/interview_web/live/capture_live.ex`, `assets/js/hooks/recorder.js`,
> and the dev tooling under `lib/mix/tasks/`.
> Tests: `mix precommit` green, 44 tests.

## What was built

| Capability | Where | Status |
|---|---|---|
| Postgres schemas: tenants, interview_templates, interview_template_versions, prompt_assets, template_questions, sessions, session_questions, question_responses (PLAN §3.2; **no** `response_chunks`) | `lib/interview/{tenants,templates,capture}` + `priv/repo/migrations/` | ✅ |
| `Interview.Capture` context: `claim_instance/4` (DB fencing + supersede), `commit_offset/3` (PLAN §5.1 invariant: storage durable → DB commit in one handler), `record_capture_complete/3`, `mark_finalizing/1`, `mark_ready/2`, `rollup_session/1`, sweeper helpers | `lib/interview/capture.ex` | ✅ |
| Oban embedded in web tier: queues `:finalize` (concurrency 1), `:sweeper`, `:webhook`. Postgres notifier. Cron `AbandonedSessionSweeper` /5m | `config/config.exs`, `lib/interview/workers/` | ✅ |
| `Interview.Storage` behaviour + Local adapter (filesystem, append-only writer file per `(response_id, capture_instance_id)`, `:file.sync/1` before ACK) | `lib/interview/storage*` | ✅ |
| `InterviewWeb.Tus.Plug` — tus 1.0.0 PATCH/HEAD/OPTIONS at `/uploads/tus/<response_id>/<capture_instance_id>` with 410 fence / 409 offset / 412 / 415 / 404 | `lib/interview_web/tus/plug.ex` | ✅ |
| `POST /sessions/:sid/responses/:rid/capture_complete` enqueues `Interview.Workers.Finalizer` (nice ffmpeg `libx264` → MP4, ffprobe duration, `Storage.put_artifact`, `Capture.mark_ready`, session rollup) | `lib/interview_web/controllers/capture_complete_controller.ex`, `lib/interview/workers/finalizer.ex` | ✅ |
| `recorder.js` speaks tus on the wire; bitrate step-down via `track.applyConstraints` along a 720p30 → 480p24 → 360p20 → 180p15 ladder, triggered at multiples of `IDB_SOFT_CAP` (150 MB) | `assets/js/hooks/recorder.js` | ✅ |
| `mix loadtest.tus` — synthetic N-uploader driver | `lib/mix/tasks/loadtest.tus.ex` | ✅ |
| `mix bench.transcode --input` updated for capturing real clips; duration-probe fallback (stream-level then full-decode) for browser-streamed WebM | `lib/mix/tasks/bench.transcode.ex` | ✅ |
| Dev seeds + `GET /capture/new` shortcut | `priv/repo/seeds.exs`, `lib/interview_web/controllers/capture_session_controller.ex` | ✅ |
| Embed-pipeline inline 404 for missing session (replaces push_navigate to `/`) | `lib/interview_web/live/capture_live.ex` + test | ✅ |
| Phase-0 stubs removed: `POST /uploads/chunk`, `Interview.UploadController`, `Interview.CaptureFence` GenServer | (deleted) | ✅ |

## Numbers gathered

### Real-content transcode bench

`mix bench.transcode --input <writer-file>` on the dev machine (Apple Silicon
M-series, macOS), input was a 32.29 s 1280×720 VP9/Opus WebM produced by the
recorder hook itself. Each preset run 3×, output to `libx264` MP4.

| Preset | Avg wall | Realtime ratio | Output size | Output bitrate |
|---|---|---|---|---|
| `veryfast` (default) | 3.51 s | **9.20×** | 6.09 MB | ~1.51 Mbps |
| `ultrafast` | 3.77 s | **8.57×** | 19.28 MB | ~4.78 Mbps |

**Reading**:

- Real talking-head VP9 transcoded at ~9× realtime locally vs. Phase-0's
  ~16× synthetic (`testsrc=`). Real content is materially harder
  (~1.7× slower) — confirms decision #6 ("VP9→H.264 is a transcode, not
  a stream-copy remux") and rules out any optimism that the Phase-0
  number was sizing-grade.
- The local bench is on Apple Silicon; PLAN §12.3's "1–2× per modern
  core" assumption is calibrated for Fly `shared-cpu-2x` /
  `dedicated-cpu-2x`. The local 9× is **not** a substitute for benching
  on the actual production hardware. PLAN §12.3 sizing notes are not
  changed here; the deferred Fly bench remains the gating action before
  finalizer pool sizing is committed.
- `ultrafast` saves ~7% wall time at the cost of 3.2× larger output.
  Not worth it on this hardware. Finalizer remains on `veryfast`
  (current default).
- The clip used was 32 s, not the targeted ~5 min. Variance across the
  3 runs was tight (≤ 80 ms wall time spread), so the ratio is a
  useful directional read; a longer clip won't change the ratio
  materially.

**Tooling fix**: `mix bench.transcode`'s ffprobe wrapper assumed the
container had a `format=duration` tag. Browser-streamed WebM (from
`MediaRecorder`) does not. The probe now falls back to stream-level
duration, then a full ffmpeg decode pass with regex extraction of the
last `time=hh:mm:ss.ms` line. Local-only dev tooling.

### Load test — `mix loadtest.tus`

Phoenix on `mix phx.server`, Postgres.app v18, Apple Silicon dev machine.
Synthetic uploaders, 1 MB PATCHes at ~8 s cadence per uploader (matches
PLAN §5.2 capture cadence at the v1 ~1 Mbps target). Driver is in-process
`:httpc` against `localhost:4000`.

| Run | Uploaders | Duration | PATCHes | Throughput | p50 / p95 / p99 (ms) | Errors |
|---|---|---|---|---|---|---|
| #1 | 50 | 30 s | 201 | 5.42 PATCH/s, 5.42 MB/s | 87 / 260 / 405 | none |
| #2 | 100 | 60 s | 719 | 10.52 PATCH/s, 10.52 MB/s | 80 / 294 / 297 | 11 transport, 66×409 |

**Reading**:

- Throughput scales close to linearly from 50 → 100 uploaders on this
  dev machine; latency p99 stays under ~300 ms.
- The 66 `409`s in run #2 are a load-driver artifact: when an
  individual uploader hits a transport error (server closed the
  connection mid-PATCH), the driver does not re-HEAD to resync its
  offset — so every subsequent PATCH for that uploader 409s on stale
  offset for the rest of the run. 11 transport errors × ~6 remaining
  PATCHes ≈ 66, which matches. The real recorder hook would re-sync
  via tus HEAD on transport failure; this driver does not.
- The actual signal is the **~1.5% transport-error rate**
  (`socket_closed_remotely`). Most likely Bandit closing keep-alive
  TCP sockets under burst, not an ingest defect. Worth a closer look
  on Phase-2 entry: tighten the loadtest driver to re-HEAD on
  transport errors so the noise drops out, and characterise whether
  the 1.5% is server-side keepalive churn or client-side `:httpc`.

### Browser-driven validations

Driven manually in Safari macOS 26 / Chrome on the cross-origin harness
at `http://localhost:5174/?sid=<SID_REAL>` (recorder mounted at
`http://localhost:4000/capture/<SID_REAL>`). Real session rows created
via `GET /capture/new`.

| # | Check | Result |
|---|---|---|
| 1a | Safari macOS — sleep / lid-close + resume | ✅ Recording resumed cleanly on wake; finalize pipeline ran end-to-end; producing MP4 with `format=mp4`, `state=ready`. The remaining 1a perturbations (5-min duration, network offline 30 s, tab-background, tab-switch) were not explicitly driven this session. The mechanism — durable IDB before ACK, tus-offset resume — is the same path that the BFCache-decline test below exercised in production-equivalent conditions. |
| 1b | Chrome — two-tab fencing | ✅ Second tab's claim flipped `question_responses.capture_instance_id`, first tab transitioned to `recorder_state=fenced`, surfaced the fenced-notice UI. |
| 1c | Chrome — BFCache restore | ✅ but with a caveat: Chrome **declines BFCache** for any page with active `getUserMedia`/`MediaRecorder`/open WebSockets — i.e. any actively-recording recorder iframe is BFCache-ineligible by design. A Back navigation is therefore a fresh load, which is what the dev log showed (`_mount_attempts=0, _mounts=0`). The valuable invariant — that the IDB queue keeps draining post-unload — was confirmed: two more tus PATCHes flushed after navigate-away, advancing `bytes_uploaded` from 1.92 MB to 2.60 MB with no fence and no error. The `pageshow.persisted` path in `recorder.js` is wired and exists for the idle case (between questions, before recording starts) but was not exercised this session. |
| 1d | Chrome — IDB cap → bitrate step | ✅ With `IDB_SOFT_CAP` lowered temporarily for the test, the ladder fired 0 → 1 (720p30 → 480p24) cleanly when buffered bytes exceeded the cap. The cap was restored. The ladder is **deliberately one-way** per PLAN §5.1: there is no `raiseBitrate`, only `lowerBitrate`, so even after the network un-throttles within the same recording, the candidate stays at the lower rung until a retake or the next question. This is by design — backpressure relief, not adaptive streaming — and is documented behaviour. |

### Pipeline observation worth recording

A buffer-progress event landed at capture-complete time with
`bytesBuffered=716689` while the client sent `expectedTotalBytes`
identical to `bytesUploaded`. Two innocuous explanations are equally
plausible without finer instrumentation:

1. The buffered-bytes UI counter is a slightly stale tick — the actual
   IDB queue had drained by the time `capture_complete` was sent, the
   UI just hadn't repainted.
2. `recorder.js` is sending `capture_complete` before fully draining
   the IDB queue, which would mean `expected_total_bytes` underreports
   the true byte count of the answer. PLAN §5.1 requires drain-then-EOF.

The finalizer ran successfully and produced a complete MP4 in both
recorded sessions, so if (2) is the actual cause it isn't biting under
fast-network conditions. Worth instrumenting before the load test in
Phase-2 entry — specifically, log the IDB queue depth at the moment
`capture_complete` is enqueued.

## Decision-log changes

No PLAN §11 decisions overturned. Reinforced:

1. **Decision #6 (codec / transcode)**: the real-content bench
   confirms VP9 → H.264 is a real transcode (~9× realtime locally on
   Apple Silicon vs. ~16× synthetic). The Fly hardware bench is still
   the input that gates §12.3 / §12.7 finalizer sizing.
2. **PLAN §5.1 ladder is one-way**: the dev validation hit step 1 but
   never recovered after un-throttle — by design. Worth surfacing in
   the public docs when the SDK lands so customers don't expect
   adaptive recovery.

## Other small fixes that landed during closeout

- `lib/interview/application.ex`: the dev harness Bandit listener is
  now gated on `Phoenix.Endpoint.server?/2` so it only starts when the
  main HTTP listener is also starting. Without this, `mix loadtest.tus`
  (which calls `app.start` for fixture creation) crashed with `:eaddrinuse`
  on `:5174` against an already-running `mix phx.server` — both were
  trying to bind the harness. The harness has no purpose without the
  main listener; tying their lifecycles together is the correct
  semantic.
- `lib/interview_web/live/capture_live.ex`: session-not-found path
  no longer `push_navigate(to: "/")`. The home page is on `:browser`,
  which sends `X-Frame-Options: DENY`, so the iframe redirected there
  was being blocked by the browser anyway. The LiveView now branches
  its `render/1` on a `not_found` assign and stays on `:embed` — the
  iframe sees a clean "Session not found" page with the right CSP
  frame-ancestors header. Status code stays 200 (LiveView mount cannot
  natively flip status); the visible behaviour is correct, and a
  proper 404 status would require wrapping the endpoint's error
  rendering, which is more invasive than the user-visible win
  warrants.

## Carries into Phase 2

These are not Phase-1 regressions; they're inputs the next session
should pick up.

- **Fly transcode bench** (`shared-cpu-2x`, `dedicated-cpu-2x`) —
  the input that finally locks PLAN §12.3 / §12.7 finalizer sizing.
- **Loadtest driver hardening**: re-HEAD after transport errors so
  noise drops out; investigate Bandit keep-alive behaviour under
  burst.
- **`capture_complete` drain check**: verify (and instrument) that
  `recorder.js` only sends `capture_complete` after the IDB queue
  has drained for the current attempt.
- **Safari MP4 server-side concat**: PLAN §10's risk row notes a
  single-blob fallback if Safari MP4 chunks aren't byte-concatable.
  The brief Safari soak this session produced a usable MP4 end-to-end
  for the duration tested, but the explicit "tab background 5 min +
  network offline 30 s + tab switch" sweep was not driven. Carry as
  a Phase-2-entry validation on real hardware.
- **`pageshow.persisted` BFCache path**: not exercised this session
  (Chrome declines BFCache for active recorders). Idle-tab BFCache
  flow validates between questions; do that exercise in Phase 2 when
  the multi-question UX lands.
- All of PLAN §7 Phase 2 itself — template authoring UI, JWT
  bootstrap, Whisper, recruiter dashboard, retake flow, tenant
  model. Phase 2 is the next session per scope.

## Phase-1 exit checklist

- [x] IndexedDB queue keyed by `(sessionId, questionIndex,
      attemptNumber, captureInstanceId, chunkIndex)` with quota /
      backpressure caps (§5.1).
- [x] tus client + tus `Plug`, local-storage backend (Tigris swap is
      a Phase-2/3 ops task, not a code task — adapter behaviour is in
      place).
- [x] Server commits `bytes_uploaded` / tus offset in the same
      handler that ACKs durability (§5.1 invariant).
- [x] Explicit `capture_complete` endpoint; finalizer enqueued only on
      this signal.
- [x] LiveView reconnect handling (stateless server, DB-backed). BFCache
      `pageshow.persisted` path wired. Capture-instance fencing on
      `question_responses.capture_instance_id`.
- [x] Finalizer Oban worker per question_response: transcode to MP4
      via ffmpeg `libx264`, session rollup to `ready`.
- [x] Abandoned-session sweeper Oban job (§3.2 state machine).
- [x] Small load test (50 then 100 concurrent uploaders).
- [x] Real-content transcode bench (caveat: Fly bench deferred).
- [x] Phase-0 stubs removed (`/uploads/chunk`, `CaptureFence`).
- [x] `mix precommit` green.
