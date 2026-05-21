// Think-time countdown — candidate prep window before recording.
//
// Owns its own setInterval so the visible numeral updates locally each
// second. Pushing a tick through the LiveView channel every second
// would burn a websocket round-trip per question per candidate for
// purely cosmetic UI; client-only ticking is the right trade.
//
// Lifecycle:
//   - On mount: read `data-think-seconds`. If > 0, start ticking. If
//     0 or missing, render nothing (no think-time configured for this
//     question).
//   - Each tick: rewrite the element's text content. Last 5 seconds
//     spelled out so the candidate doesn't get a wall of decreasing
//     digits.
//   - At zero: stop the interval, replace the text with the
//     "ready when you are" cue, and fire `think_time_done` on the LV
//     channel so the server-side phase can reflect it (used by
//     downstream features — accessibility, telemetry).
//   - On destroyed: clear the interval to avoid orphans on phase
//     change or LV navigation.

const SPELL = ["", "one", "two", "three", "four", "five"];

// Number of seconds at the END of think-time AND the END of the
// idle window where the cinematic 3-2-1 overlay flashes on the
// camera preview.
const CINEMATIC_LAST_SECONDS = 3;

// After think-time runs out, how long the candidate has to click
// Record before it auto-starts. Closes the cheating window — without
// it the candidate could sit idle indefinitely after the prep window.
const IDLE_AUTO_START_SECONDS = 10;

// Screen-reader announcement milestones. Announcing every second
// is unusable noise; these are the moments where the audio cue
// carries real information.
const THINK_TIME_ANNOUNCE_AT = new Set([30, 20, 10, 5, 4, 3, 2, 1]);
const IDLE_ANNOUNCE_AT = new Set([10, 5, 4, 3, 2, 1]);

