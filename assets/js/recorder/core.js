// RecorderCore — MediaRecorder + IDB + tus pump.
//
// Owns the camera stream, MediaRecorder lifecycle, IndexedDB durability
// queue, and tus uploader. Parametrised over identity (the IDB key
// tuple) and endpoints (tus URL + capture_complete URL) so both the
// candidate Recorder hook and the recruiter prompt recorder can drive
// it (PLAN §3.4 recruiter prompts).
//
// Invariants (PLAN §5.1):
//   - Each chunk is durable in IDB *before* any upload attempt.
//   - Each chunk is deleted from IDB *only after* the server ACKs durability.
//   - chunkIndex is monotonic per (identity, captureInstanceId).
//   - capture_complete is an *explicit* signal — never inferred from idle.
//   - Single in-flight PATCH per (identity, captureInstanceId), offset-ordered.
//   - On QuotaExceededError or buffered>HARD_CAP, recording pauses.
//
// Events emitted to `onEvent(name, payload)`:
//   "recorder_ready"          { mimeType }
//   "recorder_started"        { captureInstanceId, mimeType }
//   "recorder_stopped"        { durationMs, reason }
//   "capture_complete_acked"  { queuedChunks, queuedBytes }
//   "buffer_progress"         { bytesBuffered, bytesUploaded }
//   "fenced"                  { current, yours }
//   "recorder_error"          { code, message }
//   "bitrate_stepped"         { step, label, width, height, frameRate }
//   "permission"              { state: "granted"|"denied"|"released", error? }

import { putChunk, deleteChunk, listForInstance, totalBufferedBytes } from "../hooks/idb";

const TIMESLICE_MS = 2000;
const IDB_SOFT_CAP = 150 * 1024 * 1024;
const IDB_HARD_CAP = 300 * 1024 * 1024;
const RETRY_BASE_MS = 500;
const RETRY_MAX_MS = 30_000;

const BITRATE_LADDER = [
  { width: 1280, height: 720, frameRate: 30, label: "720p30" },
  { width: 854, height: 480, frameRate: 24, label: "480p24" },
  { width: 640, height: 360, frameRate: 20, label: "360p20" },
  { width: 320, height: 180, frameRate: 15, label: "180p15" },
];

const PREFERRED_MIMES = [
  "video/webm;codecs=vp9,opus",
  "video/webm;codecs=vp8,opus",
  "video/webm",
  "video/mp4;codecs=avc1,mp4a",
  "video/mp4",
];

export function pickMimeType() {
  if (typeof MediaRecorder === "undefined") return null;
  for (const mime of PREFERRED_MIMES) {
    try {
      if (MediaRecorder.isTypeSupported(mime)) return mime;
    } catch (_) {
      // continue
    }
  }
  return "";
}

export function isMobile() {
  const ua = (navigator.userAgent || "").toLowerCase();
  if (/iphone|ipad|ipod|android|mobile/.test(ua)) return true;
  if (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1) return true;
  return false;
}

