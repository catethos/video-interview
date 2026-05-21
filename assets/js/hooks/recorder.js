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
    if (this.core) this.core.destroy();
  },

  // --- Core event bridge ----------------------------------------------

  handleCoreEvent(name, payload) {
    switch (name) {
      case "recorder_ready":
        this.pushEvent("recorder_ready", payload);
        break;

      case "permission": {
        this.pushEvent("permission", payload);
        if (payload.state === "granted") this.postToParent({ type: "permissions_granted" });
        if (payload.state === "denied") this.postToParent({ type: "permissions_denied" });
        break;
      }

      case "recorder_started":
        this.pushEvent("recorder_started", payload);
        this.postToParent({ type: "recording_started", position: this.state.questionIndex });
        break;

      case "recorder_stopped":
        this.setActionDisabled("start", false);
        this.pushEvent("recorder_stopped", payload);
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
};

export default Recorder;
