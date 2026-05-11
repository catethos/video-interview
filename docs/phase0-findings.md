# Phase 0 — risk-validation findings

> Status as of 2026-05-07.
> Phase-0 spike code lives in `lib/interview_web/live/capture_live.ex`,
> `assets/js/hooks/recorder.js`, `lib/interview_web/controllers/upload_controller.ex`,
> `lib/interview/capture_fence.ex`, and the harness under `priv/harness/`.
> The transcode bench is `mix bench.transcode`.

## What was built

| Capability | Where | Status |
|---|---|---|
| Phoenix app + LiveView /capture page with `getUserMedia` + permission state | `CaptureLive` | ✅ |
| MediaRecorder JS hook (timeslice=2000ms), MIME negotiation (VP9 → VP8 → MP4) | `assets/js/hooks/recorder.js` | ✅ |
| IndexedDB durable queue keyed by `(session, q, attempt, captureInstance, chunk)` | `assets/js/hooks/idb.js` | ✅ |
| Stub upload endpoint with fsync-before-ACK, EOF marker | `UploadController` | ✅ |
| Server-side fencing (in-memory) with 410-Gone on stale writers | `Interview.CaptureFence` | ✅ |
| BFCache `pageshow.persisted` re-kick of uploader | `recorder.js` `onBfCacheRestore` | ✅ (basic) |
| Cross-origin third-party iframe harness on a different hostname | Bandit @ `127.0.0.1:5174`, `priv/harness/` | ✅ |
| `frame-ancestors` CSP, `Permissions-Policy`, `Referrer-Policy` on recorder | `Plugs.EmbedCSP` | ✅ |
| Mobile UA detection + email-myself-the-link UX (recorder + SDK stub) | `recorder.js` `renderMobileBlock` + `priv/sdk/embed.v1.js` | ✅ |
| VP9 → H.264 transcode benchmark | `mix bench.transcode` | ✅ (synthetic only) |
| Fence + upload-controller test coverage | `test/interview/capture_fence_test.exs`, `test/interview_web/upload_controller_test.exs` | ✅ (14 tests, all green) |

## Numbers gathered

### Transcode benchmark (synthetic input)

`mix bench.transcode --duration 30` on the dev machine (Apple Silicon, macOS),
`-c:v libx264 -preset veryfast -crf 23`:

| Run | Wall | Realtime ratio |
|---|---|---|
| 1 | 1.85 s | 16.2× |
| 2 | 1.84 s | 16.3× |

**Caveat**: the input is `testsrc=` (a synthetic test pattern). It is *much*
easier to encode than real talking-head footage because temporal complexity
is near-zero. PLAN §12.3 budgets 1–2× realtime on a modern core for real
content. The bench tooling is correct; the *number* should not be used for
sizing until we re-bench against a real interview clip in Phase 1.
**Action**: at the start of Phase 1, capture ~5 minutes of real recorded
content in the spike app, drop it into `mix bench.transcode --input ...`,
and re-run on `shared-cpu-2x` and `dedicated-cpu-2x` Fly machines.
**Decision-log impact**: confirms decision #6 (VP9→H.264 is a transcode,
not a stream-copy remux); Phase-0 doesn't disprove the conservative §12.3
sizing.

### Safari macOS soak

**Not yet executed** — the app is ready to run inside the harness on
`http://127.0.0.1:5174`, but the soak test (5-minute background tab,
network-link conditioner offline toggles, sleep/wake, tab switch) requires
manual driving in Safari. Open question — see "Open" below.

### BFCache + duplicate-tab fencing

Validated end-to-end via tests + curl:

- `Interview.CaptureFence.claim/4` returns `{:claimed, new, previous}`;
  previous becomes `superseded` on the next claim.
- HTTP 410 with body `{ok:false, error:"fenced", current, yours}` for any
  stale writer's PATCH.
- JS hook handles 410 by stopping the recorder, suppressing further uploads,
  and pushing a `fenced_notice` event to the LiveView.

Two-tab manual soak in Chrome **was not yet exercised** because it requires
opening two browser windows. The mechanism is in place and the unit/integration
tests cover the contract; the only thing left is to exercise the actual
two-tab path in the harness.

## Decision-log changes

No decisions overturned. Two reinforced:

