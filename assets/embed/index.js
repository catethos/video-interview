/* @you/interview-embed — Phase 3 SDK.
 *
 * Tiny customer-facing JS that mounts the recorder iframe, runs the
 * postMessage handshake (PLAN §4.3), and exposes a clean event API.
 *
 * Public surface:
 *
 *   YourInterview.mount(target, {
 *     sessionId,                 // returned by POST /api/sessions on the customer backend
 *     bootstrapToken,            // single-use, ≤5 min, returned by POST /api/sessions
 *     iframeSrc,                 // base origin of the recorder; defaults to where this script was loaded from
 *     bootstrapTokenInUrl: false,// opt-in fallback: pass token via ?token= instead of postMessage
 *     onReady, onSubmitted, onError, onPermissions, onRecording, onProgress,
 *     onUnsupportedBrowser,      // mobile / Firefox / Safari detected; SDK rendered the blocking UI
 *     onPopoutRequested,         // returns Promise<{popoutUrl} | {bootstrapToken}> — must hit customer backend
 *   })
 *
 * Returns a handle: { iframe, mobile, unsupportedBrowser, unmount(), popout() }.
 *
 * Invariants (PLAN §4.3):
 *   - Every inbound postMessage is validated against (origin, source, channelId, schema).
 *     Origin is the iframe URL's origin (captured at mount); source is the iframe's contentWindow
 *     at the time `ready` arrived; channelId is the nonce the iframe sent in `ready`.
 *   - Outbound `auth` is posted to the *specific* iframe origin, never '*'.
 *   - `popout()` requires the customer to mint a NEW bootstrap (we never reuse the embed's token).
 *   - `popout()` runs from a user-gesture handler and uses noopener,noreferrer.
 */
