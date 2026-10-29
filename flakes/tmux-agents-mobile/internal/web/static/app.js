// tmux-agents-mobile client: SSE frame patching, key forwarding, small form
// niceties. No frameworks; htmx is used only for the compose form.
(() => {
  "use strict";

  const frame = document.getElementById("frame");
  const pane = frame ? frame.dataset.pane : null;

  /* ---------------- compose ---------------- */

  const compose = document.getElementById("compose");
  if (compose) {
    const box = compose.querySelector("textarea");
    box.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        compose.requestSubmit();
      }
    });
    // htmx posts this form; the server replies 204 and the textarea clears.
    document.body.addEventListener("htmx:afterRequest", (e) => {
      if (e.detail && e.detail.elt === compose && e.detail.successful) {
        box.value = "";
        box.focus();
      }
    });
  }

  /* ---------------- confirmations ---------------- */

  for (const el of document.querySelectorAll("[data-confirm]")) {
    const form = el.closest("form");
    if (!form) continue;
    form.addEventListener("submit", (e) => {
      if (!window.confirm(el.dataset.confirm)) e.preventDefault();
    });
  }

  /* ---------------- frame streaming ---------------- */

  function connect(el) {
    const fit = el.dataset.fit === "1";
    const lines = [];
    for (const child of el.children) {
      lines.push({ n: Number(child.dataset.n || 0), h: child.innerHTML });
    }

    let follow = true;
    const atBottom = () =>
      el.scrollHeight - el.scrollTop - el.clientHeight < 48;
    el.addEventListener("scroll", () => {
      follow = atBottom();
    });

    // Fit mode shrinks the font just enough to show every column; never
    // larger than the configured terminal size.
    function fitFont(cols) {
      if (!fit || !cols) return;
      const base =
        parseFloat(
          getComputedStyle(document.documentElement).getPropertyValue("--term-size")
        ) || 22;
      const width = el.clientWidth - 18;
      const size = Math.max(5.5, Math.min(base, width / cols / 0.6));
      el.style.fontSize = size.toFixed(2) + "px";
    }

    const rowHTML = (i) => (lines[i] && lines[i].h) || "";

    // Rebuilding is only for structural changes (a scroll shift, or the row
    // count changing). Scroll offsets are restored when the reader is not
    // following the bottom, because in fit mode dragging sideways is the only
    // way to read the right-hand columns.
    function rebuild() {
      const top = el.scrollTop;
      const left = el.scrollLeft;
      const frag = document.createDocumentFragment();
      for (let i = 0; i < lines.length; i++) {
        const div = document.createElement("div");
        div.className = "line";
        div.dataset.n = String(i);
        div.innerHTML = rowHTML(i);
        frag.appendChild(div);
      }
      el.replaceChildren(frag);
      if (follow) {
        el.scrollTop = el.scrollHeight;
      } else {
        el.scrollTop = top;
        el.scrollLeft = left;
      }
    }

    // The common case: a few rows changed in place. Touching only those rows
    // keeps the scroll position, text selection and an in-progress drag intact.
    function patchRows(changed) {
      for (const l of changed) {
        const node = el.querySelector('.line[data-n="' + l.n + '"]');
        if (node) node.innerHTML = rowHTML(l.n);
      }
    }

    function setMeta(f) {
      if (f.cols) el.dataset.cols = f.cols;
      fitFont(f.cols);
    }

    function replace(f) {
      lines.length = 0;
      const src = f.lines || [];
      for (let i = 0; i < src.length; i++) lines.push(src[i]);
      setMeta(f);
      rebuild();
    }

    function patch(p) {
      if (p.full) {
        replace(p);
        return;
      }
      let structural = false;
      if (p.from) {
        const shifted = new Array(lines.length);
        for (let i = 0; i < lines.length; i++) {
          const j = i + p.from;
          shifted[i] = j >= 0 && j < lines.length ? lines[j] : { n: i, h: "" };
        }
        for (let i = 0; i < shifted.length; i++) lines[i] = shifted[i];
        structural = true;
      }
      const changed = p.lines || [];
      for (const l of changed) {
        if (l.n >= 0) lines[l.n] = l;
      }
      if (typeof p.total === "number" && p.total !== lines.length) {
        lines.length = p.total;
        for (let i = 0; i < lines.length; i++) {
          if (!lines[i]) lines[i] = { n: i, h: "" };
        }
        structural = true;
      }
      if (structural) rebuild();
      else patchRows(changed);
    }

    const es = new EventSource(
      "/p/" + pane + "/events?fit=" + (fit ? "1" : "0")
    );
    es.addEventListener("init", (e) => replace(JSON.parse(e.data)));
    es.addEventListener("full", (e) => replace(JSON.parse(e.data)));
    es.addEventListener("patch", (e) => patch(JSON.parse(e.data)));
    // A pane that exits (or is killed, or its session closes) has nothing left
    // to show: go back to the inbox instead of lingering on a dead screen.
    es.addEventListener("gone", () => {
      es.close();
      location.replace("/");
    });
    // A refused or closed stream means the same thing - the pane is gone, or
    // this tab outlived a restart. EventSource gives up (CLOSED) on non-2xx
    // and on a non-text/event-stream response, so treat that as gone too.
    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) location.replace("/");
    };
    window.addEventListener("resize", () => fitFont(Number(el.dataset.cols)));

    el.addEventListener("click", () => {
      if (document.body.classList.contains("raw")) sink && sink.focus();
    });
  }

  /* ---------------- raw keys ---------------- */

  const sink = document.getElementById("keysink");
  let raw = false;

  function send(payload) {
    if (!pane) return;
    fetch("/p/" + pane + "/keys", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      credentials: "same-origin",
    }).catch(() => {});
  }

  const special = {
    Enter: "Enter",
    Escape: "Escape",
    Tab: "Tab",
    Backspace: "BSpace",
    Delete: "DC",
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    Home: "Home",
    End: "End",
    PageUp: "PPage",
    PageDown: "NPage",
  };

  function translate(e) {
    if (e.ctrlKey && e.key.length === 1 && !e.altKey) {
      return { key: "C-" + e.key.toLowerCase() };
    }
    if (e.altKey && e.key.length === 1 && !e.ctrlKey) {
      return { key: "M-" + e.key.toLowerCase() };
    }
    if (e.shiftKey && e.key === "Tab") return { key: "BTab" };
    if (special[e.key]) return { key: special[e.key] };
    if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) return { text: e.key };
    return null;
  }

  if (sink) {
    sink.addEventListener("keydown", (e) => {
      if (!raw) return;
      const out = translate(e);
      if (!out) return;
      e.preventDefault();
      send(out);
    });

    // Soft keyboards do not always emit keydown for every character; use the
    // input event as the fallback and keep the sink empty.
    sink.addEventListener("input", () => {
      if (!raw) return;
      const v = sink.value;
      sink.value = "";
      if (v) send({ text: v });
    });
  }

  const toggle = document.querySelector("[data-raw-toggle]");
  if (toggle) {
    toggle.addEventListener("click", () => {
      raw = !raw;
      document.body.classList.toggle("raw", raw);
      toggle.textContent = raw ? "typing on" : "typing mode";
      // Close the popover so the keyboard has the screen.
      const menu = toggle.closest("details");
      if (menu) menu.open = false;
      if (raw) {
        if (sink) sink.focus({ preventScroll: true });
      } else if (sink) {
        sink.blur();
      }
    });
  }

  // Any tap outside an open menu or key popover closes it.
  document.addEventListener("click", (e) => {
    for (const d of document.querySelectorAll("details[data-menu][open]")) {
      if (!d.contains(e.target)) d.open = false;
    }
  });

  for (const btn of document.querySelectorAll("[data-key]")) {
    btn.addEventListener("click", () => send({ key: btn.dataset.key }));
  }

  /* ---------------- inbox: filter + refresh ---------------- */

  const filter = document.getElementById("filter");
  const cardsEl = document.querySelector(".cards");
  const noMatches = document.getElementById("no-matches");

  // Cards are replaced by the poll, so this queries them fresh each time.
  const applyFilter = () => {
    if (!cardsEl) return;
    const terms = filter ? filter.value.toLowerCase().split(/\s+/).filter(Boolean) : [];
    let visible = 0;
    for (const card of cardsEl.querySelectorAll(".card")) {
      const text = (card.dataset.text || "").toLowerCase();
      const on = terms.every((term) => text.includes(term));
      card.classList.toggle("hidden-card", !on);
      if (on) visible++;
    }
    if (noMatches) noMatches.hidden = visible > 0;
  };

  if (filter) {
    const toggle = document.getElementById("search-toggle");
    const bar = document.getElementById("searchbar");
    const close = document.getElementById("search-close");

    // The filter lives behind a button so the list owns the screen; closing it
    // clears the query, because a filter you cannot see must not stay applied.
    const setOpen = (open) => {
      if (!bar) return;
      bar.hidden = !open;
      if (toggle) {
        toggle.classList.toggle("is-open", open);
        toggle.setAttribute("aria-expanded", open ? "true" : "false");
      }
      if (open) {
        // Focus synchronously: the click is the user activation that lets the
        // phone open its keyboard, and a rAF in between can lose it.
        filter.focus();
        return;
      }
      if (filter.value !== "") {
        filter.value = "";
        applyFilter();
      }
      filter.blur();
    };

    toggle?.addEventListener("click", () => setOpen(bar.hidden));
    close?.addEventListener("click", () => setOpen(false));
    filter.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        setOpen(false);
      }
    });
    filter.addEventListener("input", applyFilter);
    filter.addEventListener("search", applyFilter);
    applyFilter();
  }

  // Panes appear, exit and change state on the computer; the list has to follow
  // without a reload. Polls pause while the tab is hidden or a finger is down
  // (swapping the DOM under a tap would swallow it), and only swap when the
  // markup actually changed.
  if (cardsEl) {
    let pressed = false;
    cardsEl.addEventListener("pointerdown", () => {
      pressed = true;
    });
    for (const ev of ["pointerup", "pointercancel"]) {
      window.addEventListener(ev, () => {
        pressed = false;
      });
    }

    const refresh = async () => {
      if (document.hidden || pressed) return;
      try {
        const res = await fetch("/?fragment=cards", {
          credentials: "same-origin",
          cache: "no-store",
        });
        if (!res.ok || res.headers.get("X-Fragment") !== "cards") return;
        const html = await res.text();
        if (html === cardsEl.innerHTML) return;
        const main = cardsEl.closest("main");
        const top = main ? main.scrollTop : 0;
        cardsEl.innerHTML = html;
        if (main) main.scrollTop = top;
        applyFilter();
      } catch (err) {
        // Offline or the server restarted: the next tick tries again.
      }
    };

    setInterval(refresh, 3000);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) refresh();
    });
  }

  /* ---------------- new-session directory picker ---------------- */

  const dirInput = document.getElementById("dir");
  const dirMenu = document.getElementById("dirmenu");
  if (dirInput && dirMenu) {
    const home = dirInput.closest("[data-home]")?.dataset.home || "";
    let items = [];
    let picked = -1; // -1: nothing chosen with the arrows, so Enter submits
    let timer = 0;
    let seq = 0;

    const short = (path) =>
      home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;

    const close = () => {
      dirMenu.hidden = true;
      dirMenu.replaceChildren();
      items = [];
      picked = -1;
    };

    const choose = (path) => {
      dirInput.value = path;
      close();
      dirInput.focus();
    };

    const paint = () => {
      dirMenu.replaceChildren();
      items.forEach((path, i) => {
        const li = document.createElement("li");
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = short(path);
        if (i === picked) b.className = "active";
        // mousedown would blur the input and close the menu before click lands
        b.addEventListener("mousedown", (e) => e.preventDefault());
        b.addEventListener("click", () => choose(path));
        li.appendChild(b);
        dirMenu.appendChild(li);
      });
      dirMenu.hidden = items.length === 0;
    };

    const run = () => {
      const mine = ++seq;
      fetch("/new/dirs?q=" + encodeURIComponent(dirInput.value.trim()), {
        credentials: "same-origin",
      })
        .then((res) => (res.ok ? res.json() : null))
        .then((data) => {
          if (mine !== seq || !data) return;
          items = data.items || [];
          picked = -1;
          paint();
        })
        .catch(() => {});
    };

    const schedule = () => {
      clearTimeout(timer);
      timer = setTimeout(run, 120);
    };

    dirInput.addEventListener("focus", schedule);
    dirInput.addEventListener("input", schedule);
    dirInput.addEventListener("keydown", (e) => {
      if (dirMenu.hidden) return;
      if (e.key === "ArrowDown") {
        e.preventDefault();
        picked = picked + 1 >= items.length ? 0 : picked + 1;
        paint();
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        picked = picked - 1 < 0 ? items.length - 1 : picked - 1;
        paint();
      } else if (e.key === "Enter" && picked >= 0) {
        e.preventDefault();
        choose(items[picked]);
      } else if (e.key === "Escape") {
        close();
      }
    });
    dirInput.addEventListener("blur", () => setTimeout(close, 120));
  }

  if (frame) connect(frame);

  // Installable app: the service worker only caches static assets. It needs a
  // secure context (https, or localhost during development).
  if ("serviceWorker" in navigator && window.isSecureContext) {
    addEventListener("load", () => {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    });
  }
})();
