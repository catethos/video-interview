// RecruiterRecorder hook — recruiter prompt-asset recording
// (PLAN §3.4 recruiter prompts).
//
// Thin wrapper around `RecorderCore`: drives the camera, MediaRecorder,
// IDB queue, and tus uploader against the prompt-asset endpoints
// (`/uploads/prompt_assets/:id/:cid` + `/api/prompt_assets/:id/capture_complete`).
//
// The LV mounts the asset row in `pending` state, mints a fresh
// `capture_instance_id`, mints a short-lived recruiter upload bearer,
// and pushes `init` to the hook with all four URLs + ids. The hook
// then drives a single recording session end-to-end. There is no
// retake / multi-attempt concept on the recruiter side — a re-record
// creates a new asset id, served by a fresh `init` push.

import { RecorderCore, isUnsupportedBrowser, uuid } from "../recorder/core";

const RecruiterRecorder = {
  mounted() {
    this.state = {
      tenantId: null,
      promptAssetId: null,
      captureInstanceId: null,
      tusUrl: null,
      captureCompleteUrl: null,
      uploadBearer: null,
    };

    this.preview = this.el.querySelector('video[data-role="preview"]');
    this.bind("request", () => this.requestCamera());
    this.bind("start", () => this.startRecording());
    this.bind("stop", () => this.stopRecording());
    this.bind("release", () => this.releaseCamera());

    this.handleEvent("init", (payload) => this.applyInit(payload));

    if (isUnsupportedBrowser()) {
      this.renderUnsupportedBrowserBlock();
      return;
    }

    this.core = new RecorderCore({
      preview: this.preview,
      // Identity is shaped for the candidate IDB schema; for the
      // recruiter we shoehorn into the same fields so we reuse the
      // existing IDB store without a schema bump:
      //   sessionId        = "prompt_asset:<id>"
      //   questionIndex    = 0
      //   attemptNumber    = 1
      //   captureInstanceId = <cid>
      getIdentity: () => ({
        sessionId: `prompt_asset:${this.state.promptAssetId}`,
        questionIndex: 0,
        attemptNumber: 1,
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
    if (this.core) this.core.destroy();
  },

  applyInit(payload) {
    if (!payload) return;
    if (typeof payload.tenantId === "string") this.state.tenantId = payload.tenantId;
    if (typeof payload.promptAssetId === "string") this.state.promptAssetId = payload.promptAssetId;
    if (typeof payload.captureInstanceId === "string") {
      this.state.captureInstanceId = payload.captureInstanceId;
    }
    if (typeof payload.tusUrl === "string") this.state.tusUrl = payload.tusUrl;
    if (typeof payload.captureCompleteUrl === "string") {
      this.state.captureCompleteUrl = payload.captureCompleteUrl;
    }
    if (typeof payload.uploadBearer === "string") this.state.uploadBearer = payload.uploadBearer;
  },

  handleCoreEvent(name, payload) {
    switch (name) {
      case "recorder_ready":
      case "permission":
      case "recorder_started":
      case "buffer_progress":
      case "bitrate_stepped":
      case "recorder_error":
        this.pushEvent(name, payload);
        break;

      case "recorder_stopped":
        this.setActionDisabled("start", false);
        this.pushEvent("recorder_stopped", payload);
        break;

      case "capture_complete_acked":
        this.pushEvent("capture_complete_acked", payload);
        break;

      case "fenced":
        this.pushEvent("fenced_notice", payload);
        break;
    }
  },

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
    this.el.innerHTML = `
      <div class="rounded-md border border-warning bg-warning/10 p-4">
        <h2 class="font-semibold">Recording requires desktop Chrome or Edge.</h2>
        <p class="text-sm">Switch browser to record a prompt video.</p>
      </div>`;
    this.pushEvent("recorder_error", {
      code: "mobile_unsupported",
      message: "blocked on mobile",
    });
  },

  async requestCamera() {
    if (this.core) await this.core.requestCamera();
  },

  releaseCamera() {
    if (this.core) this.core.releaseCamera();
  },

  startRecording() {
    if (!this.core) return;
    if (!this.state.tusUrl || !this.state.captureInstanceId) {
      this.pushEvent("recorder_error", {
        code: "not_initialized",
        message: "recorder not initialized yet",
      });
      return;
    }
    this.setActionDisabled("start", true);
    this.core.startRecording();
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

export default RecruiterRecorder;