// v1 supports Chrome + Edge desktop only (PLAN decision #14).
export function isUnsupportedBrowser() {
  if (isMobile()) return true;
  const ua = navigator.userAgent || "";
  if (/Firefox\//.test(ua)) return true;
  if (/Safari\//.test(ua) && !/Chrome\//.test(ua)) return true;
  return false;
}

export function uuid() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return "id-" + Math.random().toString(16).slice(2) + Date.now().toString(16);
}

export class RecorderCore {
  // opts:
  //   getIdentity  () => { sessionId, questionIndex, attemptNumber, captureInstanceId }
  //   getEndpoints () => { tusUrl, captureCompleteUrl }
  //   getAuthBearer () => string | null
  //   refreshAuthBearer () => Promise<string | null>
  //   onEvent      (name, payload) => void
  //   preview      <video> element for the live camera preview (optional)
  constructor(opts) {
    this.getIdentity = opts.getIdentity || (() => ({}));
    this.getEndpoints = opts.getEndpoints || (() => ({}));
    this.getAuthBearer = opts.getAuthBearer || (() => null);
    this.refreshAuthBearer = opts.refreshAuthBearer || (async () => null);
    this.onEvent = opts.onEvent || (() => {});
    this.preview = opts.preview || null;

    this.mimeType = pickMimeType();
    this.stream = null;
    this.recorder = null;
    this.recorderStartedAt = null;
    this.autoStopTimer = null;
    this.chunkIndex = 0;
    this.bytesUploadedAcked = 0;
    this.uploaderRunning = false;
    this.uploaderQueueWake = null;
    this.stopped = false;
    this.capturePending = false;
    this.fenced = false;
    this.stopReason = null;
    this.bitrateStep = 0;
    this.maxAnswerSeconds = null;

    this._onPageShow = (e) => { if (e.persisted) this.kickUploader(); };
    this._onOnline = () => this.kickUploader();
    window.addEventListener("pageshow", this._onPageShow);
    window.addEventListener("online", this._onOnline);

    this.onEvent("recorder_ready", { mimeType: this.mimeType || "(none)" });
  }

  destroy() {
    window.removeEventListener("pageshow", this._onPageShow);
    window.removeEventListener("online", this._onOnline);
    this._clearAutoStop();
    this.releaseCamera();
  }

  setMaxAnswerSeconds(seconds) {
    this.maxAnswerSeconds = Number.isInteger(seconds) ? seconds : null;
  }

  // --- Camera ---------------------------------------------------------

  async requestCamera() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } },
        audio: { echoCancellation: true, noiseSuppression: true },
      });
      this.stream = stream;
      if (this.preview) this.preview.srcObject = stream;
      this._setupAudioAnalyser(stream);
      this.onEvent("permission", { state: "granted" });
      return true;
    } catch (err) {
      this.onEvent("permission", {
        state: "denied",
        error: `${err.name || "Error"}: ${err.message || err}`,
      });
      return false;
    }
  }

  releaseCamera() {
    this._clearAutoStop();
    if (this.recorder && this.recorder.state !== "inactive") {
      try { this.recorder.stop(); } catch (_) {}
    }
    this._teardownAudioAnalyser();
    if (this.stream) {
      this.stream.getTracks().forEach((t) => t.stop());
      this.stream = null;
    }
    if (this.preview) this.preview.srcObject = null;
    this.onEvent("permission", { state: "released" });
  }

  // --- Mic-level analyser ---------------------------------------------
  //
  // Lets the candidate see their mic is actually picking them up before
  // they commit to recording. Cheap: one AnalyserNode reading the audio
  // track's time-domain data. We expose `getMicLevel()` returning a
  // [0..1] RMS amplitude that the host (hook) renders to the DOM via
  // requestAnimationFrame — pushing per-frame audio levels through the
  // LV channel would be wasteful.

  _setupAudioAnalyser(stream) {
    if (!stream) return;
    const audioTracks = stream.getAudioTracks();
    if (!audioTracks.length) return;

    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      this.audioCtx = new AC();
      this.audioSource = this.audioCtx.createMediaStreamSource(stream);
      this.audioAnalyser = this.audioCtx.createAnalyser();
      this.audioAnalyser.fftSize = 1024;
      this.audioSamples = new Uint8Array(this.audioAnalyser.fftSize);
      this.audioSource.connect(this.audioAnalyser);
      // Note: do NOT connect the analyser to audioCtx.destination — the
      // candidate would hear themselves echo. AnalyserNode reads the
      // graph without needing an output sink.
    } catch (err) {
      // Web Audio not available / blocked — the level just stays at 0.
      // Not worth surfacing as an error; mic still records.
      this._teardownAudioAnalyser();
    }
  }

  _teardownAudioAnalyser() {
    try {
      if (this.audioSource) this.audioSource.disconnect();
      if (this.audioCtx && this.audioCtx.state !== "closed") this.audioCtx.close();
    } catch (_) {
      /* ignore — releasing best-effort */
    }
    this.audioSource = null;
    this.audioAnalyser = null;
    this.audioCtx = null;
    this.audioSamples = null;
  }

  // Returns the current mic input level as a 0..1 RMS amplitude. Cheap
  // enough to call per animation frame. Returns 0 if no analyser (no
  // mic permission yet, or Web Audio unavailable).
  getMicLevel() {
    if (!this.audioAnalyser || !this.audioSamples) return 0;
    this.audioAnalyser.getByteTimeDomainData(this.audioSamples);
    // Samples are 0..255 centered at 128. Compute deviation RMS.
    let sumSquares = 0;
    for (let i = 0; i < this.audioSamples.length; i++) {
      const v = (this.audioSamples[i] - 128) / 128;
      sumSquares += v * v;
    }
    return Math.sqrt(sumSquares / this.audioSamples.length);
  }

  // --- Recorder lifecycle --------------------------------------------

  // Start a recording. Identity + endpoints are read from the callbacks
  // — the host (hook) is responsible for having claimed the writer slot
  // server-side BEFORE calling start.
  startRecording() {
    if (!this.stream) {
      this._reportError("no_stream", "open the camera first");
      return false;
    }
    if (this.recorder && this.recorder.state !== "inactive") {
      this._reportError("already_recording", "recorder is already running");
      return false;
    }

    this.chunkIndex = 0;
    this.bytesUploadedAcked = 0;
    this.stopped = false;
    this.capturePending = false;
    this.fenced = false;
    this.bitrateStep = 0;

    const opts = {};
    if (this.mimeType) opts.mimeType = this.mimeType;
    let recorder;
    try {
      recorder = new MediaRecorder(this.stream, opts);
    } catch (err) {
      this._reportError("recorder_construct_failed", String(err));
      return false;
    }
    this.recorder = recorder;

    recorder.ondataavailable = (event) =>
      this._onChunk(event.data).catch((err) =>
        this._reportError("ondata_persist_failed", String(err)),
      );
    recorder.onerror = (event) =>
      this._reportError("recorder_error_event", String(event.error || event));
    recorder.onstop = () =>
      this._onRecorderStop().catch((err) =>
        this._reportError("onstop_failed", String(err)),
      );

    recorder.start(TIMESLICE_MS);
    this.recorderStartedAt = Date.now();
    this._armAutoStop();

    const ident = this.getIdentity();
    this.onEvent("recorder_started", {
      captureInstanceId: ident.captureInstanceId,
      mimeType: recorder.mimeType || this.mimeType,
    });
    this.kickUploader();
    return true;
  }

  stopRecording(opts = {}) {
    const r = this.recorder;
    if (!r) {
      this._reportError("not_recording", "no active recorder");
      return;
    }
    this.stopReason = opts.reason || "user";
    if (r.state !== "inactive") {
      this.stopped = true;
      try {
        r.stop();
      } catch (err) {
        this._reportError("stop_throw", String(err));
      }
    }
    this._clearAutoStop();
  }

  // --- Internal -------------------------------------------------------

  _armAutoStop() {
    this._clearAutoStop();
    const max = this.maxAnswerSeconds;
    if (!Number.isInteger(max) || max <= 0) return;
    this.autoStopTimer = setTimeout(() => {
      this.autoStopTimer = null;
      this.stopRecording({ reason: "max_answer_seconds" });
    }, max * 1000);
  }

  _clearAutoStop() {
    if (this.autoStopTimer) {
      clearTimeout(this.autoStopTimer);
      this.autoStopTimer = null;
    }
  }

  async _onChunk(blob) {
    if (!blob || blob.size === 0) return;
    const i = this.chunkIndex++;
    const ident = this.getIdentity();
    const row = {
      sessionId: ident.sessionId,
      questionIndex: ident.questionIndex,
      attemptNumber: ident.attemptNumber,
      captureInstanceId: ident.captureInstanceId,
      chunkIndex: i,
      blob,
      mimeType: this.mimeType,
      uploaded: false,
      createdAt: Date.now(),
    };

    try {
      await putChunk(row);
    } catch (err) {
      this._reportError("idb_put_failed", String(err));
      this._pauseForQuota();
      return;
    }

    await this._reportProgress();
    this.kickUploader();
  }

  async _onRecorderStop() {
    const startedAt = this.recorderStartedAt;
    const durationMs = startedAt ? Date.now() - startedAt : null;
    this.onEvent("recorder_stopped", {
      durationMs,
      reason: this.stopReason || "user",
    });
    this.capturePending = true;
    this.kickUploader();
  }

  // --- Uploader -------------------------------------------------------

  kickUploader() {
    if (this.uploaderRunning) {
      if (this.uploaderQueueWake) {
        const wake = this.uploaderQueueWake;
        this.uploaderQueueWake = null;
        wake();
      }
      return;
    }
    this.uploaderRunning = true;
    this._uploaderLoop().finally(() => {
      this.uploaderRunning = false;
    });
  }

  async _uploaderLoop() {
    let attempt = 0;

    while (true) {
      if (this.fenced) return;
      const endpoints = this.getEndpoints();
      if (!endpoints || !endpoints.tusUrl) return;

      const ident = this.getIdentity();
      const rows = await listForInstance({
        sessionId: ident.sessionId,
        questionIndex: ident.questionIndex,
        attemptNumber: ident.attemptNumber,
        captureInstanceId: ident.captureInstanceId,
      });

      const next = rows.find((r) => !r.uploaded);
      if (next) {
        try {
          await this._uploadOne(next, endpoints);
          attempt = 0;
        } catch (err) {
          if (String(err.message) === "fenced") return;
          attempt += 1;
          this._reportError("upload_retry", `${err}; attempt #${attempt}`);
          await this._backoff(attempt);
          continue;
        }
        await this._reportProgress();
        continue;
      }

      if (this.capturePending) {
        const drainSnapshot = await this._snapshotDrain();
        try {
          await this._sendCaptureComplete(endpoints);
          this.capturePending = false;
          this.onEvent("capture_complete_acked", drainSnapshot);
        } catch (err) {
          if (String(err.message) === "fenced") return;
          attempt += 1;
          this._reportError("capture_complete_retry", `${err}; attempt #${attempt}`);
          await this._backoff(attempt);
          continue;
        }
      }
      break;
    }
  }

  async _snapshotDrain() {
    try {
      const ident = this.getIdentity();
      const rows = await listForInstance({
        sessionId: ident.sessionId,
        questionIndex: ident.questionIndex,
        attemptNumber: ident.attemptNumber,
        captureInstanceId: ident.captureInstanceId,
      });
      const pending = rows.filter((r) => !r.uploaded);
      const queuedBytes = pending.reduce((sum, r) => sum + (r.blob ? r.blob.size : 0), 0);
      return { queuedChunks: pending.length, queuedBytes };
    } catch (_) {
      return { queuedChunks: 0, queuedBytes: 0 };
    }
  }

  _backoff(attempt) {
    const ms =
      Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** (attempt - 1)) *
      (0.5 + Math.random());
    return new Promise((resolve) => {
      this.uploaderQueueWake = resolve;
      setTimeout(resolve, ms);
    });
  }

  async _authedFetch(url, init, retryOn401 = true) {
    const headers = Object.assign({}, init.headers || {});
    const bearer = this.getAuthBearer();
    if (bearer) headers["Authorization"] = "Bearer " + bearer;
    const res = await fetch(
      url,
      Object.assign({}, init, { headers, credentials: "omit" }),
    );
    if (res.status === 401 && retryOn401) {
      const fresh = await this.refreshAuthBearer();
      if (fresh) return this._authedFetch(url, init, false);
    }
    return res;
  }

  async _uploadOne(row, endpoints) {
    const offset = this.bytesUploadedAcked;
    const body = await row.blob.arrayBuffer();

    const res = await this._authedFetch(endpoints.tusUrl, {
      method: "PATCH",
      headers: {
        "Tus-Resumable": "1.0.0",
        "Content-Type": "application/offset+octet-stream",
        "Upload-Offset": String(offset),
      },
      body,
    });

    if (res.status === 410) {
      this._handleFenced({ current: res.headers.get("X-Capture-Current") });
      throw new Error("fenced");
    }
    if (res.status === 409) throw new Error("offset_mismatch");
    if (res.status === 401) throw new Error("upload_unauthorized");
    if (!res.ok) throw new Error(`tus PATCH http ${res.status}`);

    const newOffset = parseInt(res.headers.get("Upload-Offset") || "0", 10);
    if (Number.isFinite(newOffset) && newOffset >= offset) {
      this.bytesUploadedAcked = newOffset;
    }

    await deleteChunk({
      sessionId: row.sessionId,
      questionIndex: row.questionIndex,
      attemptNumber: row.attemptNumber,
      captureInstanceId: row.captureInstanceId,
      chunkIndex: row.chunkIndex,
    });
  }

  async _sendCaptureComplete(endpoints) {
    const ident = this.getIdentity();
    const res = await this._authedFetch(endpoints.captureCompleteUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        captureInstanceId: ident.captureInstanceId,
        expectedTotalBytes: this.bytesUploadedAcked,
      }),
    });

    if (res.status === 410) {
      const body = await res.json().catch(() => ({}));
      this._handleFenced({ current: body.current });
      throw new Error("fenced");
    }
    if (res.status === 401) throw new Error("capture_complete_unauthorized");
    if (!res.ok) throw new Error(`capture_complete http ${res.status}`);
  }

  _handleFenced(body) {
    if (this.fenced) return;
    this.fenced = true;
    this._clearAutoStop();
    if (this.recorder && this.recorder.state !== "inactive") {
      try { this.recorder.stop(); } catch (_) {}
    }
    const ident = this.getIdentity();
    this.onEvent("fenced", {
      current: body.current || "(unknown)",
      yours: body.yours || ident.captureInstanceId,
    });
  }

  async _reportProgress() {
    const buffered = await totalBufferedBytes().catch(() => 0);
    this.onEvent("buffer_progress", {
      bytesBuffered: buffered,
      bytesUploaded: this.bytesUploadedAcked,
    });

    if (buffered > IDB_HARD_CAP) {
      this._pauseForQuota();
    } else if (buffered > IDB_SOFT_CAP) {
      const target = Math.min(
        BITRATE_LADDER.length - 1,
        Math.floor(buffered / IDB_SOFT_CAP),
      );
      if (target > this.bitrateStep) {
        this._lowerBitrate(target);
      }
    }
  }

  _lowerBitrate(targetStep) {
    const step = Math.min(BITRATE_LADDER.length - 1, targetStep);
    if (step <= this.bitrateStep) return;

    const constraints = BITRATE_LADDER[step];
    const track =
      this.stream && this.stream.getVideoTracks ? this.stream.getVideoTracks()[0] : null;

    if (!track) {
      console.warn("[recorder] lowerBitrate: no video track");
      return;
    }

    track
      .applyConstraints({
        width: { ideal: constraints.width },
        height: { ideal: constraints.height },
        frameRate: { ideal: constraints.frameRate },
      })
      .then(() => {
        this.bitrateStep = step;
        this.onEvent("bitrate_stepped", {
          step,
          label: constraints.label,
          width: constraints.width,
          height: constraints.height,
          frameRate: constraints.frameRate,
        });
      })
      .catch((err) => {
        this._reportError("bitrate_step_failed", String(err));
      });
  }

  _pauseForQuota() {
    if (this.recorder && this.recorder.state === "recording") {
      try { this.recorder.pause(); } catch (_) {}
      this._reportError(
        "quota_pause",
        "Local buffer is full. Network is too slow or storage is exhausted.",
      );
    }
  }

  _reportError(code, message) {
    console.warn("[recorder]", code, message);
    this.onEvent("recorder_error", { code, message });
  }
}
