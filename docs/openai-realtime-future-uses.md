# OpenAI Realtime APIs — future use cases

Reference notes for two OpenAI realtime APIs that we surveyed but did **not**
adopt in v1. Captures where they could fit later, why we deferred them, and
what would need to be true to reopen the decision.

Current v1 transcript plan (PLAN.md decision #9): per-`question_response`
offline Whisper API call in an Oban worker, populating `transcript_text` /
`transcript_provider` / `transcript_ready_at`. The schema and recruiter UI
exist (`lib/interview/capture/response.ex`, `lib/interview_web/live/recruiter_session_live.ex`);
the worker is unimplemented.

---

## 1. Realtime transcription (`gpt-realtime-whisper`)

Streams transcript deltas as audio arrives. WebRTC for browser, WebSocket
for server-side audio pipelines. Endpoint type `session.type = "transcription"`.
Events: `conversation.item.input_audio_transcription.delta` /
`.completed`.

### Possible use cases

- **Live captions during candidate recording.** Clone the audio track from
  the existing `getUserMedia` stream in `assets/js/hooks/recorder.js`, open
  a WebRTC peer connection to the realtime endpoint with a short-TTL
  ephemeral token minted by Phoenix, and render deltas as captions next to
  the recorder UI. Pushes the final transcript back via a LiveView event
  that writes to `question_responses`.
  - Wins: mic-confidence cue ("we're hearing you"), accessibility, faster
    time-to-transcript (no wait for ffmpeg finalize), saves the offline
    Whisper call when realtime succeeds.
  - Costs: third concurrent network stream from the candidate browser (on
    top of MediaRecorder + tus), ephemeral-token mint endpoint, fallback
    path for dropped realtime sessions.
- **Silence / no-speech detection in the recorder UI.** If deltas stop
  arriving for N seconds while the recorder is running, surface a "we're
  not hearing you — check your mic" warning before the candidate finishes
  the answer. Currently the candidate only learns of mic issues at
  playback time.
- **Live answer-length / pacing feedback.** Use word counts from deltas to
  show "~N words so far" or "you have 20s left — wrap up" cues, especially
  useful when `max_answer_seconds` is short.
- **Recruiter-side captions during prompt recording.** Same hook reused
  when recruiters record video prompts (`prompt_assets`) — gives them a
  transcript to proofread before publishing the template.
- **Server-side streaming transcription off the tus PATCH pipeline.**
  Technically possible (demux audio from PATCH chunks, push over
  WebSocket), but defeats the realtime model's whole point — nobody's
  watching the deltas, and the PATCH cadence (~8 s) isn't realtime. Skip
  unless we ever need transcripts to land *before* finalize for downstream
  jobs.
- **Live-mode (Phase 5) captions.** Once two-way live interviews exist,
  each peer's audio track gets a transcription session for in-call
  captions. Cheap to add once the live channel is built.

### Reopen the decision when

- Candidates frequently report "I didn't realize my mic wasn't working"
  in support tickets / completion-rate data.
- Recruiters ask for "transcripts ready the moment the candidate submits"
  (current pipeline waits on ffmpeg finalize first).
- Accessibility / a11y requirements land for the candidate flow.
- Phase 5 (live mode) ships.

### Why we deferred for v1

The offline Whisper job is materially simpler (one Oban worker, no client
changes, no ephemeral tokens, no fallback path) and produces the same
artifact recruiters consume. Live captions are a UX improvement, not a
correctness one — worth doing once the offline path is shipped.

---

## 2. Realtime translation (`gpt-realtime-translate`)

Streams translated audio + transcript deltas while the speaker is still
talking. Dedicated endpoint `/v1/realtime/translations`. WebRTC for
browser media, WebSocket for server media. One session per output
language; for two-way calls, one session per direction.

### Possible use cases

- **Phase 5 conversational translation in live interviews.** Recruiter
  speaks English, candidate speaks Spanish (or vice versa), each hears the
  other in their own language with subtitles. This is the doc's
  "conversational translation" pattern — one session per direction, audio
  tracks kept separate. Natural fit when live mode ships.
- **Live "listen-along" interpretation for panel interviews.** When/if we
  add panel interviews (Option C, server-side recording), a hiring
  manager who doesn't speak the candidate's language can listen along to
  a translated audio track in real time. Useful for global hiring teams.
- **Real-time translated captions for hearing-impaired or non-native
  panelists.** Even without translated audio, the transcript deltas can
  power live multilingual subtitles in a panel UI.
- **Live demo / coding interview localization.** If we ever support
  technical interviews where the interviewer thinks aloud, translated
  audio lets candidates from any language follow along.

### Use cases this API is the **wrong tool** for

- **Async transcript translation.** Translating a saved Spanish
  `transcript_text` into English for a recruiter is a normal text
  translation call (chat completion or `gpt-4o-mini`) — no streaming
  audio needed. Realtime translation here would burn a WebRTC session
  per recording for zero latency benefit.
- **Translating offline recordings as a batch.** Same reasoning: feed
  the finalized audio to a non-realtime transcription model with
  translation, or do transcribe-then-translate in two steps.

### Reopen the decision when

- Phase 5 (live mode) is on the roadmap with a concrete customer.
- A customer asks for live cross-language interviews specifically (vs.
  "translate the transcript afterward").
- Panel / multi-party interviews enter scope (Option C in PLAN.md).

### Why we deferred for v1

v1 is async one-way recording — there is no live listener for translated
audio to reach, so the streaming nature of the API has nothing to do. The
realtime translation endpoint becomes interesting only when a live
channel exists.

For multilingual transcript support short of live mode: add an offline
"translate to English" action on the recruiter session view that runs a
normal text-translation call against the stored `transcript_text`. Cheap,
orthogonal to the recording pipeline, ships in hours not weeks.

---

## Cross-cutting notes

- **Both APIs need ephemeral token minting.** Don't ship the standard
  OpenAI API key to the browser. A `/api/realtime/sessions` endpoint that
  mints short-TTL session secrets (similar pattern to the existing
  bootstrap-token / upload-bearer-token flow in PLAN §4.2) is reusable
  across transcription and translation.
- **Audio source.** For browser flows, both reuse the candidate's
  `getUserMedia` audio track — we'd clone it from the recorder hook
  rather than asking for mic permission twice.
- **Fallback.** Any realtime feature we ship needs an offline fallback
  path. The finalized MP4 in Tigris is always available; the offline
  Whisper / text-translation jobs are the durable layer.
- **Cost model.** Realtime APIs are priced per minute of audio in *and*
  out; offline transcription is cheaper per minute. Run a cost projection
  against current session volume before flipping a feature flag on.
