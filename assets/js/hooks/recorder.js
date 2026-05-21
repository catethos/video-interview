// Recorder hook — candidate capture (PLAN §5.1).
//
// Thin wrapper around `RecorderCore`: drives the camera, MediaRecorder,
// IDB queue, and tus uploader via the shared core, while owning the
// LiveView event surface, postMessage handshake, and per-question state
// the candidate flow needs.

import { RecorderCore, isUnsupportedBrowser, uuid } from "../recorder/core";

const Recorder = {
  mounted() {
    this.state = {
      sessionId: this.el.dataset.sessionId,
      questionIndex: 1,
      attemptNumber: 1,
      maxAnswerSeconds: null,
      minAnswerSeconds: null,
      captureInstanceId: null,
      responseId: null,
      tusUrl: null,
      captureCompleteUrl: null,
      uploadBearer: null,
      // postMessage channel id (PLAN §4.3) — random nonce we include in
      // every outbound message and require on every inbound message.
      channelId: uuid(),
      parentOrigin: null,
    };

    this.preview = this.el.querySelector('video[data-role="preview"]');
    this.countdownEl = this.el.querySelector('[data-role="recording-countdown"]');
    this.micLevelEl = this.el.querySelector('[data-role="mic-level"]');
    this.countdownTimer = null;
    this.micLevelFrame = null;
    this.bind("request", () => {
      // Optimistic LV ping so the UI can react the instant the candidate
      // commits — getUserMedia + the browser permission dialog can take
      // 1-2s, and waiting for the granted/denied event leaves the page
      // visually frozen during that window (e.g. the prompt video stays
      // expanded). The hook then proceeds with the actual camera open.
      this.pushEvent("permission_requesting", {});
      this.requestCamera();
    });
    this.bind("start", () => this.startRecording());
    this.bind("stop", () => this.stopRecording());
    // Note: no `release` binding — candidates can't choose to drop the
    // camera mid-interview. The hook still owns `releaseCamera()` for
    // unmount cleanup (see destroyed() → core.destroy()).

    this.handleEvent("set_question", (payload) => this.applyQuestion(payload));
    this.handleEvent("auth_acked", (payload) => {
      if (payload && typeof payload.uploadBearer === "string") {
        this.state.uploadBearer = payload.uploadBearer;
      }
    });
    this.handleEvent("post_to_parent", (payload) => this.postToParent(payload));

    // Cross-hook handoff from ThinkTimeCountdown: when the post-
    // thinktime idle window expires, recording must start whether
    // the candidate clicked Record or not (cheating-window mitigation).
    // Listening at document level because the dispatcher (an external
    // hook) can't reach into this section's DOM directly.
    this.onAutoStart = () => this.startRecording();
    document.addEventListener("candidate:auto-start-recording", this.onAutoStart);

    // Focus telemetry: tab/window blur or visibilitychange are recorded
    // server-side so the recruiter dashboard can surface "candidate left
    // the tab 2× during this answer". The LV only persists when phase
    // is :recording (see capture_live.ex handle_event); we fire from JS
    // unconditionally and let the server filter. Coalescing window
    // collapses blur+visibilitychange pairs that some browsers fire
    // together (~250ms).
    this.onVisibility = () => {
      if (document.visibilityState === "hidden") this.fireFocusEvent("focus_lost");
      else this.fireFocusEvent("focus_regained");
    };
    this.onBlur = () => this.fireFocusEvent("focus_lost");
    this.onFocus = () => this.fireFocusEvent("focus_regained");
    document.addEventListener("visibilitychange", this.onVisibility);
    window.addEventListener("blur", this.onBlur);
    window.addEventListener("focus", this.onFocus);

    if (window.parent && window.parent !== window) {
      this.bindPostMessage();
      this.postToParent({ type: "ready" });
    }

    if (isUnsupportedBrowser()) {
      this.renderUnsupportedBrowserBlock();
      return;
    }

    this.core = new RecorderCore({
      preview: this.preview,
      getIdentity: () => ({
        sessionId: this.state.sessionId,
        questionIndex: this.state.questionIndex,
        attemptNumber: this.state.attemptNumber,
        captureInstanceId: this.state.captureInstanceId,
      }),
      getEndpoints: () => ({
        tusUrl: this.state.tusUrl,
        captureCompleteUrl: this.state.captureCompleteUrl,
      }),
      getAuthBearer: () => this.state.uploadBearer,
      refreshAuthBearer: () => this.refreshUploadBearer(),
      onEvent: (name, payload) => this.handleCoreEvent(name, payload),
    });
  },

  destroyed() {
    if (this.onMessage) window.removeEventListener("message", this.onMessage);
    if (this.onAutoStart) {
      document.removeEventListener("candidate:auto-start-recording", this.onAutoStart);
    }
    if (this.onVisibility) {
      document.removeEventListener("visibilitychange", this.onVisibility);
    }
    if (this.onBlur) window.removeEventListener("blur", this.onBlur);
    if (this.onFocus) window.removeEventListener("focus", this.onFocus);
    if (this.core) this.core.destroy();
    this.stopRecordingCountdown();
    this.stopMicLevelLoop();
  },

  // --- Core event bridge ----------------------------------------------

  handleCoreEvent(name, payload) {
    switch (name) {
      case "recorder_ready":
        this.pushEvent("recorder_ready", payload);
        break;

      case "permission": {
        this.pushEvent("permission", payload);
        if (payload.state === "granted") {
          this.postToParent({ type: "permissions_granted" });
          this.startMicLevelLoop();
        }
        if (payload.state === "denied") this.postToParent({ type: "permissions_denied" });
        if (payload.state === "released") this.stopMicLevelLoop();
        break;
      }

      case "recorder_started":
        this.state.startInFlight = false;
        this.startRecordingCountdown();
        this.pushEvent("recorder_started", payload);
        // Notify other hooks (e.g. ThinkTimeCountdown's idle timer)
        // so they can cancel any pending auto-start logic.
        document.dispatchEvent(new CustomEvent("candidate:recorder-started"));
        this._announce("Recording started.");
        this.postToParent({ type: "recording_started", position: this.state.questionIndex });
        break;

      case "recorder_stopped":
        this.state.startInFlight = false;
        this.stopRecordingCountdown();
        this.setActionDisabled("start", false);
        this.pushEvent("recorder_stopped", payload);
        this._announce("Recording stopped.");
        this.postToParent({
          type: "recording_stopped",
          position: this.state.questionIndex,
          durationMs: payload.durationMs,
        });
        break;

      case "capture_complete_acked":
        this.pushEvent("capture_complete_acked", payload);
        break;

      case "buffer_progress": {
        this.pushEvent("buffer_progress", payload);
        const denom = payload.bytesUploaded + payload.bytesBuffered;
        const percent = denom > 0 ? Math.round((payload.bytesUploaded / denom) * 100) : 0;
        this.postToParent({
          type: "upload_progress",
          sessionId: this.state.sessionId,
          percent,
        });
        break;
      }

      case "fenced":
        this.pushEvent("fenced_notice", payload);
        break;

      case "recorder_error":
        this.state.startInFlight = false;
        this.pushEvent("recorder_error", payload);
        break;

      case "bitrate_stepped":
        this.pushEvent("bitrate_stepped", payload);
        break;
    }
  },

  // --- postMessage bridge ---------------------------------------------

  bindPostMessage() {
    if (this.onMessage) return;
    this.onMessage = (event) => {
      if (event.source !== window.parent) return;
      const data = event.data;
      if (!data || data.v !== 1 || data.channelId !== this.state.channelId) return;

      if (
        this.state.parentOrigin === null &&
        typeof event.origin === "string" &&
        event.origin !== "null"
      ) {
        this.state.parentOrigin = event.origin;
      }

      if (data.type === "auth" && typeof data.bootstrapToken === "string") {
        this.pushEvent(
          "auth",
          { token: data.bootstrapToken, parentOrigin: this.state.parentOrigin },
          (reply) => {
            if (reply && reply.uploadBearer) this.state.uploadBearer = reply.uploadBearer;
          },
        );
      }
    };
    window.addEventListener("message", this.onMessage);
  },

  postToParent(message) {
    if (!window.parent || window.parent === window) return;
    if (!message || typeof message.type !== "string") return;
    const payload = Object.assign({}, message, {
      v: 1,
      channelId: this.state.channelId,
    });
    const target = this.state.parentOrigin || "*";
    try {
      window.parent.postMessage(payload, target);
    } catch (_) {
      // best-effort relay — never fatal
    }
  },

  applyQuestion(payload) {
    if (!payload) return;
    if (Number.isInteger(payload.questionIndex)) this.state.questionIndex = payload.questionIndex;
    if (Number.isInteger(payload.attemptNumber)) this.state.attemptNumber = payload.attemptNumber;
    this.state.maxAnswerSeconds = Number.isInteger(payload.maxAnswerSeconds)
      ? payload.maxAnswerSeconds
      : null;
    this.state.minAnswerSeconds = Number.isInteger(payload.minAnswerSeconds)
      ? payload.minAnswerSeconds
      : null;

    if (this.core) this.core.setMaxAnswerSeconds(this.state.maxAnswerSeconds);
  },

  // --- UI plumbing ----------------------------------------------------

  bind(action, handler) {
    const btn = this.el.querySelector(`[data-action="${action}"]`);
    if (btn) btn.addEventListener("click", handler);
  },

  setActionDisabled(action, disabled) {
    const btn = this.el.querySelector(`[data-action="${action}"]`);
    if (!btn) return;
    btn.disabled = !!disabled;
    btn.classList.toggle("btn-disabled", !!disabled);
  },

  renderUnsupportedBrowserBlock() {
    const url = location.href;
    this.el.innerHTML = `
      <div class="rounded-md border border-warning bg-warning/10 p-4 space-y-3">
        <h2 class="font-semibold">Please complete this in desktop Chrome or Edge.</h2>
        <p class="text-sm">
          This interview needs a recording engine that only Chrome and Edge
          fully support today. Open this link on a laptop or desktop running
          Chrome 100+ or Edge 100+.
        </p>
        <form data-role="email-link" class="flex flex-col gap-2 sm:flex-row sm:items-center">
          <input type="email" name="email" required placeholder="you@example.com"
                 class="input input-sm flex-1" />
          <button type="submit" class="btn btn-sm btn-primary">Email me this link</button>
        </form>
        <p class="text-xs opacity-70">Or copy the link manually:
          <code class="break-all">${url}</code></p>
      </div>`;
    const form = this.el.querySelector('[data-role="email-link"]');
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const email = form.querySelector('input[name="email"]').value.trim();
      if (!email) return;
      this.pushEvent("email_link_request", { email, url });
      form.innerHTML = '<p class="text-sm">Sent. Check your inbox.</p>';
    });
    this.pushEvent("recorder_error", { code: "mobile_unsupported", message: "blocked on mobile" });
  },

  // --- Camera + recorder ----------------------------------------------

  async requestCamera() {
    if (!this.core) return;
    await this.core.requestCamera();
  },

  releaseCamera() {
    if (this.core) this.core.releaseCamera();
  },

  startRecording() {
    if (!this.core) return;
    // Single-flight guard. The auto-start handoff from ThinkTimeCountdown
    // can race the candidate's manual Record click within the same
    // 200ms window, producing TWO claim_instance pushes with different
    // captureInstanceIds for the same attempt. The server treats that
    // as a takeover and fences the first claim — recording never
    // actually starts. Guard at the top so the second caller is a no-op.
    if (this.state.startInFlight) return;
    if (this.core.recorder && this.core.recorder.state !== "inactive") return;
    this.state.startInFlight = true;

    this.state.captureInstanceId = uuid();
    this.state.responseId = null;
    this.state.tusUrl = null;
    this.state.captureCompleteUrl = null;

    this.setActionDisabled("start", true);
    this.core.setMaxAnswerSeconds(this.state.maxAnswerSeconds);

    this.pushEvent(
      "claim_instance",
      {
        questionIndex: this.state.questionIndex,
        attemptNumber: this.state.attemptNumber,
        captureInstanceId: this.state.captureInstanceId,
      },
      (reply) => {
        if (!reply || !reply.ok) {
          this.state.startInFlight = false;
          this.setActionDisabled("start", false);
          this.pushEvent("recorder_error", {
            code: "claim_failed",
            message: (reply && reply.error) || "unknown",
          });
          return;
        }
        this.state.responseId = reply.responseId;
        this.state.tusUrl = reply.tusUrl;
        this.state.captureCompleteUrl = reply.captureCompleteUrl;
        this.core.startRecording();
      },
    );
  },

  stopRecording(opts = {}) {
    if (this.core) this.core.stopRecording(opts);
  },

  refreshUploadBearer() {
    return new Promise((resolve) => {
      this.pushEvent("refresh_upload_token", {}, (reply) => {
        if (reply && reply.token) {
          this.state.uploadBearer = reply.token;
          resolve(true);
        } else {
          resolve(false);
        }
      });
    });
  },

  // --- Recording-time countdown overlay -------------------------------
  //
  // Lives inside this hook (rather than a sibling hook) because the
  // surrounding section uses phx-update="ignore" — a separate hook on
  // a sibling can't track data-phase reliably across diffs. The
  // authoritative auto-stop is in core.js's _armAutoStop; this widget
  // is just the visible mirror, updating once per second.

  startRecordingCountdown() {
    if (!this.countdownEl) return;
    const max = this.state.maxAnswerSeconds;
    if (!Number.isInteger(max) || max <= 0) return;

    this.countdownElapsed = 0;
    this.renderRecordingCountdown();
    this.countdownTimer = setInterval(() => this.tickRecordingCountdown(), 1000);
  },

  stopRecordingCountdown() {
    if (this.countdownTimer) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = null;
    }
    if (this.countdownEl) {
      this.countdownEl.textContent = "";
      this.countdownEl.classList.remove(
        "recording-countdown-receding",
        "recording-countdown-warning",
      );
    }
  },

  tickRecordingCountdown() {
    const max = this.state.maxAnswerSeconds;
    if (!Number.isInteger(max) || max <= 0) return;
    this.countdownElapsed += 1;
    if (this.countdownElapsed >= max) {
      // Authoritative stop fires in core.js; clamp the visible value.
      this.countdownElapsed = max;
      this.renderRecordingCountdown();
      return;
    }
    this.renderRecordingCountdown();
  },

  renderRecordingCountdown() {
    if (!this.countdownEl) return;
    const max = this.state.maxAnswerSeconds;
    const remaining = Math.max(0, max - this.countdownElapsed);

    const m = Math.floor(remaining / 60);
    const s = remaining % 60;
    this.countdownEl.textContent =
      `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;

    this.countdownEl.classList.toggle("recording-countdown-receding", remaining <= 15);
    this.countdownEl.classList.toggle("recording-countdown-warning", remaining <= 5);

    // Throttled aria-live cues for screen-reader users. Spamming every
    // second is unusable; we milestone-announce instead.
    if (
      remaining === 60 ||
      remaining === 30 ||
      remaining === 15 ||
      remaining === 10 ||
      (remaining <= 5 && remaining > 0)
    ) {
      this._announce(`${remaining} seconds left to record.`);
    }
    if (remaining === 0) this._announce("Recording time is up.");
  },

  // Same shape as the announce() helper in think_time_countdown.js;
  // duplicated here so each hook owns its dedupe state. Writes into
  // the shared #countdown-announce aria-live region in the LV template.
  _announce(text) {
    const el = document.getElementById("countdown-announce");
    if (!el) return;
    const next = text === this._lastAnnouncement ? text + "​" : text;
    el.textContent = next;
    this._lastAnnouncement = text;
  },

  // --- Focus telemetry ------------------------------------------------
  //
  // Coalesce blur + visibilitychange events that fire in the same
  // ~250ms window (some browsers — Safari especially — fire both on
  // backgrounding). The server uses (response_id, occurred_at, kind)
  // as a unique key so duplicate inserts no-op, but de-duping client-
  // side keeps the channel cleaner.

  fireFocusEvent(name) {
    const now = Date.now();
    if (this.lastFocusEventAt && now - this.lastFocusEventAt < 250) return;
    this.lastFocusEventAt = now;
    this.pushEvent(name, { at: new Date(now).toISOString() });
  },

  // --- Mic-level indicator --------------------------------------------
  //
  // After permission is granted, render a live audio level so the
  // candidate can confirm their mic is being picked up. Drives a CSS
  // custom property on the mic-level element via requestAnimationFrame
  // — no LV roundtrip per frame.

  startMicLevelLoop() {
    if (!this.micLevelEl || !this.core) return;
    if (this.micLevelFrame) return;
    const tick = () => {
      if (!this.core) return;
      const level = this.core.getMicLevel(); // 0..1
      // Normalize to a visually useful range — typical conversational
      // speech sits around 0.05..0.20 RMS, so we scale to fill the bar
      // at ~0.4 RMS to avoid a sluggish-looking meter.
      const display = Math.min(1, level * 2.5);
      this.micLevelEl.style.setProperty("--mic-level", display.toFixed(3));
      // Mark "live" once we see a non-trivial signal — the candidate
      // can use this as a quick visual confirmation.
      this.micLevelEl.classList.toggle("mic-level-live", display > 0.04);
      this.micLevelFrame = requestAnimationFrame(tick);
    };
    this.micLevelFrame = requestAnimationFrame(tick);
  },

  stopMicLevelLoop() {
    if (this.micLevelFrame) {
      cancelAnimationFrame(this.micLevelFrame);
      this.micLevelFrame = null;
    }
    if (this.micLevelEl) {
      this.micLevelEl.style.removeProperty("--mic-level");
      this.micLevelEl.classList.remove("mic-level-live");
    }
  },
};

export default Recorder;
