# Safari macOS soak — Phase-4 harness + checklist

> Status as of 2026-05-09. PLAN §7 Phase 4, §10 risk #1.
>
> Phase 0 ran a 5-minute Safari soak inside the third-party iframe; Phase
> 4 needs **multi-hour, real-world WiFi** behaviour before we declare the
> async pipeline production-ready. This file is the harness + checklist
> so any teammate (not just whoever wrote the recorder) can repeat the
> soak.
>
> The soak runs on real hardware, out of band — there is no Elixir test
> for "Safari survived 4 hours of Wi-Fi flaps." What follows is the
> minimum we need to write down so it stays repeatable.

## Devices

Run the matrix on the hardware our customers run, not on the dev box:

- MacBook Pro / Air, Apple Silicon, **Safari 17+** on macOS 14+.
- One run on **macOS 13 / Safari 16.x** if any customer is still on it
  (we commit to 16+ in PLAN §8.4).

iOS Safari is **out of scope** — the SDK detects mobile and shows the
"complete on a desktop computer" banner.

## Network

- Real residential WiFi — pick the one most likely to drop, not the
  conference-room ethernet.
- macOS Network Link Conditioner profiles to layer in:
  - "100% Loss" 30s — exercises offline buffering + tus resume.
  - "3G" + 5% loss for 5 minutes — exercises bitrate downshift (PLAN
    §5.1) and uploader backpressure.
- Toggle the Wi-Fi off via the menu bar at minute 12 and 47 of the soak
  — no Network Link, just a hard cut.

## Matrix

For each browser × device cell, run **all** of these in sequence in one
session (don't reload between rows — we're soaking, not unit-testing):

| # | Scenario | What to verify |
|---|---|---|
| 1 | **Bg tab**: open the harness in tab A, switch to tab B for 5 min, return | Recorder still capturing; `bytes_uploaded` advanced; no zero-length blobs in IDB |
| 2 | **Network drop** mid-recording (10s, 30s, 90s) | tus resumes from current offset; `last_upload_ack_at` advances after reconnect; no duplicate writes |
| 3 | **Sleep/wake** the lid for 10 minutes mid-recording | Page recovers (LV reconnect); `pageshow.persisted=true` path runs; new `auth` not required (token still valid) |
| 4 | **BFCache restore** — navigate away (back button) and return | Hook re-mounts; captureInstanceId stays the same OR fences cleanly |
| 5 | **Multi-question (5 Q × 60s)** without interruption | All 5 responses reach `ready`; session rolls up to `ready` once finalize completes; webhook fires once |
| 6 | **Pop-out + return** mid-question | Embed iframe tears down; popped-out tab on `interview.yourdomain.com` becomes the sole writer; original answers persisted |
| 7 | **Quota pressure** (forced via DevTools Storage > Quota tab to 50 MB) | Bitrate steps down at IDB_SOFT_CAP, recorder pauses at IDB_HARD_CAP, "Continue in full window" dialog shown |
| 8 | **Tab close mid-upload** then re-open the magic link | New mount reads DB state, resumes via tus offset, completes the in-flight question |

## Metrics to record

For every soak run, capture these **per-question** numbers — paste into
`safari-soak-runs/<yyyy-mm-dd>-<browser>.md` (a new file per run; the
run is the artifact, this checklist is the schema):

| Metric | Where it comes from | Target |
|---|---|---|
| Timeslice cadence (ms between `ondataavailable`) | dev telemetry handler in `recorder.js` | within ±200 ms of 2000 |
| Blob size per chunk (bytes) | same | 200–400 KB at default bitrate; halves after a downshift |
| IDB-buffered peak (MB) | `buffer_progress` event | < 150 MB outside an offline-toggle test |
| tus PATCH duration p50 / p95 (ms) | DevTools network panel, filter `tus` | p50 < 1500, p95 < 5000 on a healthy link |
| capture_complete latency (ms from `onstop` to ACK) | LV log + `capture_complete_acked` event | < 3000 with a drained queue |
| Finalizer transcode realtime ratio | finalizer Oban job log (`Logger.info`) | ≥ 1.5× on `dedicated-cpu-2x`; flag if < 1× |
| Webhook delivery attempts before success | `webhook_deliveries.attempts` | 1 (no retries) on a healthy receiver |

## Dev-time telemetry handler

The recorder hook already pushEvents `recorder_started`, `recorder_stopped`,
`buffer_progress`, `bitrate_stepped`, `capture_complete_acked` to the
LiveView. In dev we tap them through a tiny Phoenix telemetry handler
(`Interview.SoakTelemetry`) that pretty-prints them to `Logger.info` so
soak runs leave a chronological log in the dev console without extra
plumbing. The same events are visible in the LV's
`render_telemetry/1` panel for the candidate-facing view.

To enable: dev config has `:interview, :soak_telemetry, true`. Keep it
off in prod — the log volume is wasteful at scale.

## Pass/fail

A soak run is a pass if:

- Every required question on the matrix completes to `ready`.
- No `failed` rows in `question_responses` other than ones intentionally
  caused by a quota-pressure or kill-the-tab test.
- Webhook delivery succeeds within 3 attempts on a healthy receiver.
- The recorder UI never gets stuck in `recording` after a network drop.

A run is a fail (and blocks Phase 4 sign-off) if:

- Any `question_responses` row is in `recording` for > 10 min after the
  candidate stopped recording (sweeper boundary).
- Any session in `submitted` for > 1 h with no advance to `ready` or
  `failed`.
- Any duplicate writer (two rows with overlapping byte ranges per
  `(session, question, attempt)`).

## What is NOT in this harness

- Mobile (Safari iOS, Chrome Android) — out of scope per PLAN §8.4.
- Network Link Conditioner > 30 % loss for > 60 s — the recorder is
  expected to surface "weak network" UX in that regime, not silently
  buffer forever.
- Real customer sites — we run the soak on the harness page on
  `:5174`, with the production CSP / `Permissions-Policy`. Customer
  pages get a separate smoke test before the launch.
