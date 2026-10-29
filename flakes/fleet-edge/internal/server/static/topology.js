// /topology: pan (drag), zoom (wheel, pinch, buttons, + - 0 keys), node
// selection with an info panel, layer toggles, and a 30s live refresh that
// swaps in the server-rendered /topology.svg (no layout logic here).
(() => {
  "use strict";
  const stage = document.getElementById("topo-stage");
  if (!stage) return;
  const svg = stage.querySelector("svg#topo");
  const panel = document.getElementById("topo-info");
  const MIN_K = 0.4, MAX_K = 8, REFRESH_MS = 30000;
  let t = { x: 0, y: 0, k: 1 };
  let meta = parseMeta(svg);
  let selected = "";

  function parseMeta(root) {
    try {
      return JSON.parse(root.querySelector("#topo-meta").textContent) || {};
    } catch {
      return {};
    }
  }

  // ---- pan / zoom ------------------------------------------------------
  const viewport = () => svg.querySelector("#topo-viewport");
  const clamp = (k) => Math.min(MAX_K, Math.max(MIN_K, k));
  function apply() {
    viewport().setAttribute("transform", `translate(${t.x} ${t.y}) scale(${t.k})`);
  }
  // Screen point -> viewBox coordinates (outside the pan/zoom transform).
  function toSvg(cx, cy) {
    return new DOMPoint(cx, cy).matrixTransform(svg.getScreenCTM().inverse());
  }
  function zoomAt(p, factor) {
    const k = clamp(t.k * factor);
    const f = k / t.k;
    t = { x: p.x - (p.x - t.x) * f, y: p.y - (p.y - t.y) * f, k };
    apply();
  }
  function zoomCenter(factor) {
    const r = svg.getBoundingClientRect();
    zoomAt(toSvg(r.left + r.width / 2, r.top + r.height / 2), factor);
  }
  function fit() {
    t = { x: 0, y: 0, k: 1 };
    apply();
  }

  svg.addEventListener("wheel", (e) => {
    e.preventDefault();
    zoomAt(toSvg(e.clientX, e.clientY), Math.exp(-e.deltaY * (e.deltaMode ? 0.05 : 0.0015)));
  }, { passive: false });

  const pointers = new Map();
  let g = null; // current gesture
  function startGesture(target) {
    const pts = [...pointers.values()];
    if (pts.length === 1) {
      g = { type: "pan", start: toSvg(pts[0].x, pts[0].y), sx: pts[0].x, sy: pts[0].y, t0: { ...t }, moved: !!g, target };
    } else if (pts.length >= 2) {
      const a = toSvg(pts[0].x, pts[0].y), b = toSvg(pts[1].x, pts[1].y);
      g = { type: "pinch", d0: Math.hypot(a.x - b.x, a.y - b.y) || 1, m0: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, t0: { ...t } };
    }
  }
  svg.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 && e.pointerType === "mouse") return;
    svg.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) g = null;
    startGesture(e.target);
  });
  svg.addEventListener("pointermove", (e) => {
    if (!pointers.has(e.pointerId) || !g) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (g.type === "pan") {
      if (!g.moved && Math.hypot(e.clientX - g.sx, e.clientY - g.sy) < 5) return;
      g.moved = true;
      svg.classList.add("panning");
      const p = toSvg(e.clientX, e.clientY);
      t = { x: g.t0.x + p.x - g.start.x, y: g.t0.y + p.y - g.start.y, k: g.t0.k };
      apply();
    } else {
      const [p1, p2] = [...pointers.values()];
      const a = toSvg(p1.x, p1.y), b = toSvg(p2.x, p2.y);
      const k = clamp(g.t0.k * Math.hypot(a.x - b.x, a.y - b.y) / g.d0);
      const m = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      // Keep the world point that was under the start midpoint under the current one.
      const wx = (g.m0.x - g.t0.x) / g.t0.k, wy = (g.m0.y - g.t0.y) / g.t0.k;
      t = { x: m.x - wx * k, y: m.y - wy * k, k };
      apply();
    }
  });
  function endPointer(e) {
    if (!pointers.has(e.pointerId)) return;
    const wasClick = g && g.type === "pan" && !g.moved && e.type === "pointerup";
    const target = g && g.target;
    pointers.delete(e.pointerId);
    svg.classList.remove("panning");
    if (wasClick) {
      const node = target && target.closest && target.closest(".node");
      select(node ? node.dataset.id : "");
    }
    if (pointers.size > 0) {
      g = { moved: true }; // a lifted pinch finger must not become a click
      startGesture(null);
    } else {
      g = null;
    }
  }
  svg.addEventListener("pointerup", endPointer);
  svg.addEventListener("pointercancel", endPointer);
  svg.addEventListener("lostpointercapture", endPointer);
  svg.addEventListener("keydown", (e) => {
    const node = e.target.closest(".node");
    if (node && (e.key === "Enter" || e.key === " ")) {
      e.preventDefault();
      e.stopPropagation();
      select(node.dataset.id);
    }
  });

  stage.querySelectorAll("[data-zoom]").forEach((b) =>
    b.addEventListener("click", () => {
      const z = b.dataset.zoom;
      if (z === "fit") fit();
      else zoomCenter(z === "in" ? 1.4 : 1 / 1.4);
    }));
  stage.addEventListener("keydown", (e) => {
    if (e.target.closest("button, input, a")) return;
    if (e.key === "+" || e.key === "=") zoomCenter(1.25);
    else if (e.key === "-") zoomCenter(0.8);
    else if (e.key === "0") fit();
    else if (e.key === "Escape") select("");
    else return;
    e.preventDefault();
  });

  // ---- layers ----------------------------------------------------------
  const LAYER_KEY = "fleet-topology-hidden-layers";
  let hidden = new Set();
  try {
    hidden = new Set(JSON.parse(localStorage.getItem(LAYER_KEY) || "[]"));
  } catch { /* private mode: defaults */ }
  stage.querySelectorAll("input[data-layer]").forEach((cb) => {
    const layer = cb.dataset.layer;
    cb.checked = !hidden.has(layer);
    svg.classList.toggle("hide-" + layer, !cb.checked);
    cb.addEventListener("change", () => {
      svg.classList.toggle("hide-" + layer, !cb.checked);
      cb.checked ? hidden.delete(layer) : hidden.add(layer);
      try { localStorage.setItem(LAYER_KEY, JSON.stringify([...hidden])); } catch { /* ignore */ }
    });
  });

  // ---- selection + info panel -----------------------------------------
  const el = (tag, attrs = {}, ...kids) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") n.className = v;
      else n.setAttribute(k, v);
    }
    for (const kid of kids) if (kid != null) n.append(kid);
    return n;
  };
  const HOST_PILL = { online: "pill-reachable", down: "pill-unreachable", sleeping: "pill-sleeping", "no-endpoint": "pill-none" };
  const SVC_PILL = { active: "pill-active", inactive: "pill-inactive", failed: "pill-failed" };
  const KIND_LABEL = {
    wan: "WAN", ethernet: "ethernet", trunk: "trunk", wifi: "wi-fi", kvm: "KVM", power: "power/USB",
    tailnet: "tailnet", public: "public path", agent: "fleet-agent poll", control: "control",
  };

  function select(id) {
    selected = meta[id] ? id : "";
    if (selected) history.replaceState(null, "", "#" + encodeURIComponent(selected));
    else if (location.hash) history.replaceState(null, "", location.pathname + location.search);
    highlight();
    renderPanel();
  }

  function highlight() {
    const id = selected;
    svg.classList.toggle("has-sel", !!id);
    const near = new Set([id]);
    svg.querySelectorAll(".edge, .elabel").forEach((e) => {
      const on = !!id && (e.dataset.from === id || e.dataset.to === id);
      e.classList.toggle("hl", on);
      if (on) { near.add(e.dataset.from); near.add(e.dataset.to); }
    });
    svg.querySelectorAll(".node").forEach((n) => {
      n.classList.toggle("sel", n.dataset.id === id);
      n.classList.toggle("dim", !!id && !near.has(n.dataset.id));
    });
  }

  function renderPanel() {
    const info = meta[selected];
    panel.hidden = !info;
    panel.replaceChildren();
    if (!info) return;
    const head = el("div", { class: "topo-info-head" }, el("h2", {}, info.label));
    if (info.state !== "static") {
      head.append(el("span", { class: "pill " + (HOST_PILL[info.state] || "pill-none") }, info.state === "no-endpoint" ? "not polled" : info.state));
    }
    head.append(el("button", { type: "button", class: "topo-close", title: "Close (Esc)" }, "×"));
    head.querySelector(".topo-close").addEventListener("click", () => select(""));
    panel.append(head);
    const sub = [info.kind, info.role && info.role !== info.kind ? info.role : ""].filter(Boolean).join(" · ");
    if (sub) panel.append(el("p", { class: "muted topo-info-sub" }, sub));
    if (info.stateText) panel.append(el("p", { class: "topo-info-state" }, info.stateText));
    const facts = el("dl", { class: "topo-facts" });
    if (info.overlayIp) facts.append(el("dt", {}, "tailnet"), el("dd", { class: "mono" }, info.overlayIp));
    if (info.lanIp) facts.append(el("dt", {}, "lan"), el("dd", { class: "mono" }, info.lanIp));
    if (facts.childElementCount) panel.append(facts);
    if (info.lines && info.lines.length) {
      panel.append(el("ul", { class: "topo-lines" }, ...info.lines.map((l) => el("li", {}, l))));
    }
    if (info.containerHost) {
      panel.append(el("h3", {}, `Containers (${(info.services || []).length})`));
      const ul = el("ul", { class: "topo-svcs" });
      for (const s of info.services || []) {
        const li = el("li", {},
          el("span", { class: "pill " + (SVC_PILL[s.state] || "pill-unknown") }, s.state),
          " ", el("strong", {}, s.name),
          s.exposure ? el("span", { class: "badge badge-" + s.exposure }, s.exposure) : null);
        if (s.description) li.append(el("div", { class: "muted" }, s.description));
        for (const u of s.urls || []) {
          if (/^https?:\/\//.test(u)) li.append(el("div", {}, el("a", { href: u, target: "_blank", rel: "noopener" }, u.replace(/^https?:\/\//, ""))));
        }
        ul.append(li);
      }
      panel.append(ul);
    }
    if (info.links && info.links.length) {
      panel.append(el("h3", {}, "Connections"));
      const ul = el("ul", { class: "topo-links" });
      for (const l of info.links) {
        const peer = el("a", { href: "#" + encodeURIComponent(l.peer) }, l.peerLabel);
        peer.addEventListener("click", (e) => { e.preventDefault(); select(l.peer); });
        ul.append(el("li", {},
          el("span", { class: "topo-link-kind lk-" + l.layer }, KIND_LABEL[l.kind] || l.kind),
          l.out ? " → " : " ← ", peer,
          l.label ? el("span", { class: "muted" }, " · " + l.label) : null));
      }
      panel.append(ul);
    }
    if (info.href && (/^https?:\/\//i.test(info.href) || /^\/(?![\/\\])/.test(info.href))) {
      panel.append(el("p", {}, el("a", { href: info.href }, info.host ? `Open ${info.host} details →` : "Open →")));
    }
  }

  // ---- live refresh ----------------------------------------------------
  function summarize() {
    let polled = 0, online = 0, sleeping = 0, down = 0;
    for (const n of Object.values(meta)) {
      if (n.state === "online") online++;
      else if (n.state === "sleeping") sleeping++;
      else if (n.state === "down") down++;
      else continue;
      polled++;
    }
    const s = document.getElementById("topo-summary");
    const strong = (v, cls) => el("strong", cls ? { class: cls } : {}, String(v));
    const parts = [strong(online), "/", strong(polled), " polled hosts online"];
    if (sleeping) parts.push(" · ", strong(sleeping), " sleeping");
    if (down) parts.push(" · ", strong(down, "warn"), " down");
    parts.push(el("span", { class: "muted", id: "topo-updated" }, " · updated " + new Date().toLocaleTimeString()));
    s.replaceChildren(...parts);
  }

  let failures = 0;
  async function refresh() {
    if (document.visibilityState !== "visible" || pointers.size) return;
    try {
      const res = await fetch("/topology.svg", { credentials: "same-origin", cache: "no-store" });
      if (!res.ok || !(res.headers.get("content-type") || "").includes("svg")) throw new Error(res.status);
      const doc = new DOMParser().parseFromString(await res.text(), "image/svg+xml");
      const root = doc.getElementById("topo-root");
      if (!root || doc.querySelector("parsererror")) throw new Error("bad svg");
      if (pointers.size) return;
      svg.querySelector("#topo-root").replaceWith(document.importNode(root, true));
      const vb = doc.documentElement.getAttribute("viewBox");
      if (vb) svg.setAttribute("viewBox", vb);
      meta = parseMeta(doc);
      if (selected && !meta[selected]) select("");
      highlight();
      renderPanel();
      summarize();
      failures = 0;
    } catch {
      // Session expiry redirects to the login page (not SVG); say so once.
      if (++failures === 2) {
        const u = document.getElementById("topo-updated");
        if (u) u.textContent = " · live refresh failed (reload to sign in again)";
      }
    }
  }
  setInterval(refresh, REFRESH_MS);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refresh(); });

  function selectHash() {
    let id = "";
    try { id = decodeURIComponent(location.hash.slice(1)); } catch { /* invalid fragment */ }
    select(id);
  }
  window.addEventListener("hashchange", selectHash);
  selectHash();
})();