const ThinkTimeCountdown = {
  mounted() {
    const total = Number.parseInt(this.el.dataset.thinkSeconds || "0", 10);
    if (!Number.isInteger(total) || total <= 0) return;

    this.remaining = total;
    this.idleRemaining = null;
    // Listen for the candidate manually starting recording (or any
    // phase transition out of :prep) — when that happens, cancel
    // the idle auto-start timer and clear the cinematic overlay.
    this.onRecorderStarted = () => this.cancelIdleTimer();
    document.addEventListener("candidate:recorder-started", this.onRecorderStarted);

    this.render();
    this.timer = setInterval(() => this.tick(), 1000);
  },

  destroyed() {
    this.clear();
    this.cancelIdleTimer();
    this.clearCinematic();
    if (this.onRecorderStarted) {
      document.removeEventListener("candidate:recorder-started", this.onRecorderStarted);
    }
  },

  clear() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  },

  cancelIdleTimer() {
    if (this.idleTimer) {
      clearInterval(this.idleTimer);
      this.idleTimer = null;
    }
    this.idleRemaining = null;
    this.clearCinematic();
  },

  tick() {
    this.remaining -= 1;
    if (this.remaining <= 0) {
      this.clear();
      this.remaining = 0;
      this.render();
      // Start the post-thinktime idle timer. If the candidate doesn't
      // click Record within IDLE_AUTO_START_SECONDS, recording auto-
      // starts (cheating window mitigation).
      this.startIdleTimer();
      return;
    }
    this.render();
  },

  startIdleTimer() {
    // Bail out if we're no longer in :prep (the candidate may have
    // clicked Record while the main timer was rendering its zero
    // tick — race condition we don't want to fight against).
    if (!isPhasePrep()) return;

    this.idleRemaining = IDLE_AUTO_START_SECONDS;
    this.renderIdle();
    this.idleTimer = setInterval(() => this.idleTick(), 1000);
  },

  idleTick() {
    // Cheap guard: if the LV moved us out of :prep (manual start,
    // navigation, anything), drop the timer instead of fighting it.
    if (!isPhasePrep()) {
      this.cancelIdleTimer();
      return;
    }

    this.idleRemaining -= 1;
    if (this.idleRemaining <= 0) {
      this.cancelIdleTimer();
      // Hand off to the Recorder hook — it owns the actual recording
      // lifecycle. Dispatched as a bubbling DOM event so the hook
      // can listen at document level.
      document.dispatchEvent(new CustomEvent("candidate:auto-start-recording"));
      return;
    }
    this.renderIdle();
  },

  renderIdle() {
    const n = this.idleRemaining;
    if (n > CINEMATIC_LAST_SECONDS) {
      this.el.textContent = `Ready when you are. Recording starts in ${n} seconds.`;
    } else {
      // Last 3 seconds — phrase shrinks to just "Recording starts in N."
      // and the cinematic numeral takes over visually.
      this.el.textContent = `Recording starts in ${SPELL[n] || n}.`;
      this.renderCinematic(n);
    }
    if (IDLE_ANNOUNCE_AT.has(n)) {
      announce(`Recording auto-starts in ${n} seconds. Click record to start sooner.`);
    }
  },

  // Two visual states:
  //   - ticking: muted italic phrase "Recording begins in N seconds."
  //   - done:    "Ready when you are."
  // Last 5 seconds use spelled-out numerals to match the editorial
  // aesthetic — "five." beats "5" at this typographic scale.
  // Last 3 seconds ALSO flash a cinematic numeral on the camera
  // preview (the [data-role="cinematic-countdown"] span the LV
  // template renders inside the preview frame).
  render() {
    if (this.remaining <= 0) {
      this.el.textContent = "Ready when you are.";
      this.el.classList.add("think-time-done");
      this.clearCinematic();
      announce("Think-time over. Get ready to record.");
      return;
    }
    if (this.remaining <= 5) {
      this.el.textContent = `Recording begins in ${SPELL[this.remaining]}.`;
    } else {
      this.el.textContent = `Recording begins in ${this.remaining} seconds.`;
    }
    if (this.remaining <= CINEMATIC_LAST_SECONDS) {
      this.renderCinematic(this.remaining);
    }
    if (THINK_TIME_ANNOUNCE_AT.has(this.remaining)) {
      announce(`Recording begins in ${this.remaining} seconds.`);
    }
  },

  // Update the cinematic-overlay span inside the preview frame.
  // We retrigger the CSS animation by toggling the class off then on
  // — assignment alone won't re-fire the animation on a re-applied
  // class. Force a reflow between the removeClass and addClass.
  renderCinematic(n) {
    const el = document.querySelector('[data-role="cinematic-countdown"]');
    if (!el) return;
    el.textContent = String(n);
    el.classList.remove("cinematic-countdown-tick");
    // Force reflow to retrigger the animation; reading offsetWidth is
    // the standard browser-API way to force a synchronous layout.
    void el.offsetWidth;
    el.classList.add("cinematic-countdown-tick");
  },

  clearCinematic() {
    const el = document.querySelector('[data-role="cinematic-countdown"]');
    if (!el) return;
    el.textContent = "";
    el.classList.remove("cinematic-countdown-tick");
  },
};

// The wrapper around the recorder + actions carries data-phase
// updated by LiveView. We use it as the source of truth for "is
// the candidate still in the prep window?" — querying the recorder
// section directly is unreliable because of phx-update="ignore".
function isPhasePrep() {
  const el = document.querySelector("[data-phase]");
  return !!el && el.dataset.phase === "prep";
}

// Write a short string into the shared aria-live="polite" region so
// screen readers announce it. The region is rendered by the LV
// template (id="countdown-announce") and is otherwise visually hidden.
// We bust identical text by appending a zero-width space when the
// new message matches the previous — browsers skip announcing
// identical text in some implementations.
let lastAnnouncement = "";
function announce(text) {
  const el = document.getElementById("countdown-announce");
  if (!el) return;
  const next = text === lastAnnouncement ? text + "​" : text;
  el.textContent = next;
  lastAnnouncement = text;
}

export default ThinkTimeCountdown;
