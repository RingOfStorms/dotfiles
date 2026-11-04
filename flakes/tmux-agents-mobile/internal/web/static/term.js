// Terminal tab: xterm.js on a WebSocket to a login shell (internal/term).
//
// Zoom is font size, never page scale. A pinch, a trackpad pinch (ctrl+wheel)
// or the menu changes the font, the grid is re-fitted to the screen and the
// shell gets the new size, so text is always rendered at the size it is shown
// at. xterm's default DOM renderer draws real text, which also stays sharp
// under browser zoom (ctrl +/-); a resize there refits the same way.
//
// The socket is expected to drop (phones close it when the app is
// backgrounded). The shell keeps running on the server; the page reconnects
// with the count of output bytes it has already drawn and continues from
// there, or redraws from the server's replay buffer if it has no screen.
//
// A redraw contains terminal queries asked long ago, often by a program that
// has since exited; xterm would answer them as input to whatever runs now.
// The server marks where history ends ("replay"), and everything the terminal
// says while it is still parsing those bytes is dropped. That includes, on a
// reconnect, output another tab was sent in the meantime: the page reconnects
// with the generation of the attachment that last drew its screen, so the
// server can tell.
(() => {
  "use strict";

  const el = document.getElementById("term");
  if (!el || !window.Terminal) return;

  const ID_KEY = "tam.term.id";
  const FONT_KEY = "tam.term.font";
  const MIN_FONT = 7;
  const MAX_FONT = 36;
  const defaultFont = () => (Math.min(screen.width, screen.height) < 600 ? 13 : 15);

  const clampFont = (px) => Math.max(MIN_FONT, Math.min(MAX_FONT, Math.round(px)));
  const savedFont = Number(localStorage.getItem(FONT_KEY));

  const css = getComputedStyle(document.documentElement);
  const term = new Terminal({
    fontFamily: css.getPropertyValue("--mono").trim() || "monospace",
    fontSize: clampFont(savedFont || defaultFont()),
    cursorBlink: true,
    scrollback: 5000,
    // Required by the unicode11 addon.
    allowProposedApi: true,
    macOptionIsMeta: true,
    // Catppuccin Mocha, matching app.css.
    theme: {
      background: "#11111b",
      foreground: "#cdd6f4",
      cursor: "#f5e0dc",
      cursorAccent: "#11111b",
      selectionBackground: "#585b7099",
      black: "#45475a",
      red: "#f38ba8",
      green: "#a6e3a1",
      yellow: "#f9e2af",
      blue: "#89b4fa",
      magenta: "#f5c2e7",
      cyan: "#94e2d5",
      white: "#bac2de",
      brightBlack: "#585b70",
      brightRed: "#f38ba8",
      brightGreen: "#a6e3a1",
      brightYellow: "#f9e2af",
      brightBlue: "#89b4fa",
      brightMagenta: "#f5c2e7",
      brightCyan: "#94e2d5",
      brightWhite: "#a6adc8",
    },
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new WebLinksAddon.WebLinksAddon());
  term.loadAddon(new Unicode11Addon.Unicode11Addon());
  term.unicode.activeVersion = "11";
  term.open(el);

  /* ---------------- sizing ---------------- */

  // The page is sized to the visual viewport, so the on-screen keyboard
  // shrinks the terminal (fewer rows) instead of covering its bottom. Android
  // does this by itself with interactive-widget=resizes-content; iOS needs it.
  const vv = window.visualViewport;
  const root = document.documentElement;
  function sizeToViewport() {
    if (!vv) return;
    root.style.setProperty("--app-h", `${vv.height}px`);
    root.style.setProperty("--app-top", `${vv.offsetTop}px`);
  }
  if (vv) {
    vv.addEventListener("resize", sizeToViewport);
    vv.addEventListener("scroll", sizeToViewport);
    sizeToViewport();
  }

  let fitFrame = 0;
  function refit() {
    if (fitFrame) return;
    fitFrame = requestAnimationFrame(() => {
      fitFrame = 0;
      // fit() throws while the element has no size (hidden tab).
      try {
        fit.fit();
      } catch {}
    });
  }
  new ResizeObserver(refit).observe(el);
  try {
    fit.fit();
  } catch {}

  function setFont(px, persist) {
    px = clampFont(px);
    if (px !== term.options.fontSize) {
      term.options.fontSize = px;
      refit();
    }
    if (persist) localStorage.setItem(FONT_KEY, String(px));
  }

  // Pinch on the terminal: intercepted in the capture phase so neither the
  // page (zoom) nor xterm (two-finger scroll) sees it.
  let pinch = null;
  const span = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
  el.addEventListener(
    "touchstart",
    (e) => {
      if (e.touches.length !== 2) return;
      pinch = { d: span(e.touches) || 1, size: term.options.fontSize };
      e.preventDefault();
      e.stopPropagation();
    },
    { capture: true, passive: false }
  );
  el.addEventListener(
    "touchmove",
    (e) => {
      if (!pinch) return;
      e.preventDefault();
      e.stopPropagation();
      if (e.touches.length === 2) setFont((pinch.size * span(e.touches)) / pinch.d, false);
    },
    { capture: true, passive: false }
  );
  const endPinch = (e) => {
    if (!pinch || e.touches.length >= 2) return;
    pinch = null;
    setFont(term.options.fontSize, true);
    e.stopPropagation();
  };
  el.addEventListener("touchend", endPinch, { capture: true });
  el.addEventListener("touchcancel", endPinch, { capture: true });
  // iOS Safari zooms the page on pinch even with user-scalable=no.
  for (const type of ["gesturestart", "gesturechange"]) {
    document.addEventListener(type, (e) => e.preventDefault(), { passive: false });
  }
  // Trackpad pinch on a desktop browser arrives as ctrl+wheel.
  el.addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      e.stopPropagation();
      setFont(term.options.fontSize - Math.sign(e.deltaY), true);
    },
    { capture: true, passive: false }
  );

  /* ---------------- connection ---------------- */

  const enc = new TextEncoder();
  const statusEl = document.getElementById("term-status");
  let ws = null;
  let id = localStorage.getItem(ID_KEY) || "";
  let offset = 0; // output bytes drawn so far; the reconnect point
  let gen = 0; // the attachment that drew them (from hello)
  let historyEnd = 0; // output before this offset is a redraw, not news
  let replaying = 0; // history writes xterm has not parsed yet
  let ended = false;
  let failures = 0;
  let retryTimer = 0;
  let statusAction = null;

  if (new URLSearchParams(location.search).has("new")) {
    // The "new shell" link without JS handling, or an explicit request: start
    // fresh and leave the old shell to its detach timeout.
    id = "";
    localStorage.removeItem(ID_KEY);
    history.replaceState(null, "", "/term");
  }

  function status(text, action) {
    statusEl.textContent = text || "";
    statusEl.hidden = !text;
    statusAction = action || null;
  }
  statusEl.addEventListener("click", () => statusAction && statusAction());

  function socketURL() {
    const q = new URLSearchParams({
      id,
      from: String(offset),
      gen: String(gen),
      cols: String(term.cols),
      rows: String(term.rows),
    });
    return `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/term/ws?${q}`;
  }

  function connect() {
    clearTimeout(retryTimer);
    retryTimer = 0;
    if (ws) return;
    const sock = new WebSocket(socketURL());
    sock.binaryType = "arraybuffer";
    ws = sock;
    sock.onmessage = (e) => {
      if (typeof e.data !== "string") {
        const bytes = new Uint8Array(e.data);
        offset += bytes.length;
        // The server never splits a message across historyEnd. Counted down
        // in xterm's write callback, which runs once the bytes are parsed
        // (and their queries answered), not when they arrive.
        if (offset <= historyEnd) {
          replaying++;
          term.write(bytes, () => replaying--);
        } else {
          term.write(bytes);
        }
        return;
      }
      const m = JSON.parse(e.data);
      switch (m.t) {
        case "hello":
          // A replay, if any, follows; it applies to this socket only.
          historyEnd = 0;
          if (id && m.id !== id) {
            // The shell we had is gone (ended, reaped, service restarted):
            // this is a new one, so the old screen is meaningless.
            term.reset();
            offset = 0;
          }
          id = m.id;
          gen = m.gen || 0;
          localStorage.setItem(ID_KEY, id);
          failures = 0;
          status("");
          break;
        case "reset":
          term.reset();
          offset = m.at || 0;
          historyEnd = 0;
          break;
        case "replay":
          historyEnd = m.until;
          break;
        case "exit":
          ended = true;
          id = "";
          localStorage.removeItem(ID_KEY);
          status(`shell exited${m.code ? ` (${m.code})` : ""} · tap or type for a new one`, () => newShell(false));
          break;
      }
    };
    sock.onclose = (e) => {
      if (ws !== sock) return;
      ws = null;
      if (ended) return;
      if (e.code === 4001) {
        status("open in another tab · tap to use it here", connect);
        return;
      }
      failures++;
      // Past a few failures the cause is likely not the network: an expired
      // sign-in turns the handshake into a redirect, which only a page load
      // can follow.
      status(
        failures > 3 ? "can't reach the shell · tap to reload" : "reconnecting…",
        failures > 3 ? () => location.reload() : connect
      );
      retryTimer = setTimeout(connect, Math.min(10000, 300 * 2 ** failures));
    };
  }

  function drop(sock) {
    sock.onmessage = null;
    sock.onclose = null;
    sock.close();
  }

  function newShell(ask) {
    if (ask && !window.confirm("End this shell and start a new one?")) return;
    if (ws) {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "close" }));
      drop(ws);
      ws = null;
    }
    id = "";
    localStorage.removeItem(ID_KEY);
    offset = 0;
    gen = 0;
    ended = false;
    failures = 0;
    term.reset();
    status("");
    connect();
    term.focus();
  }

  function send(data) {
    if (ended) {
      newShell(false);
      return;
    }
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(enc.encode(data));
  }

  let resizeTimer = 0;
  term.onResize(({ cols, rows }) => {
    clearTimeout(resizeTimer);
    // A pinch resizes on every frame; the shell only needs the final size.
    resizeTimer = setTimeout(() => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "resize", cols, rows }));
    }, 80);
  });

  // Phones suspend the page and kill the socket; come back immediately
  // rather than waiting out the backoff.
  const wake = () => {
    if (document.visibilityState === "visible" && !ws && !ended) {
      failures = 0;
      connect();
    }
  };
  document.addEventListener("visibilitychange", wake);
  window.addEventListener("online", wake);
  window.addEventListener("pageshow", wake);

  /* ---------------- input ---------------- */

  // Sticky modifiers from the key bar apply to the next key, typed or tapped.
  const mods = { ctrl: false, alt: false };
  const modButtons = document.querySelectorAll(".term-keys [data-mod]");
  function setMod(name, on) {
    mods[name] = on;
    for (const b of modButtons) {
      if (b.dataset.mod === name) b.setAttribute("aria-pressed", String(on));
    }
  }
  function clearMods() {
    setMod("ctrl", false);
    setMod("alt", false);
  }

  function withMods(data) {
    if (!mods.ctrl && !mods.alt) return data;
    let out = data;
    if (mods.ctrl && data.length === 1) {
      const code = data.toUpperCase().charCodeAt(0);
      if (code >= 64 && code <= 95) out = String.fromCharCode(code & 31);
      else if (data === " ") out = "\x00";
      else if (data === "?") out = "\x7f";
      else if (data === "/") out = "\x1f";
    }
    if (mods.alt) out = "\x1b" + out;
    clearMods();
    return out;
  }

  // While a redraw is being parsed, xterm's output is its answers to old
  // queries (and the odd keystroke typed in that moment): drop it.
  term.onData((data) => {
    if (!replaying) send(withMods(data));
  });
  term.onBinary((data) => {
    if (replaying) return;
    const bytes = Uint8Array.from(data, (c) => c.charCodeAt(0));
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(bytes);
  });

  // Cursor and editing keys, xterm-style: SS3/CSI A-D in application cursor
  // mode or not, and CSI 1;<mod> X once a modifier is held.
  const cursorKeys = { up: "A", down: "B", right: "C", left: "D", home: "H", end: "F" };
  const tildeKeys = { pgup: "5", pgdn: "6" };
  function keySequence(name) {
    const mod = 1 + (mods.alt ? 2 : 0) + (mods.ctrl ? 4 : 0);
    if (cursorKeys[name]) {
      const k = cursorKeys[name];
      if (mod > 1) return `\x1b[1;${mod}${k}`;
      return (term.modes.applicationCursorKeysMode ? "\x1bO" : "\x1b[") + k;
    }
    if (tildeKeys[name]) return mod > 1 ? `\x1b[${tildeKeys[name]};${mod}~` : `\x1b[${tildeKeys[name]}~`;
    switch (name) {
      case "esc":
        return "\x1b";
      case "tab":
        return "\t";
      case "^c":
        return "\x03";
    }
    return null;
  }

  for (const b of document.querySelectorAll(".term-keys button")) {
    // Keep focus (and the on-screen keyboard) on the terminal.
    b.addEventListener("pointerdown", (e) => e.preventDefault());
    b.addEventListener("click", () => {
      if (b.dataset.mod) {
        setMod(b.dataset.mod, !mods[b.dataset.mod]);
        return;
      }
      const name = b.dataset.send;
      const seq = keySequence(name);
      if (seq === null) {
        send(withMods(name));
        return;
      }
      clearMods();
      send(seq);
    });
  }

  /* ---------------- menu ---------------- */

  function menuAction(selector, fn) {
    for (const a of document.querySelectorAll(selector)) {
      a.addEventListener("click", (e) => {
        e.preventDefault();
        const menu = a.closest("details");
        if (menu) menu.open = false;
        fn();
      });
    }
  }
  menuAction(".js-font-up", () => setFont(term.options.fontSize + 1, true));
  menuAction(".js-font-down", () => setFont(term.options.fontSize - 1, true));
  menuAction(".js-new-shell", () => newShell(true));

  connect();
  term.focus();
})();