1. **Decision #6 — codec/transcode**: bench tooling confirms VP9→H.264 must
   be treated as a real transcode. The synthetic 16× number is *not* a
   sizing input. Phase-1 must re-bench with real talking-head content
   before committing finalizer pool sizing in §12.3 / §12.7.
2. **Decision #5 — tus on Phoenix → Tigris**: the Phase-0 stub uses a
   custom multipart PUT to validate the *contract* (durable-before-ACK,
   fenced writers, monotonic chunk index). Phase 1 swaps the stub for the
   real tus protocol with `tus_plug` server + `tus-js-client`. The
   contract (durable-before-ACK, single in-flight per attempt, ACKs commit
   the offset before the response) is unchanged; only the wire format
   moves.

## Cross-site vs cross-origin in dev

The harness Bandit listener is bound to `127.0.0.1:5174` so that `127.0.0.1`
and `localhost` render as different *sites* for cookie/storage-partitioning
purposes. In dev, **drive the harness via `http://localhost:5174/`** so the
LiveView session cookie (SameSite=Lax) is delivered into the iframe and the
candidate flow can mount as it stands today. That URL still exercises
cross-*origin* (different port) behaviour — `frame-ancestors` CSP,
`Permissions-Policy` delegation, `postMessage` origin allowlist — which is
the Phase-0 contract we set out to validate.

The cross-*site* path (`http://127.0.0.1:5174/`) currently fails LiveView
mount with "session misconfigured or token outdated" because cookies are
dropped across sites. That's the canonical PLAN §4.2 problem
("All auth continuity must be driven by tokens, not cookies") and is
deliberately deferred to the embed-SDK work in Phase 3 (single-use
bootstrap JWT delivered via SDK→iframe postMessage, exchanged for a
short-TTL upload bearer). Re-enable the cross-site path in dev once that
flow is in place.

## Open before exiting Phase 0

These are not blockers — they are the human-in-the-loop validations that
need to happen against a real browser before locking in Phase 1.

1. **Safari macOS 5-minute soak** in the cross-site harness:
   - Background the tab for 5 minutes; verify chunk cadence resumes
     cleanly on focus.
   - Toggle network offline for 30s mid-recording; verify IDB grows and
     drains on reconnect, with no missing chunks.
   - Sleep/wake the laptop mid-recording; verify the recorder either
     pauses cleanly or surfaces an error.
   - Confirm Safari's MP4 chunks are individually parseable enough that
     server-side concat-to-MP4 is viable. If not, the architecture has
     to switch to a single-blob fallback for Safari (decision #6 already
     calls this out).
2. **Two-tab fencing in Chrome**: open `http://127.0.0.1:5174/?sid=X`
   in two tabs, start recording in both; confirm the second tab fences
   the first via the LiveView channel and that the first tab's UI shows
   the `fenced_notice` state.
3. **BFCache restore**: navigate away, navigate back, confirm
   `pageshow.persisted` re-kicks the uploader and the old captureInstance
   is no longer the live writer (it's been replaced by a fresh claim on
   the new mount).
4. **Real-content transcode bench**: as noted under "Transcode benchmark"
   above.
5. **Quota / storage partitioning**: with the harness on a different
   site than the recorder, drive the recorder long enough that IDB
   exceeds the 150 MB soft cap; confirm the bitrate-step-down stub fires
   (currently a no-op) and that the hard-cap pause UX is reachable.

## Phase-1 entry checklist

Carry into Phase 1:

- [ ] Replace the stub upload endpoint with a real tus protocol
      implementation (`tus_plug` + `tus-js-client`).
- [ ] Move fencing state from `Interview.CaptureFence` (in-memory) to
      Postgres (`question_responses.capture_instance_id`).
- [ ] Wire `bytes_uploaded` and tus offset commits into the same
      transaction that ACKs durability to Tigris.
- [ ] Implement the explicit `capture_complete` endpoint and the
      finalizer Oban job (concat → ffmpeg `libx264` transcode → thumbnail).
- [ ] Build the abandoned-session sweeper (`last_client_seen_at` >
      threshold).
- [ ] Implement the bitrate-step-down stub in the recorder hook.
- [ ] Run the real-content transcode bench and update §12.3 sizing.
- [ ] Run a small (~50 concurrent uploaders) load test against the tus
      ingest path.
