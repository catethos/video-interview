// SDK unit tests — fake-window harness, no deps.
//
// Run with:  node --test assets/embed/__tests__/sdk.test.js
//
// These cover the postMessage validation rules in PLAN §4.3 — the part
// of the SDK that has actual logic to test. iframe injection, callbacks,
// and DOM mutation are exercised end-to-end by the harness page.

const { test } = require("node:test");
const assert = require("node:assert/strict");

// Fake out the browser globals esbuild's IIFE expects.
function makeWindow() {
  const listeners = [];
  return {
    addEventListener(name, fn) {
      if (name === "message") listeners.push(fn);
    },
    removeEventListener(name, fn) {
      if (name === "message") {
        const i = listeners.indexOf(fn);
        if (i !== -1) listeners.splice(i, 1);
      }
    },
    open() {
      // Returns a fake popup window.
      return { closed: false, close() { this.closed = true; }, location: {} };
    },
    location: { href: "https://customer-a.com/embed" },
    deliver(message) {
      for (const fn of listeners) fn(message);
    },
  };
}

function makeIframeWindow() {
  return {
    posts: [],
    postMessage(payload, target) {
      this.posts.push({ payload, target });
    },
  };
}

function loadSdk(win) {
  const fs = require("node:fs");
  const path = require("node:path");
  const src = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");

  // Run the IIFE under a controlled context. We provide the minimum
  // shims the SDK touches at top level; mount() sees these via closure.
  const sandbox = {
    window: win,
    document: {
      currentScript: { src: "https://recorder.yourdomain.com/embed.v1.js" },
      querySelector(sel) { return makeHost(sel); },
      createElement(tag) { return makeIframe(tag); },
    },
    navigator: { userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 0 },
    location: win.location,
    URL: URL,
    console,
    crypto: { randomUUID: () => "xxxx-xxxx-xxxx" },
    Promise,
  };
  // The SDK ends with `if (typeof module !== "undefined" && module.exports)`
  // — feed it a module, then read the export.
  const mod = { exports: null };
  const fn = new Function(
    "window", "document", "navigator", "location", "URL", "console", "crypto",
    "module", "Promise",
    src
  );
  fn(
    sandbox.window, sandbox.document, sandbox.navigator, sandbox.location,
    sandbox.URL, sandbox.console, sandbox.crypto, mod, sandbox.Promise
  );
  return win.YourInterview;
}

function makeHost() {
  return {
    children: [],
    appendChild(c) { this.children.push(c); c._parent = this; },
    removeChild(c) {
      const i = this.children.indexOf(c);
      if (i !== -1) this.children.splice(i, 1);
      c._parent = null;
    },
    set innerHTML(v) { this._innerHTML = v; },
    get innerHTML() { return this._innerHTML || ""; },
    querySelector() { return null; },
  };
}

function makeIframe() {
  const cw = makeIframeWindow();
  return {
    set src(v) { this._src = v; },
    get src() { return this._src; },
    set allow(v) { this._allow = v; },
    set title(v) { this._title = v; },
    set style(_v) { /* the SDK assigns a string to .style.cssText */ },
    style: { set cssText(_v) {} },
    contentWindow: cw,
    get parentNode() { return this._parent; },
  };
}

function setup() {
  const win = makeWindow();
  const sdk = loadSdk(win);
  const calls = { onSubmitted: [], onReady: [], onError: [], onPermissions: [], onRecording: [], onProgress: [] };
  const handle = sdk.mount("#mount", {
    sessionId: "sess-1",
    bootstrapToken: "boot-1",
    iframeSrc: "https://recorder.yourdomain.com",
    onSubmitted:   (e) => calls.onSubmitted.push(e),
    onReady:       (e) => calls.onReady.push(e),
    onError:       (e) => calls.onError.push(e),
    onPermissions: (e) => calls.onPermissions.push(e),
    onRecording:   (e) => calls.onRecording.push(e),
    onProgress:    (e) => calls.onProgress.push(e),
  });
  return { win, sdk, handle, calls };
}

