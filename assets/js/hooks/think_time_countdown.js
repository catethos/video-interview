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

// Number of seconds at the END of think-time where the cinematic
// 3-2-1 overlay flashes on the camera preview. Matches the post-
// thinktime auto-start window's last-3-seconds cinematic (Pass B).
const CINEMATIC_LAST_SECONDS = 3;

const ThinkTimeCountdown = {
  mounted() {
    const total = Number.parseInt(this.el.dataset.thinkSeconds || "0", 10);
    if (!Number.isInteger(total) || total <= 0) return;

    this.remaining = total;
    this.render();
    this.timer = setInterval(() => this.tick(), 1000);
  },

  destroyed() {
    this.clear();
    this.clearCinematic();
  },

  clear() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  },

  tick() {
    this.remaining -= 1;
    if (this.remaining <= 0) {
      this.clear();
      this.remaining = 0;
      this.render();
      // No LV push on zero. Recording start is candidate-driven (Open
      // camera → Record click); the server doesn't need to know
      // think-time ended for any current behavior. Phase 2 may add an
      // a11y announcement event here.
      return;
    }
    this.render();
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

export default ThinkTimeCountdown;