(function () {
  "use strict";

  var ALLOW = "camera; microphone; autoplay; fullscreen";

  function isMobile() {
    var ua = (navigator.userAgent || "").toLowerCase();
    if (/iphone|ipad|ipod|android|mobile/.test(ua)) return true;
    if (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1) return true;
    return false;
  }

  // v1 supports Chrome + Edge desktop only (PLAN decision #14). Firefox,
  // Safari macOS, and mobile all hit the same blocking UI.
  function isUnsupportedBrowser() {
    if (isMobile()) return true;
    var ua = navigator.userAgent || "";
    // Chrome / Edge user agents include "Chrome/<ver>" and Edge adds " Edg/".
    // Firefox: "Firefox/<ver>". Safari (no Chrome): "Safari/<ver>" without "Chrome".
    if (/Firefox\//.test(ua)) return true;
    if (/Safari\//.test(ua) && !/Chrome\//.test(ua)) return true;
    return false;
  }

  function urlOrigin(input) {
    try {
      return new URL(input, location.href).origin;
    } catch (_) {
      return null;
    }
  }

  // The script's own origin — used as the default iframeSrc so the customer's
  // mount() call can be a single line.
  function scriptOrigin() {
    var s = document.currentScript;
    if (s && s.src) return urlOrigin(s.src);
    return null;
  }
  var DEFAULT_IFRAME_SRC = scriptOrigin();

  function ensureHost(target) {
    var host = typeof target === "string" ? document.querySelector(target) : target;
    if (!host) throw new Error("YourInterview.mount: target not found: " + target);
    return host;
  }

  function renderBrowserBlock(host) {
    host.innerHTML =
      '<div style="font-family:system-ui,sans-serif;max-width:520px;margin:24px auto;padding:16px;border:1px solid #ddd;border-radius:8px">' +
      '<h2 style="margin:0 0 8px 0;font-size:16px">Please complete this in desktop Chrome or Edge.</h2>' +
      '<p style="font-size:14px;color:#444">This interview needs a recording engine that only Chrome and Edge fully support today. Open this link on a laptop or desktop running Chrome 100+ or Edge 100+.</p>' +
      '<form data-role="email-link" style="display:flex;gap:8px;margin-top:12px">' +
      '<input type="email" required placeholder="you@example.com" name="email" style="flex:1;padding:6px 8px;border:1px solid #ccc;border-radius:6px"/>' +
      '<button type="submit" style="padding:6px 12px;border:0;background:#4c6ef5;color:#fff;border-radius:6px">Email me this link</button>' +
      "</form></div>";
  }

  function mount(target, options) {
    options = options || {};
    var host = ensureHost(target);

    if (isUnsupportedBrowser()) {
      renderBrowserBlock(host);
      var form = host.querySelector('[data-role="email-link"]');
      if (form && typeof options.onUnsupportedBrowser === "function") {
        form.addEventListener("submit", function (e) {
          e.preventDefault();
          var input = form.querySelector('input[name="email"]');
          options.onUnsupportedBrowser({ email: (input && input.value) || "" });
          form.innerHTML = '<p style="font-size:14px">Sent. Check your inbox.</p>';
        });
      }
      return {
        mobile: isMobile(),
        unsupportedBrowser: true,
        unmount: function () { host.innerHTML = ""; },
        popout: function () { /* no-op on unsupported browser */ },
      };
    }

    var sessionId = options.sessionId;
    var bootstrap = options.bootstrapToken;
    if (!sessionId) throw new Error("YourInterview.mount: sessionId required");
    if (!bootstrap) throw new Error("YourInterview.mount: bootstrapToken required");

    var iframeSrc = options.iframeSrc || DEFAULT_IFRAME_SRC;
    if (!iframeSrc) {
      throw new Error(
        "YourInterview.mount: iframeSrc required " +
          "(could not infer from document.currentScript)"
      );
    }
    var iframeBase = String(iframeSrc).replace(/\/+$/, "");
    var captureUrl = iframeBase + "/capture/" + encodeURIComponent(sessionId);
    var useUrlToken = options.bootstrapTokenInUrl === true;
    if (useUrlToken) {
      captureUrl += "?token=" + encodeURIComponent(bootstrap);
    }
    var iframeOrigin = urlOrigin(captureUrl);
    if (!iframeOrigin) throw new Error("YourInterview.mount: invalid iframeSrc: " + iframeSrc);

    var iframe = document.createElement("iframe");
    iframe.src = captureUrl;
    iframe.allow = ALLOW;
    iframe.style.cssText = "width:100%;height:100%;border:0";
    iframe.title = "Interview recorder";
    host.appendChild(iframe);

    var channelId = null;
    var sourceWindow = null;
    var torn = false;

    function call(name, payload) {
      var fn = options[name];
      if (typeof fn !== "function") return;
      try {
        fn(payload);
      } catch (err) {
        // A throwing callback shouldn't kill the SDK message loop.
        if (typeof console !== "undefined" && console.error) console.error(name, err);
      }
    }

    function onMessage(event) {
      // Source check first — silently drop anything not from this iframe.
      if (event.source !== iframe.contentWindow) return;
      if (event.origin !== iframeOrigin) return;
      var d = event.data;
      if (!d || typeof d !== "object" || d.v !== 1 || typeof d.type !== "string") return;

      // `ready` establishes the channelId nonce and the source window we'll
      // accept further messages from.
      if (d.type === "ready") {
        if (typeof d.channelId !== "string" || !d.channelId) return;
        channelId = d.channelId;
        sourceWindow = iframe.contentWindow;
        if (!useUrlToken) {
          sourceWindow.postMessage(
            { v: 1, type: "auth", channelId: channelId, bootstrapToken: bootstrap },
            iframeOrigin
          );
        }
        return;
      }

      // After `ready`, every message must carry the captured channelId.
      if (channelId === null) return;
      if (d.channelId !== channelId) return;

      switch (d.type) {
        case "permissions_granted":
        case "permissions_denied":
          call("onPermissions", { type: d.type });
          break;
        case "recording_started":
          call("onRecording", { type: "recording_started", position: d.position });
          break;
        case "recording_stopped":
          call("onRecording", {
            type: "recording_stopped",
            position: d.position,
            durationMs: d.durationMs,
          });
          break;
        case "upload_progress":
          call("onProgress", { sessionId: d.sessionId, percent: d.percent });
          break;
        case "session_submitted":
          call("onSubmitted", { sessionId: d.sessionId });
          break;
        case "session_ready":
          call("onReady", { sessionId: d.sessionId });
          break;
        case "error":
          call("onError", { code: d.code, message: d.message });
          break;
        default:
          // Unknown type — silently drop per PLAN §4.3.
          break;
      }
    }
    window.addEventListener("message", onMessage);

    function postToIframe(message) {
      if (!sourceWindow || channelId === null) return false;
      var payload = {};
      for (var k in message) if (Object.prototype.hasOwnProperty.call(message, k)) payload[k] = message[k];
      payload.v = 1;
      payload.channelId = channelId;
      sourceWindow.postMessage(payload, iframeOrigin);
      return true;
    }

    function unmount() {
      if (torn) return;
      torn = true;
      window.removeEventListener("message", onMessage);
      if (iframe.parentNode) iframe.parentNode.removeChild(iframe);
    }

    function popout() {
      if (typeof options.onPopoutRequested !== "function") {
        throw new Error(
          "YourInterview.popout: onPopoutRequested required (mints a fresh bootstrap)"
        );
      }
      // Open a placeholder window synchronously to preserve the user-gesture.
      var win = window.open("", "_blank", "noopener,noreferrer");
      if (!win) {
        call("onError", { code: "popup_blocked", message: "Browser blocked the popup." });
        return null;
      }
      Promise.resolve(options.onPopoutRequested({ sessionId: sessionId }))
        .then(function (result) {
          if (!result) {
            try { win.close(); } catch (_) {}
            return;
          }
          var url = result.popoutUrl;
          if (!url && result.bootstrapToken) {
            url =
              iframeBase +
              "/capture/" +
              encodeURIComponent(sessionId) +
              "?token=" +
              encodeURIComponent(result.bootstrapToken);
          }
          if (!url) {
            try { win.close(); } catch (_) {}
            return;
          }
          win.location.href = url;
          unmount();
        })
        .catch(function (err) {
          call("onError", { code: "popout_failed", message: String(err) });
          try { win.close(); } catch (_) {}
        });
      return win;
    }

    return {
      iframe: iframe,
      mobile: false,
      unmount: unmount,
      popout: popout,
      // Optional command surface (PLAN §4.3 inbound). v1 LV may no-op some.
      start: function () { return postToIframe({ type: "start" }); },
      pause: function () { return postToIframe({ type: "pause" }); },
      resume: function () { return postToIframe({ type: "resume" }); },
      setLocale: function (locale) { return postToIframe({ type: "set_locale", locale: locale }); },
    };
  }

  // Hooks for tests (validate via fake-window harness).
  var YourInterview = {
    mount: mount,
    _isMobile: isMobile,
    _isUnsupportedBrowser: isUnsupportedBrowser,
    _version: "v1"
  };
  if (typeof window !== "undefined") window.YourInterview = YourInterview;
  if (typeof module !== "undefined" && module.exports) module.exports = YourInterview;
})();