test("ready handshake captures channelId and posts auth to the iframe origin", () => {
  const { win, handle } = setup();
  // Simulate the iframe sending `ready`.
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  const posts = handle.iframe.contentWindow.posts;
  assert.equal(posts.length, 1, "SDK should post auth in response to ready");
  assert.equal(posts[0].target, "https://recorder.yourdomain.com", "auth must target the iframe origin, not '*'");
  assert.equal(posts[0].payload.type, "auth");
  assert.equal(posts[0].payload.channelId, "ch-1");
  assert.equal(posts[0].payload.bootstrapToken, "boot-1");
});

test("messages from a non-iframe source are dropped", () => {
  const { win, handle, calls } = setup();
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  // Spoof from a different source window with valid-looking payload.
  win.deliver({
    source: { fake: true },
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "session_submitted", channelId: "ch-1", sessionId: "sess-1" },
  });
  assert.equal(calls.onSubmitted.length, 0);
});

test("messages from a different origin are dropped", () => {
  const { win, handle, calls } = setup();
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://attacker.example.com",
    data: { v: 1, type: "session_submitted", channelId: "ch-1", sessionId: "sess-1" },
  });
  assert.equal(calls.onSubmitted.length, 0);
});

test("messages with the wrong channelId are dropped", () => {
  const { win, handle, calls } = setup();
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "session_submitted", channelId: "ch-DIFFERENT", sessionId: "sess-1" },
  });
  assert.equal(calls.onSubmitted.length, 0);
});

test("valid messages of every protocol type fire their callbacks", () => {
  const { win, handle, calls } = setup();
  const send = (type, extra = {}) =>
    win.deliver({
      source: handle.iframe.contentWindow,
      origin: "https://recorder.yourdomain.com",
      data: Object.assign({ v: 1, type, channelId: "ch-1" }, extra),
    });

  send("ready", { channelId: "ch-1" });
  send("permissions_granted");
  send("permissions_denied");
  send("recording_started", { position: 1 });
  send("recording_stopped", { position: 1, durationMs: 30000 });
  send("upload_progress", { sessionId: "sess-1", percent: 42 });
  send("session_submitted", { sessionId: "sess-1" });
  send("session_ready", { sessionId: "sess-1" });
  send("error", { code: "boom", message: "kaboom" });

  assert.equal(calls.onPermissions.length, 2);
  assert.equal(calls.onRecording.length, 2);
  assert.equal(calls.onProgress.length, 1);
  assert.equal(calls.onProgress[0].percent, 42);
  assert.equal(calls.onSubmitted.length, 1);
  assert.equal(calls.onReady.length, 1);
  assert.equal(calls.onError.length, 1);
});

test("unknown message types are silently ignored", () => {
  const { win, handle, calls } = setup();
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "make_coffee", channelId: "ch-1" },
  });
  // Nothing throws, no callback fires.
  assert.equal(
    calls.onPermissions.length + calls.onRecording.length + calls.onProgress.length +
      calls.onSubmitted.length + calls.onReady.length + calls.onError.length,
    0
  );
});

test("messages received before `ready` are dropped (no channelId yet)", () => {
  const { win, handle, calls } = setup();
  // No `ready` first — channelId is still null.
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "session_submitted", channelId: "anything", sessionId: "sess-1" },
  });
  assert.equal(calls.onSubmitted.length, 0);
});

test("bootstrapTokenInUrl skips the auth postMessage", () => {
  const win = makeWindow();
  const sdk = loadSdk(win);
  const handle = sdk.mount("#mount", {
    sessionId: "sess-1",
    bootstrapToken: "boot-1",
    iframeSrc: "https://recorder.yourdomain.com",
    bootstrapTokenInUrl: true,
  });
  win.deliver({
    source: handle.iframe.contentWindow,
    origin: "https://recorder.yourdomain.com",
    data: { v: 1, type: "ready", channelId: "ch-1" },
  });
  assert.equal(handle.iframe.contentWindow.posts.length, 0,
    "bootstrapTokenInUrl path must not emit `auth` (token is already in src)");
});
