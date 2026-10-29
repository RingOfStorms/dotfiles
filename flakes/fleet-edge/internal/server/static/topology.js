// /topology: a route atlas. The server lays out the map and renders it as
// standalone SVG; this script only pans/zooms, replays recorded frames, and
// draws journeys for the traffic events the backend reports. It never invents
// a route: an event animates only along anchors that exist (a public route
// through the edge or router hub, or a tailnet route to a placed host), and
// the virtual origin is a marker, never real internet gear.
(() => {
  "use strict";
  const stage = document.getElementById("topo-stage");
  if (!stage) return;
  const svg = stage.querySelector("svg#topo");
  if (!svg) return;
  const NS = "http://www.w3.org/2000/svg";
  const panel = document.getElementById("topo-info");
  const summaryEl = document.getElementById("topo-summary");
  const problemsEl = document.getElementById("topo-problems");
  const timeEl = document.getElementById("topo-time");
  const timeLabel = document.getElementById("topo-time-label");
  const timeMeta = document.getElementById("topo-time-meta");
  const timeNote = document.getElementById("topo-time-note");
  const playBtn = document.getElementById("topo-play");
  const speedEl = document.getElementById("topo-speed");
  const liveBtn = document.getElementById("topo-live");
  const simBadge = document.getElementById("topo-sim");
  const simNote = document.getElementById("topo-sim-note");
  const modeNote = document.getElementById("topo-mode-note");
  const attrEl = document.getElementById("topo-attr");
  const attrNote = document.getElementById("topo-attr-note");
  const side = stage.parentElement;

  const MIN_K = 0.4, MAX_K = 8, TRAFFIC_POLL_MS = 3000, STEP_MS = 30000;
  // MAX_STEP_MS bounds how long a replay trusts one window when the server
  // does not report a traffic window of its own.
  const MAX_STEP_MS = 60 * 1000;
  const MAX_DOTS = 64, MAX_SEEN = 4000;
  const VIEW_KEY = "fleet-topology-view";
  const LAYER_KEY = "fleet-topology-hidden-layers";
  const MODE_KEY = "fleet-topology-mode";
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const TIME_FMT = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

  // ---- model -----------------------------------------------------------
  let meta = {};              // node id -> NodeInfo
  let byHost = new Map();     // inventory host -> node id
  let hubs = {};              // tailnet / edge / router / dashboard node ids
  let dims = { w: 0, h: 0 };
  let playing = false;
  let playSpeed = 64;
  let suppressTraffic = false; // paused replay shows health, not new dots
  let failures = 0;
  let epoch = "";
  let frame = null;           // last frame body applied to the map
  let frameCountries = {};    // banned IP -> ISO country, from the frame
  let selected = "";          // node id shown in the sidebar
  let mode = "simulated";     // traffic mode: simulated | real
  let timeline = null;        // recorded health samples for the strip
  let cursor = null;          // replay clock in ms; null follows live
  let lastSnapshot = "";      // snapshotAt of the last applied frame
  // events waiting for the clock to reach them: replay paces traffic to the
  // recorded window instead of dumping a window's worth of dots at once.
  const pending = [];
  // ---- pan / zoom ------------------------------------------------------
  // The map is drawn at full size for the fleet, which is far wider than any
  // stage. Fitting it whole renders 7 px labels, so the first view scales up
  // until the name under a station is readable and centres the home station;
  // "fit" is still the explicit whole-fleet overview.
  const LABEL_UNITS = 13.5, LABEL_MIN_PX = 11.5;
  let t = { x: 0, y: 0, k: 1 };
  let autoView = true;        // no saved preference: derive the opening view
  try {
    const v = JSON.parse(localStorage.getItem(VIEW_KEY) || "null");
    if (v && Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.k)) {
      t = { x: v.x, y: v.y, k: Math.min(MAX_K, Math.max(MIN_K, v.k)) };
      // An identity view is the plain fit, which is also what a stale save
      // from a smaller diagram looks like: treat it as "no preference".
      autoView = t.k === 1 && t.x === 0 && t.y === 0;
    }
  } catch { /* private mode: identity */ }

  const viewport = () => svg.querySelector("#topo-viewport");
  let overlay = null;
  const clamp = (k) => Math.min(MAX_K, Math.max(MIN_K, k));
  function apply() {
    const vp = viewport();
    if (!vp) return;
    vp.setAttribute("transform", `translate(${t.x} ${t.y}) scale(${t.k})`);
    overlay = vp.querySelector("#topo-overlay");
  }
  function saveView() {
    try { localStorage.setItem(VIEW_KEY, JSON.stringify(t)); } catch { /* ignore */ }
  }
  function toSvg(cx, cy) {
    const m = svg.getScreenCTM();
    if (!m) return new DOMPoint(cx, cy);
    return new DOMPoint(cx, cy).matrixTransform(m.inverse());
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
    autoView = false;
    t = { x: 0, y: 0, k: 1 };
    apply();
    saveView();
  }

  // focusNode picks the station worth opening on: the host carrying the most
  // declared services among those currently up. A router or a cloud region
  // makes a poor centre because nothing in the fleet is anchored to it.
  function focusNode() {
    const scored = [];
    for (const [id, info] of Object.entries(meta)) {
      if (!info || !info.host || !Array.isArray(info.services) || !info.services.length) continue;
      if (!Number.isFinite(info.x) || !Number.isFinite(info.y)) continue;
      scored.push({ info, live: info.state === "online" ? 1 : 0, n: info.services.length });
    }
    if (scored.length) {
      scored.sort((a, b) => b.live - a.live || b.n - a.n);
      return scored[0].info;
    }
    return meta[hubs.edge] || meta[hubs.dashboard] || null;
  }
  // legibleK is the smallest zoom at which a station name clears
  // LABEL_MIN_PX on a stage of this size.
  function legibleK() {
    const r = svg.getBoundingClientRect();
    if (!r.width || !r.height || !dims.w || !dims.h) return 0;
    const base = Math.min(r.width / dims.w, r.height / dims.h);
    if (!(base > 0)) return 0;
    return clamp(Math.max(1, LABEL_MIN_PX / (LABEL_UNITS * base)));
  }
  // initialView parks the home station in the middle of the stage at that
  // scale. fit() stays the explicit whole-fleet overview.
  function initialView() {
    if (!autoView) return;
    const k = legibleK();
    if (!k) return;
    const r = svg.getBoundingClientRect();
    const focus = focusNode();
    const px = focus && Number.isFinite(focus.x) ? focus.x : dims.w / 2;
    const py = focus && Number.isFinite(focus.y) ? focus.y : dims.h / 2;
    const mid = toSvg(r.left + r.width / 2, r.top + r.height / 2);
    t = { x: mid.x - px * k, y: mid.y - py * k, k };
    apply();
  }
  // A view saved on a wide screen is unreadable on a phone: keep its centre
  // and raise the scale to this stage's floor once, never on every resize.
  let restoreChecked = false;
  function ensureLegible() {
    const k = legibleK();
    const r = svg.getBoundingClientRect();
    if (!k || t.k >= k || !r.width) return;
    const mid = toSvg(r.left + r.width / 2, r.top + r.height / 2);
    const px = (mid.x - t.x) / t.k, py = (mid.y - t.y) / t.k;
    t = { x: mid.x - px * k, y: mid.y - py * k, k };
    apply();
  }
  window.addEventListener("resize", () => {
    if (autoView) initialView();
    else { restoreChecked = false; ensureLegible(); }
  });

  svg.addEventListener("wheel", (e) => {
    e.preventDefault();
    autoView = false;
    zoomAt(toSvg(e.clientX, e.clientY), Math.exp(-e.deltaY * (e.deltaMode ? 0.05 : 0.0015)));
  }, { passive: false });

  const pointers = new Map();
  let g = null;
  function startGesture(target) {
    const pts = [...pointers.values()];
    if (pts.length === 1) {
      g = { type: "pan", start: toSvg(pts[0].x, pts[0].y), sx: pts[0].x, sy: pts[0].y, t0: { ...t }, moved: !!(g && g.moved), target };
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
      autoView = false;
      svg.classList.add("panning");
      const p = toSvg(e.clientX, e.clientY);
      t = { x: g.t0.x + p.x - g.start.x, y: g.t0.y + p.y - g.start.y, k: g.t0.k };
      apply();
    } else {
      const [p1, p2] = [...pointers.values()];
      const a = toSvg(p1.x, p1.y), b = toSvg(p2.x, p2.y);
      autoView = false;
      const k = clamp(g.t0.k * Math.hypot(a.x - b.x, a.y - b.y) / g.d0);
      const m = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
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
    saveView();
    if (wasClick) {
      const node = target && target.closest && target.closest(".node");
      select(node ? node.dataset.id : "");
    }
    if (pointers.size > 0) {
      g = { moved: true };
      startGesture(null);
    } else {
      g = null;
    }
  }
  svg.addEventListener("pointerup", endPointer);
  svg.addEventListener("pointercancel", endPointer);
  svg.addEventListener("lostpointercapture", endPointer);
  svg.addEventListener("keydown", (e) => {
    const node = e.target.closest && e.target.closest(".node");
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
      else { autoView = false; zoomCenter(z === "in" ? 1.4 : 1 / 1.4); }
      saveView();
    }));
  stage.addEventListener("keydown", (e) => {
    if (e.target.closest("button, input, a, select")) return;
    autoView = false;
    if (e.key === "+" || e.key === "=") zoomCenter(1.25);
    else if (e.key === "-") zoomCenter(0.8);
    else if (e.key === "0") fit();
    else if (e.key === "Escape") select("");
    else return;
    e.preventDefault();
    saveView();
  });

  // ---- layers + view modes --------------------------------------------
  let hidden = new Set();
  try {
    hidden = new Set(JSON.parse(localStorage.getItem(LAYER_KEY) || "[]"));
  } catch { /* private mode: defaults */ }
  const layerBoxes = side.querySelectorAll("input[data-layer]");
  layerBoxes.forEach((cb) => {
    const layer = cb.dataset.layer;
    cb.checked = !hidden.has(layer);
    svg.classList.toggle("hide-" + layer, !cb.checked);
    cb.addEventListener("change", () => {
      svg.classList.toggle("hide-" + layer, !cb.checked);
      if (cb.checked) hidden.delete(layer);
      else hidden.add(layer);
      try { localStorage.setItem(LAYER_KEY, JSON.stringify([...hidden])); } catch { /* ignore */ }
    });
  });
  const VIEWS = {
    overview: [],
    physical: ["tailnet", "public", "control"],
    control: ["physical", "tailnet", "public"],
  };
  function setView(name) {
    const off = VIEWS[name] || VIEWS.overview;
    svg.classList.toggle("view-overview", name === "overview");
    side.querySelectorAll("[data-view]").forEach((b) => b.classList.toggle("on", b.dataset.view === name));
    layerBoxes.forEach((cb) => {
      const want = !off.includes(cb.dataset.layer) && !hidden.has(cb.dataset.layer);
      cb.checked = want;
      svg.classList.toggle("hide-" + cb.dataset.layer, !want);
    });
  }
  side.querySelectorAll("[data-view]").forEach((b) =>
    b.addEventListener("click", () => setView(b.dataset.view)));
  svg.classList.add("view-overview");

  // ---- helpers ---------------------------------------------------------
  const el = (tag, attrs = {}, ...kids) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === "class") n.className = v;
      else n.setAttribute(k, v);
    }
    for (const kid of kids) if (kid != null && kid !== false) n.append(kid);
    return n;
  };
  const sEl = (tag, attrs = {}) => {
    const n = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    return n;
  };
  const parseMeta = (root) => {
    try {
      const node = root.querySelector("#topo-meta");
      return JSON.parse(node.textContent) || {};
    } catch {
      return {};
    }
  };
  const parseTime = (v) => {
    if (!v) return NaN;
    if (typeof v === "number") return v < 1e12 ? v * 1000 : v;
    const n = Date.parse(v);
    return Number.isFinite(n) ? n : NaN;
  };
  // asOfMs is the moment the health on screen belongs to: the applied frame's
  // snapshot, never the wall clock, so a replay never reads as stale.
  const asOfMs = () => parseTime(frame && frame.snapshotAt) || parseTime(frame && frame.at) || Date.now();
  // appliedMs is the clock the map is showing. It moves only when a frame
  // arrives, so the label and the strip cursor always describe the health that
  // is actually drawn rather than a request still in flight.
  const appliedMs = () => parseTime(frame && frame.at) || parseTime(frame && frame.snapshotAt) || NaN;
  function age(iso) {
    const ms = parseTime(iso);
    if (!Number.isFinite(ms)) return "";
    const d = Math.max(0, asOfMs() - ms);
    if (d < 90e3) return Math.round(d / 1000) + "s ago";
    if (d < 90 * 60e3) return Math.round(d / 60e3) + " min ago";
    if (d < 47 * 3600e3) return (d / 3600e3).toFixed(d < 10 * 3600e3 ? 1 : 0) + " h ago";
    return Math.round(d / 86400e3) + " d ago";
  }
  const olderThan = (iso, ms) => {
    const at = parseTime(iso);
    return Number.isFinite(at) && asOfMs() - at > ms;
  };
  const clock = (ms) => TIME_FMT.format(new Date(ms));
  const fmtBytes = (b) => {
    if (!b) return "0";
    const u = ["B", "KiB", "MiB", "GiB", "TiB"];
    let i = 0, v = b;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (v >= 10 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + u[i];
  };
  const pct = (used, total) => (total ? (used * 100 / total).toFixed(0) + "%" : "");
  function uptime(sec) {
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return `${m}m`;
  }

  let regions = null;
  try { regions = new Intl.DisplayNames([navigator.language || "en"], { type: "region" }); } catch { /* older engine */ }
  function country(iso) {
    if (!iso || !/^[A-Za-z]{2}$/.test(iso)) return "";
    let name = iso;
    try { name = regions ? regions.of(iso.toUpperCase()) : iso; } catch { name = iso; }
    const flag = String.fromCodePoint(...[...iso.toUpperCase()].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65));
    return flag + " " + name;
  }

  // ---- selection + drilldown ------------------------------------------
  const STATE_PILL = { online: "pill-reachable", down: "pill-unreachable", sleeping: "pill-sleeping", "no-endpoint": "pill-none" };
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

  // smartFlags mirrors the server's single drive rule: standby is not a
  // fault, every other counter is worth a look. Missing SMART is unknown,
  // never healthy.
  function smartFlags(d) {
    if (d.standby) return { state: "standby", flags: [] };
    const flags = [];
    if (!d.healthy) flags.push("SMART says unhealthy");
    if (d.pendingSectors > 0) flags.push(d.pendingSectors + " pending sectors");
    if (d.uncorrectableErrors > 0) flags.push(d.uncorrectableErrors + " uncorrectable");
    if (d.mediaErrors > 0) flags.push(d.mediaErrors + " media errors");
    if (d.reallocatedSectors > 0) flags.push(d.reallocatedSectors + " reallocated");
    if (d.wearPercentUsed >= 100) flags.push("worn (" + d.wearPercentUsed + "% used)");
    return { state: flags.length ? "bad" : "ok", flags };
  }
  function fsProblems(fs) {
    const b = fs.bcachefs;
    if (!b) return [];
    const out = [];
    if (b.degraded) out.push("degraded");
    const io = (b.devices || []).reduce((a, d) => a + (d.ioErrorsRead || 0) + (d.ioErrorsWrite || 0) + (d.ioErrorsCsum || 0), 0);
    if (io > 0) out.push(io + " IO errors");
    return out;
  }
  const dur = (sec) => {
    if (!sec || sec < 0) return "";
    if (sec < 120) return Math.round(sec) + "s";
    if (sec < 7200) return Math.round(sec / 60) + "m";
    if (sec < 172800) return (sec / 3600).toFixed(1) + "h";
    return Math.round(sec / 86400) + "d";
  };

  // capped renders every item the host reported: the first few eagerly and
  // the rest behind a button that says how many are left. Records are never
  // silently dropped.
  function capped(parent, cls, items, limit, render) {
    const ul = el("ul", { class: cls });
    items.slice(0, limit).forEach((it) => ul.append(render(it)));
    if (items.length > limit) {
      const rest = items.slice(limit);
      const btn = el("button", { type: "button", class: "topo-more" },
        `Show all ${items.length} (${rest.length} more)`);
      btn.addEventListener("click", () => {
        for (const it of rest) ul.append(render(it));
        btn.remove();
        moreRow.remove();
      });
      const moreRow = el("li", { class: "topo-more-row" }, btn);
      ul.append(moreRow);
    }
    parent.append(ul);
    return ul;
  }

  // A preview is the same geometry a moving dot follows, drawn once and left
  // in place so a service's path can be read with traffic switched off.
  let preview = null;
  function clearPreview() {
    if (preview) preview.remove();
    preview = null;
  }
  function previewRoute(hostId, name) {
    clearPreview();
    const svc = serviceOf(meta[hostId], name);
    if (!svc) return "this service is not declared any more.";
    if (!overlay) return "the map is not drawn yet.";
    const audience = svc.public || svc.viaRouter ? "public" : svc.exposure === "local" ? "" : "tailnet";
    if (!audience) return `${name} is reachable only from its own host: there is no path to draw.`;
    const route = routeFor({ host: hostId, service: name, audience });
    if (!route) return "No route can be drawn: the host is not placed, or the hub it needs is missing from the map.";
    preview = journeyPath("journey preview j-" + route.audience, polyD(route.pts), route.audience, 1.5);
    overlay.append(preview);
    return "";
  }

  function renderPanel() {
    const info = meta[selected];
    panel.hidden = !info;
    panel.replaceChildren();
    clearPreview();
    if (!info) return;
    const hostId = selected;

    const head = el("div", { class: "topo-info-head" }, el("h2", {}, info.label));
    if (info.state && info.state !== "static") {
      head.append(el("span", { class: "pill " + (STATE_PILL[info.state] || "pill-none") },
        info.state === "no-endpoint" ? "not polled" : info.state));
    }
    const close = el("button", { type: "button", class: "topo-close", title: "Close (Esc)" }, "×");
    close.addEventListener("click", () => select(""));
    head.append(close);
    panel.append(head);

    const sub = [info.kind, info.role && info.role !== info.kind ? info.role : ""].filter(Boolean).join(" · ");
    if (sub) panel.append(el("p", { class: "muted topo-info-sub" }, sub));
    if (info.stateText) panel.append(el("p", { class: "topo-info-state" }, info.stateText));
    if (info.lastSeen && !info.live) {
      panel.append(el("p", { class: "muted" },
        "last seen " + age(info.lastSeen) + (info.statusTime ? " · status captured " + info.statusTime : "")));
    }

    const facts = el("dl", { class: "topo-facts" });
    if (info.host) facts.append(el("dt", {}, "host"), el("dd", { class: "mono" }, info.host));
    if (info.overlayIp) facts.append(el("dt", {}, "tailnet"), el("dd", { class: "mono" }, info.overlayIp));
    if (info.lanIp) facts.append(el("dt", {}, "lan"), el("dd", { class: "mono" }, info.lanIp));
    if (info.polledAt && info.live) facts.append(el("dt", {}, "polled"), el("dd", {}, age(info.polledAt)));
    if (info.badges && info.badges.length) facts.append(el("dt", {}, "tags"), el("dd", {}, info.badges.join(" · ")));
    if (facts.childElementCount) panel.append(facts);

    if (info.lines && info.lines.length) {
      panel.append(el("ul", { class: "topo-lines" }, ...info.lines.map((l) => el("li", {}, l))));
    }

    // Three separate ledgers: services not running and disk problems are
    // faults; bans are protective enforcement and only ever a badge.
    const health = el("div", { class: "topo-health" });
    if (info.svcFailed) health.append(el("p", { class: "topo-bad" }, `${info.svcFailed} of ${(info.services || []).length} services not running`));
    if (info.diskWarnings) health.append(el("p", { class: "topo-warn" }, `${info.diskWarnings} disk problem${info.diskWarnings === 1 ? "" : "s"}`));
    if (info.bannedCount) health.append(el("p", { class: "topo-ok" }, `${info.bannedCount} IP${info.bannedCount === 1 ? "" : "s"} banned (enforcement)`));
    if (health.childElementCount) panel.append(health);

    const services = info.services || [];
    if (services.length) {
      panel.append(el("h3", {}, `Services (${services.length})`));
      const status = el("p", { class: "muted topo-route-note" });
      const ul = el("ul", { class: "topo-svcs" });
      for (const s of services) {
        const li = el("li", {},
          el("span", { class: "pill " + (SVC_PILL[s.state] || "pill-unknown") }, s.state || "unknown"),
          " ", el("strong", {}, s.name),
          s.exposure ? el("span", { class: "badge badge-" + s.exposure }, s.exposure) : null);
        if (s.public) li.append(el("span", { class: "badge badge-public" }, "via edge"));
        else if (s.viaRouter) li.append(el("span", { class: "badge badge-lan" }, "via router"));
        const platform = [
          s.proto && s.port ? `${s.proto}:${s.port}` : s.proto,
          info.host,
          s.exposure === "local" ? "host-only" : "",
        ].filter(Boolean);
        if (platform.length) li.append(el("div", { class: "muted topo-platform" }, platform.join(" · ")));
        if (s.description) li.append(el("div", { class: "muted" }, s.description));
        for (const u of s.urls || []) {
          if (/^https?:\/\//.test(u)) li.append(el("div", {}, el("a", { href: u, target: "_blank", rel: "noopener" }, u.replace(/^https?:\/\//, ""))));
        }
        const show = el("button", { type: "button", class: "topo-route-btn" }, "Show route");
        show.addEventListener("click", () => {
          const msg = previewRoute(hostId, s.name);
          status.textContent = msg ||
            `${s.name}: drawn from ${s.public || s.viaRouter ? "the internet" : "the overlay"} to ${info.label}.`;
        });
        li.append(el("div", { class: "topo-svc-actions" }, show));
        ul.append(li);
      }
      panel.append(ul, status);
    }

    const smart = info.smart || [];
    if (smart.length) {
      panel.append(el("h3", {}, `Drives (${info.smartOk || 0} ok · ${info.smartFailed || 0} to check)`));
      const ul = el("ul", { class: "topo-drives" });
      for (const d of smart) {
        const { standby, flags } = smartFlags(d);
        const li = el("li", { class: flags.length ? "topo-warn" : standby ? "muted" : "" });
        li.append(el("strong", {}, [d.device, d.model].filter(Boolean).join(" · ") || "drive"));
        const bits = [];
        if (standby) bits.push("standby / asleep");
        if (d.tempC) bits.push(d.tempC + "°C");
        if (d.powerOnHours) bits.push(Math.round(d.powerOnHours / 24) + "d powered");
        if (d.serial) bits.push(d.serial);
        if (bits.length) li.append(el("div", { class: "muted" }, bits.join(" · ")));
        if (flags.length) li.append(el("div", {}, flags.join(" · ")));
        if (d.updatedAt) {
          const old = olderThan(d.updatedAt, 30 * 60e3);
          li.append(el("div", { class: "topo-age" + (old ? " old" : "") },
            "SMART read " + age(d.updatedAt) + (old ? " — stale (15 min cadence)" : "")));
        }
        ul.append(li);
      }
      panel.append(ul);
    }

    const filesystems = info.filesystems || [];
    if (filesystems.length) {
      panel.append(el("h3", {}, "Filesystems"));
      const ul = el("ul", { class: "topo-fs" });
      for (const fs of filesystems) {
        const probs = fsProblems(fs);
        const li = el("li", { class: probs.length ? "topo-warn" : "" });
        li.append(el("strong", {}, fs.mount || fs.device || "mount"), " ",
          el("span", { class: "muted" }, [fs.fstype, pct(fs.usedBytes, fs.totalBytes)].filter(Boolean).join(" · ")));
        if (probs.length) li.append(el("div", {}, probs.join(" · ")));
        if (fs.bcachefs && fs.bcachefs.uuid) li.append(el("div", { class: "topo-age" }, "pool " + fs.bcachefs.uuid));
        ul.append(li);
      }
      panel.append(ul);
    }
    // Bans are protective enforcement, not a fault: they are listed in full
    // here and badged on the station, never counted as a problem.
    const fb = info.fail2ban;
    if (fb) {
      panel.append(el("h3", {}, "Bans (enforcement)"));
      if (fb.updatedAt) {
        const old = olderThan(fb.updatedAt, 2 * 60e3);
        panel.append(el("p", { class: "topo-age" + (old ? " old" : "") },
          "fail2ban read " + age(fb.updatedAt) + (old ? " — stale (1 min cadence)" : "")));
      }
      const jails = fb.jails || [];
      if (jails.length) {
        const ul = el("ul", { class: "topo-jails" });
        for (const j of jails) {
          const li = el("li", {}, el("strong", {}, j.name),
            el("span", { class: "muted" }, ` · ${j.currentlyBanned || 0} now · ${j.totalBanned || 0} total`));
          const ips = j.bannedIPs || [];
          if (ips.length) {
            li.append(el("div", { class: "mono topo-ips" }, ips.map((ip) => {
              const c = country(frameCountries[ip]);
              return c ? `${ip} ${c}` : ip;
            }).join(" · ")));
          }
          ul.append(li);
        }
        panel.append(ul);
      } else {
        panel.append(el("p", { class: "muted" }, "no jails reporting"));
      }
      const bans = fb.recentBans || [];
      if (bans.length) {
        capped(panel, "topo-bans", bans, 8, (b) => {
          const c = country(frameCountries[b.ip]);
          return el("li", {},
            el("span", { class: "pill " + (b.active ? "pill-inactive" : "pill-none") }, b.active ? "banned" : "expired"),
            " ", el("span", { class: "mono" }, b.ip),
            c ? el("span", { class: "muted" }, " " + c) : null,
            el("span", { class: "muted" }, ` · ${b.jail}${b.failures ? " · " + b.failures + " failures" : ""}`),
            b.bannedAt ? el("span", { class: "topo-age" }, " · " + clock(parseTime(b.bannedAt))) : null,
            b.banSeconds ? el("span", { class: "muted" }, ` for ${Math.round(b.banSeconds / 60)} min`) : null);
        });
      }
    }

    if (info.system) {
      const s = info.system;
      const facts2 = el("dl", { class: "topo-facts" });
      facts2.append(el("dt", {}, "cpu"), el("dd", {}, s.cpuPercent != null ? s.cpuPercent.toFixed(0) + "%" : "—"));
      if (s.memTotalBytes) facts2.append(el("dt", {}, "memory"), el("dd", {}, `${fmtBytes(s.memUsedBytes)} / ${fmtBytes(s.memTotalBytes)}`));
      if (s.uptimeSec) facts2.append(el("dt", {}, "uptime"), el("dd", {}, uptime(s.uptimeSec)));
      panel.append(el("h3", {}, "System"), facts2);
    } else if (info.host && !info.live) {
      panel.append(el("p", { class: "muted topo-age" }, "system metrics are last known only; the host is not answering"));
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
    if (info.href && (/^https?:\/\//i.test(info.href) || /^\/(?![\\/])/.test(info.href))) {
      panel.append(el("p", {}, el("a", { href: info.href }, info.host ? `Open ${info.host} details →` : "Open →")));
    }
  }

  // ---- traffic animation ----------------------------------------------
  // Dots travel along anchors the server already declared. A public request
  // enters through the edge hub, or the router when that is where it lands; a
  // tailnet request starts at the overlay origin. Local-only services and
  // unplaced hosts have no anchors, so they never get a trace.
  const seen = new Set();
  const dots = [];
  let rafId = 0;

  function nodePoint(id) {
    const info = meta[id];
    return info ? { x: info.x, y: info.y } : null;
  }
  function originFor(kind) {
    const x = kind === "tailnet" ? Math.max(140, dims.w - 140) : 110;
    const y = 34;
    if (!overlay) return { x, y };
    const key = "origin-" + kind;
    if (!overlay.querySelector("#" + key)) {
      const marker = sEl("g", { class: "origin", id: key });
      marker.append(sEl("rect", { x: x - 74, y: y - 16, width: 148, height: 32, rx: 16 }));
      const text = sEl("text", { x, y: y + 4, "text-anchor": "middle" });
      text.textContent = kind === "tailnet" ? "simulated overlay client" : "simulated internet client";
      marker.append(text);
      overlay.append(marker);
    }
    return { x, y };
  }
  function serviceOf(info, name) {
    if (!info || !name) return null;
    return (info.services || []).find((s) => s.name === name) || null;
  }
  // link appends an elbowed run between two anchors: one stub out of each and
  // a single elbow, matching the drawn cabling.
  function link(a, b, out) {
    const pts = [];
    const stubA = 18, stubB = 18;
    const dx = b.x - a.x, dy = b.y - a.y;
    const horizontal = Math.abs(dx) >= Math.abs(dy);
    const sa = horizontal
      ? { x: a.x + Math.sign(dx || 1) * stubA, y: a.y }
      : { x: a.x, y: a.y + Math.sign(dy || 1) * stubA };
    const sb = horizontal
      ? { x: b.x - Math.sign(dx || 1) * stubB, y: b.y }
      : { x: b.x, y: b.y - Math.sign(dy || 1) * stubB };
    if (out.length) pts.push({ x: a.x, y: a.y });
    pts.push(sa);
    if (horizontal) {
      const mx = (sa.x + sb.x) / 2;
      pts.push({ x: mx, y: sa.y }, { x: mx, y: sb.y });
    } else {
      const my = (sa.y + sb.y) / 2;
      pts.push({ x: sa.x, y: my }, { x: sb.x, y: my });
    }
    pts.push(sb, { x: b.x, y: b.y });
    out.push(...pts);
    return out;
  }
  function routeFor(ev) {
    if (!ev || !ev.host) return null;
    const hostId = byHost.get(ev.host) || byHost.get(ev.to && ev.to.id);
    const hostPt = hostId && nodePoint(hostId);
    if (!hostPt) return null;                       // unplaced host: nothing to draw
    const svc = serviceOf(meta[hostId], ev.service);
    if (!svc) return null;                          // not a declared service here
    const pts = [];
    if (ev.audience === "public") {
      if (svc.viaRouter) {
        const hubPt = hubs.router && nodePoint(hubs.router);
        if (!hubPt) return null;                    // no router hub: never a fake route
        link(originFor("internet"), hubPt, pts);
      } else if (svc.public) {
        const hubPt = hubs.edge && nodePoint(hubs.edge);
        if (!hubPt) return null;
        link(originFor("internet"), hubPt, pts);
      } else {
        return null;
      }
      const last = pts[pts.length - 1];
      link(last, hostPt, pts);
      return { pts, audience: "public" };
    }
    if (ev.audience === "tailnet") {
      if (svc.exposure === "local") return null;    // local-only: no tailnet path
      link(originFor("tailnet"), hostPt, pts);
      return { pts, audience: "tailnet" };
    }
    return null;
  }

  const polyD = (pts) => pts.map((p, i) => (i ? "L" : "M") + p.x.toFixed(0) + " " + p.y.toFixed(0)).join(" ");

  // Journey paths are created as the .journey element itself, so a
  // ".journey path" stylesheet rule never matches them and SVG's default
  // black fill would flood the map. Carry the presentation in attributes,
  // resolved from the same custom properties the stylesheet uses.
  function themeVar(name, fallback) {
    const v = getComputedStyle(svg).getPropertyValue(name).trim();
    return v || fallback;
  }
  function journeyPath(cls, d, audience, width) {
    return sEl("path", {
      class: cls,
      d,
      fill: "none",
      stroke: themeVar(audience === "tailnet" ? "--t-purple" : "--t-amber", audience === "tailnet" ? "#8a7ec8" : "#d7a24a"),
      "stroke-width": width,
      "stroke-linejoin": "round",
      "stroke-linecap": "round",
      opacity: "0.9",
    });
  }

  function spawn(ev) {
    if (!overlay || dots.length >= MAX_DOTS) return;
    const route = routeFor(ev);
    if (!route) return;
    // Style follows the event, not the mode: a real provider's events look
    // different from simulated ones even though they use the same primitives.
    const kind = ev.simulated === false ? "real" : "sim";
    const path = journeyPath(`journey j-${route.audience} ${kind}`, polyD(route.pts), route.audience, 2);
    const seg = [];
    let total = 0;
    for (let i = 1; i < route.pts.length; i++) {
      const a = route.pts[i - 1], b = route.pts[i];
      const len = Math.hypot(b.x - a.x, b.y - a.y);
      if (len > 0) seg.push({ a, b, len });
      total += len;
    }
    if (total < 1) return;
    const dot = sEl("circle", {
      class: `ev-dot aud-${route.audience} ${kind}`,
      cx: route.pts[0].x, cy: route.pts[0].y, r: 3.2,
    });
    const tip = sEl("title");
    tip.textContent = [
      kind === "real" ? "measured" : "simulated",
      ev.service || "", ev.proto, ev.status,
      ev.ms ? ev.ms + "ms" : "", ev.bytes ? fmtBytes(ev.bytes) : "",
    ].filter(Boolean).join(" · ");
    dot.append(tip);
    overlay.append(path, dot);
    const dur = Math.min(2400, Math.max(700, total * 2.5));
    const item = { dot, path, seg, total, dur, progress: 0, fading: false, fadeLeft: 0, out: false };
    dots.push(item);
    if (reduced) {
      // No travelling dot: park the marker at the destination and fade it.
      const end = route.pts[route.pts.length - 1];
      dot.setAttribute("cx", end.x);
      dot.setAttribute("cy", end.y);
      item.fading = true;
      item.fadeLeft = 900;
    }
    if (!rafId) rafId = requestAnimationFrame(tick);
  }

  function pointAt(item, dist) {
    let left = dist;
    for (const s of item.seg) {
      if (left <= s.len) {
        const f = left / s.len;
        return { x: s.a.x + (s.b.x - s.a.x) * f, y: s.a.y + (s.b.y - s.a.y) * f };
      }
      left -= s.len;
    }
    const last = item.seg[item.seg.length - 1];
    return last ? last.b : { x: 0, y: 0 };
  }

  // One clock moves the dots and expires them, and it only runs while the map
  // is showing traffic: live, or a replay that is playing. Pausing therefore
  // freezes both travel and fade where they are, instead of letting timers
  // finish a dot behind a cursor that has stopped.
  const dotsRunning = () => document.visibilityState === "visible" && (cursor == null || playing);
  let lastTick = 0;
  function tick(now) {
    rafId = 0;
    if (!dotsRunning()) { lastTick = 0; return; }
    const dt = lastTick ? Math.min(100, now - lastTick) : 16;
    lastTick = now;
    let more = false;
    for (const item of dots.slice()) {
      if (item.out) continue;
      if (item.fading) {
        item.fadeLeft -= dt;
        if (item.fadeLeft <= 0) finish(item);
        else more = true;
        continue;
      }
      item.progress += dt;
      const f = Math.min(1, item.progress / item.dur);
      const p = pointAt(item, item.total * f);
      item.dot.setAttribute("cx", p.x.toFixed(1));
      item.dot.setAttribute("cy", p.y.toFixed(1));
      if (f >= 1) {
        item.fading = true;
        item.fadeLeft = 400;
        item.path.style.opacity = "0";
      }
      more = true;
    }
    if (more) rafId = requestAnimationFrame(tick);
    else lastTick = 0;
  }
  function finish(item) {
    if (item.out) return;
    item.out = true;
    const i = dots.indexOf(item);
    if (i >= 0) dots.splice(i, 1);
    item.dot.remove();
    item.path.remove();
  }

  function clearTraffic() {
    for (const item of dots.slice()) finish(item);
    seen.clear();
    pending.length = 0;
    clearPreview();
    if (overlay) overlay.querySelectorAll(".origin").forEach((o) => o.remove());
    epoch = "";
  }

  // consume takes the events the provider reported for the window now on
  // screen. It never infers mode from the events: whenever a provider reports
  // traffic the events animate, and each event carries its own origin style.
  // During playback they are queued and released as the clock reaches them, so
  // a replay paces traffic instead of dumping a window at once.
  function consume(traffic, windowEndMs) {
    if (!traffic || suppressTraffic) return;
    const next = traffic.epoch || "";
    if (next && next !== epoch) {
      for (const item of dots.slice()) finish(item);
      pending.length = 0;
      epoch = next;
    }
    const end = Number.isFinite(windowEndMs) ? windowEndMs : Infinity;
    for (const ev of Array.isArray(traffic.events) ? traffic.events : []) {
      if (!ev || !ev.id || seen.has(ev.id)) continue;
      seen.add(ev.id);
      // A replay (playing or paused) only queues: nothing spawns behind a
      // clock that is not moving.
      if (cursor != null) pending.push(ev);
      else if (parseTime(ev.at) <= end) spawn(ev);
      if (seen.size > MAX_SEEN) seen.clear();
    }
    if (cursor != null) pending.sort((a, b) => parseTime(a.at) - parseTime(b.at));
  }

  // release moves queued events whose moment the replay clock has reached.
  function release(nowMs) {
    while (pending.length && parseTime(pending[0].at) <= nowMs) spawn(pending.shift());
  }
  // ---- frame application ----------------------------------------------
  function applySvg(text) {
    const doc = new DOMParser().parseFromString(text, "image/svg+xml");
    if (doc.querySelector("parsererror")) throw new Error("bad svg");
    const root = doc.getElementById("topo-root");
    const liveRoot = svg.querySelector("#topo-root");
    if (!root || !liveRoot) throw new Error("no root");
    const imported = document.importNode(root, true);
    liveRoot.replaceWith(imported);
    const vb = doc.documentElement.getAttribute("viewBox");
    if (vb) svg.setAttribute("viewBox", vb);
    meta = parseMeta(imported);
    byHost = new Map();
    for (const [id, info] of Object.entries(meta)) {
      if (info && info.host) byHost.set(info.host, id);
    }
    hubs = {
      tailnet: imported.getAttribute("data-hub-tailnet") || "",
      edge: imported.getAttribute("data-hub-edge") || "",
      router: imported.getAttribute("data-hub-router") || "",
      dashboard: imported.getAttribute("data-hub-dashboard") || "",
    };
    dims = {
      w: Number(imported.getAttribute("data-width")) || 0,
      h: Number(imported.getAttribute("data-height")) || 0,
    };
    ensureOverlay();
    layerBoxes.forEach((cb) => svg.classList.toggle("hide-" + cb.dataset.layer, !cb.checked));
    if (selected && !meta[selected]) selected = "";
    highlight();
    renderPanel();
    summarize();
    if (autoView) initialView();
    else if (!restoreChecked) { restoreChecked = true; ensureLegible(); }
  }

  function ensureOverlay() {
    const vp = viewport();
    if (!vp) return;
    overlay = vp.querySelector("#topo-overlay");
    if (!overlay) {
      overlay = sEl("g", { id: "topo-overlay" });
      vp.append(overlay);
    }
  }

  function summarize() {
    let online = 0, sleeping = 0, down = 0, unpolled = 0;
    for (const n of Object.values(meta)) {
      if (n.state === "online") online++;
      else if (n.state === "sleeping") sleeping++;
      else if (n.state === "down") down++;
      else if (n.state !== "static") unpolled++;
    }
    const strong = (v, cls) => el("strong", cls ? { class: cls } : {}, String(v));
    const parts = [strong(online), online === 1 ? " machine available" : " machines available"];
    if (sleeping) parts.push(" · ", strong(sleeping), " sleeping");
    if (down) parts.push(" · ", strong(down, "warn"), down === 1 ? " needs attention" : " need attention");
    parts.push(el("span", { class: "muted", id: "topo-updated" },
      cursor == null ? " · live" : " · replay " + clock(cursor)));
    summaryEl.replaceChildren(...parts);

    const unpolledEl = document.getElementById("topo-unpolled");
    if (unpolledEl) unpolledEl.textContent = String(unpolled);

    const problems = [];
    for (const n of Object.values(meta)) {
      if (n.state === "down") problems.push(`${n.label}: not answering${n.lastSeenAge ? " (last seen " + n.lastSeenAge + " ago)" : ""}`);
      if (n.svcFailed) problems.push(`${n.label}: ${n.svcFailed} service${n.svcFailed === 1 ? "" : "s"} not running`);
      if (n.diskWarnings) problems.push(`${n.label}: ${n.diskWarnings} disk problem${n.diskWarnings === 1 ? "" : "s"}`);
    }
    problemsEl.hidden = problems.length === 0;
    problemsEl.replaceChildren(...problems.map((p) => el("span", { class: "topo-problem" }, p)));
  }

  // ---- timeline --------------------------------------------------------
  const samples = () => (timeline && Array.isArray(timeline.samples) ? timeline.samples : []);
  function nearestSample(ms) {
    let best = null, bestDelta = Infinity;
    for (const s of samples()) {
      const at = parseTime(s.at);
      if (!Number.isFinite(at)) continue;
      const d = Math.abs(at - ms);
      if (d < bestDelta) { best = s; bestDelta = d; }
    }
    return best;
  }
  function windowBounds() {
    if (!timeline) return null;
    const start = parseTime(timeline.start) || parseTime(timeline.coverageStart);
    const end = parseTime(timeline.end) || parseTime(timeline.coverageEnd);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null;
    return { start, end };
  }

  // paintStrip is the visual history: one bar per slice of the window, at the
  // worst finding recorded in it, so a bad minute stays visible instead of
  // collapsing into a hairline. Slices without a snapshot are left empty, so
  // a recording gap never reads as healthy time.
  let stripKey = "";
  let stripCursor = null;
  function paintStrip() {
    const strip = document.getElementById("topo-strip");
    if (!strip) return;
    const bounds = windowBounds();
    if (!bounds) {
      stripKey = "";
      stripCursor = null;
      strip.hidden = true;
      strip.replaceChildren();
      return;
    }
    strip.hidden = false;
    const count = samples().length;
    const gaps = (timeline.gaps || []).length;
    const width = strip.clientWidth || 320;
    const bars = Math.max(48, Math.min(480, Math.round(width / 2)));
    const key = [count, bounds.start, bounds.end, gaps, bars].join("|");
    if (key !== stripKey) {
      stripKey = key;
      strip.replaceChildren();
      const span = bounds.end - bounds.start;
      // 0 unknown, 1 ok, 2 only sleeping, 3 disk warning, 4 host down.
      const worst = new Uint8Array(bars);
      for (const s of samples()) {
        const at = parseTime(s.at);
        if (!Number.isFinite(at)) continue;
        const i = Math.min(bars - 1, Math.max(0, Math.floor((at - bounds.start) / span * bars)));
        const level = s.down > 0 ? 4 : s.driveWarnings > 0 ? 3 : s.online === 0 && s.sleeping > 0 ? 2 : 1;
        if (level > worst[i]) worst[i] = level;
      }
      for (const gap of timeline.gaps || []) {
        const gs = parseTime(gap.start), ge = parseTime(gap.end);
        if (!Number.isFinite(gs) || !Number.isFinite(ge)) continue;
        const from = Math.max(0, Math.floor((gs - bounds.start) / span * bars));
        const to = Math.min(bars, Math.ceil((ge - bounds.start) / span * bars));
        for (let i = from; i < to; i++) worst[i] = 0;
      }
      const names = ["", "ok", "quiet", "warn", "bad"];
      const frag = document.createDocumentFragment();
      // Runs of equal level become one bar, so the strip stays a few nodes.
      for (let i = 0; i < bars;) {
        let j = i;
        while (j < bars && worst[j] === worst[i]) j++;
        if (worst[i]) {
          const seg = el("span", { class: "seg " + names[worst[i]] });
          seg.style.left = (i / bars * 100).toFixed(3) + "%";
          seg.style.width = ((j - i) / bars * 100).toFixed(3) + "%";
          frag.append(seg);
        }
        i = j;
      }
      strip.append(frag);

      stripCursor = el("span", { class: "cursor" });
      strip.append(stripCursor);
    }
    if (stripCursor) {
      const ms = cursor == null ? asOfMs() : cursor;
      const inside = Number.isFinite(ms) && ms >= bounds.start && ms <= bounds.end;
      stripCursor.hidden = !inside;
      if (inside) stripCursor.style.left = ((ms - bounds.start) / (bounds.end - bounds.start) * 100).toFixed(3) + "%";
    }
  }
  // The label describes the health actually drawn: it stays on the applied
  // frame while a scrubbed request is in flight, then jumps when the response
  // lands. The slider thumb follows the target the user picked.
  function paintTime() {
    const bounds = windowBounds();
    if (!bounds) {
      timeEl.disabled = true;
      playBtn.disabled = true;
      timeLabel.textContent = "No recorded history";
      paintStrip();
      return;
    }
    timeEl.disabled = false;
    playBtn.disabled = false;
    const applied = appliedMs();
    const shown = cursor == null ? applied : Number.isFinite(applied) ? applied : cursor;
    if (cursor == null) {
      timeEl.value = String(timeEl.max);
    } else {
      const frac = Math.min(1, Math.max(0, (cursor - bounds.start) / (bounds.end - bounds.start)));
      timeEl.value = String(Math.round(frac * Number(timeEl.max)));
    }
    if (cursor != null) {
      timeLabel.textContent = "Replay " + (Number.isFinite(shown) ? clock(shown) : "—");
    } else {
      timeLabel.textContent = "Live";
    }
    if (timeMeta) {
      const sample = Number.isFinite(shown) && shown >= bounds.start && shown <= bounds.end ? nearestSample(shown) : null;
      timeMeta.textContent = sample
        ? `${clock(parseTime(sample.at))} · ${sample.online} up · ${sample.driveWarnings} disk · ${sample.bannedCount} banned`
        : "";
    }
    playBtn.textContent = playing ? "❚❚" : "▶";
    playBtn.setAttribute("aria-pressed", playing ? "true" : "false");
    paintStrip();
  }

  // ---- playback --------------------------------------------------------
  // One rAF loop owns the clock. A replay asks for the frame *at the cursor*
  // with trafficWindow=full, so the server returns every event of the snapshot
  // window that covers that instant, clipped to the present. Those events are
  // queued and released only when the clock reaches each one, so a window
  // plays out across its own seconds instead of arriving as one burst. The
  // next request is decided by the window the server actually returned, never
  // by a wall-clock bucket.
  let playRaf = 0;
  let lastPlayAt = 0;
  let playWindowEnd = NaN;

  function startPlay() {
    const bounds = windowBounds();
    if (!bounds) return;
    // Resuming keeps the queued events and the window the last frame covered:
    // a pause is not a seek. Only a start from the live view is a fresh
    // replay, and that one discards whatever traffic was on the map.
    if (cursor == null) {
      clearTraffic();
      cursor = bounds.start;
      playWindowEnd = NaN;
    }
    playing = true;
    suppressTraffic = false;
    lastPlayAt = 0;
    paintTime();
    if (!Number.isFinite(playWindowEnd)) requestFrame(cursor, "play", true);
    if (!playRaf) playRaf = requestAnimationFrame(playTick);
    if (!rafId) rafId = requestAnimationFrame(tick);
  }
  function stopPlay() {
    playing = false;
    if (playRaf) cancelAnimationFrame(playRaf);
    playRaf = 0;
    lastPlayAt = 0;
    // Dots freeze where they are: the dot clock refuses to advance while a
    // replay is paused, and startPlay starts it again.
    if (rafId) cancelAnimationFrame(rafId);
    rafId = 0;
    lastTick = 0;
    paintTime();
  }
  function playTick(now) {
    playRaf = 0;
    if (!playing) return;
    if (document.visibilityState !== "visible") return;
    const bounds = windowBounds();
    if (!bounds) { stopPlay(); return; }
    const dt = lastPlayAt ? Math.min(1000, now - lastPlayAt) : 16;
    lastPlayAt = now;
    cursor = Math.min(bounds.end, (cursor == null ? bounds.start : cursor) + dt * playSpeed);
    if (cursor >= bounds.end) {
      stopPlay();
      goLive();
      return;
    }
    // A window without a snapshot (a gap) never sets an end, so the next
    // covered instant is tried on the following tick.
    if (!Number.isFinite(playWindowEnd) || cursor >= playWindowEnd) {
      requestFrame(cursor, "play", true);
    }
    release(cursor);
    paintTime();
    playRaf = requestAnimationFrame(playTick);
  }

  let scrubTimer = 0;
  function seek(ms) {
    stopPlay();
    cursor = ms;
    suppressTraffic = true; // paused replay shows recorded health, not new dots
    // The old frame covered another instant, so playing from here asks again.
    playWindowEnd = NaN;
    clearTraffic();
    paintTime();
    clearTimeout(scrubTimer);
    scrubTimer = setTimeout(() => requestFrame(cursor, "seek"), 120);
  }
  timeEl.addEventListener("input", () => {
    const bounds = windowBounds();
    if (!bounds) return;
    const frac = Number(timeEl.value) / Number(timeEl.max);
    seek(bounds.start + (bounds.end - bounds.start) * frac);
  });
  timeEl.addEventListener("change", () => {
    clearTimeout(scrubTimer);
    if (cursor != null) requestFrame(cursor, "seek");
  });
  playBtn.addEventListener("click", () => (playing ? stopPlay() : startPlay()));
  speedEl.addEventListener("change", () => { playSpeed = Number(speedEl.value) || 64; });
  liveBtn.addEventListener("click", goLive);

  function goLive() {
    stopPlay();
    cursor = null;
    suppressTraffic = false;
    playWindowEnd = NaN;
    clearTraffic();
    paintTime();
    requestFrame(NaN, "live");
  }

  // ---- fetching --------------------------------------------------------
  // Every request carries a generation; a newer request aborts and silences
  // the older one, so a slow response can never overwrite a fresher mode,
  // cursor or live switch.
  let gen = 0;
  let inflight = null;

  const url = (path, params) => {
    const u = new URL(path, location.origin);
    for (const [k, v] of Object.entries(params || {})) {
      if (v != null && v !== "") u.searchParams.set(k, String(v));
    }
    return u.toString();
  };

  async function getJSON(href, signal) {
    const res = await fetch(href, { credentials: "same-origin", cache: "no-store", signal, headers: { accept: "application/json" } });
    let body = null;
    try { body = await res.json(); } catch { body = null; }
    if (!res.ok) {
      const err = new Error((body && (body.error || body.code)) || `HTTP ${res.status}`);
      err.status = res.status;
      err.body = body;
      throw err;
    }
    return body || {};
  }

  async function requestFrame(ms, reason, full) {
    // The replay clock ticks many times per second but a frame may take
    // hundreds of milliseconds to arrive. A play request never aborts the
    // frame already on the wire, or nothing would ever land; the window it
    // returns decides when the next play request is due. Seek, live and a
    // mode switch are explicit intents and still supersede what is running.
    if (reason === "play" && inflight) return;
    const mine = ++gen;
    if (inflight) inflight.abort();
    const ctl = new AbortController();
    inflight = ctl;
    const at = Number.isFinite(ms) ? new Date(ms).toISOString() : "";
    const q = { mode };
    if (at) q.at = at;
    // Full asks for the whole snapshot window rather than the prefix up to
    // the cursor. Only a replay may ask; a live window is still running.
    if (full && at) q.trafficWindow = "full";
    try {
      const body = await getJSON(url("/api/topology/frame", q), ctl.signal);
      if (mine !== gen) return;                  // superseded: drop it
      inflight = null;
      // A play frame that lands after the pause is stale by definition: the
      // replay is frozen, so it must not move the map, the label or the dots.
      if (reason === "play" && !playing) return;
      lastSnapshot = body.snapshotAt || "";
      // Only a play frame says how far the replay cursor is fed; any other
      // frame leaves the next play request to ask at the cursor.
      playWindowEnd = reason === "play" ? windowEndOf(body) : NaN;
      frame = body;
      showGeoip(body.geoip);
      frameCountries = body.countries || {};
      applySvg(body.svg || "");
      applyTraffic(body.traffic, body.at, reason);
      timeNote.classList.remove("old");
      timeNote.textContent = describeFreshness(body);
      paintTime();
    } catch (err) {
      if (err && err.name === "AbortError") return;
      if (mine !== gen) return;
      inflight = null;
      handleFetchError(err);
    }
  }

  // windowEndOf is the instant after which the frame's traffic no longer
  // covers the cursor: the traffic window's end, else the snapshot window.
  function windowEndOf(body) {
    const snap = parseTime(body && body.snapshotAt);
    const end = parseTime(body && body.traffic && body.traffic.window && body.traffic.window.end);
    if (Number.isFinite(end)) return end;
    return Number.isFinite(snap) ? snap + MAX_STEP_MS : NaN;
  }

  function describeFreshness(body) {
    if (!body) return "";
    if (body.live) {
      return `Live · newest recorded snapshot ${body.snapshotAt ? clock(parseTime(body.snapshotAt)) : "unknown"}.`;
    }
    const age = Math.round(body.snapshotAgeSeconds || 0);
    return `Recorded ${clock(parseTime(body.snapshotAt))} · ${age}s into that 30s window.`;
  }

  let pollGen = 0;
  async function pollTraffic() {
    // Only the live view polls: a replay, playing or paused, is answered by
    // the frame request for its cursor.
    if (document.visibilityState !== "visible" || suppressTraffic || playing || cursor != null) return;
    const mine = ++pollGen;
    const q = { mode };
    const ctl = new AbortController();
    try {
      const body = await getJSON(url("/api/topology/traffic", q), ctl.signal);
      if (mine !== pollGen) return;              // a newer poll or mode change won
      if (body.snapshotAt && lastSnapshot && body.snapshotAt !== lastSnapshot) {
        requestFrame(cursor == null ? NaN : cursor, cursor == null ? "live" : "seek");
        return;
      }
      frameCountries = body.countries || {};
      applyTraffic(body.traffic, body.at, "poll");
      failures = 0;
    } catch (err) {
      if (err && err.name === "AbortError") return;
      if (mine !== pollGen) return;
      handleFetchError(err);
    }
  }

  // setBadge keeps the map honestly labelled at all times: a simulated map
  // says Simulation before the first fetch, during a failed fetch, and in
  // real mode where nothing is simulated it says so instead.
  function setBadge(simulated, why) {
    if (!simBadge) return;
    simBadge.hidden = false;
    simBadge.classList.toggle("is-sim", simulated);
    simBadge.classList.toggle("is-real", !simulated);
    simBadge.textContent = simulated ? "Simulation" : why || "No traffic provider";
    simBadge.title = simulated
      ? "Requests on this map are generated from declared routes, not measured"
      : "No real traffic provider is connected";
  }

  // applyTraffic is provider-agnostic. A provider is either simulated or
  // measured; whenever it reports available traffic the events animate through
  // the same primitives, styled per event. An unavailable provider (real mode
  // today) clears the map and says why — it never falls back to simulation.
  function applyTraffic(traffic, at, reason) {
    if (!traffic) return;
    const simulated = traffic.simulated !== false;
    if (traffic.available !== true) {
      clearTraffic();
      setBadge(false, simulated ? "No traffic" : "No traffic provider");
      if (simNote) {
        const note = [traffic.message, traffic.reason].filter(Boolean).join(" — ");
        simNote.hidden = !note;
        simNote.textContent = note || (simulated ? "No simulated traffic for this window." : "");
      }
      if (modeNote) {
        modeNote.textContent = simulated
          ? "No simulated traffic is available for this window."
          : "Real traffic is not connected. Nothing is simulated in this mode.";
      }
      return;
    }
    setBadge(simulated, "Live traffic");
    if (simNote) {
      simNote.hidden = !traffic.message;
      simNote.textContent = traffic.message || "";
    }
    if (modeNote) {
      modeNote.textContent = simulated
        ? "Requests are generated from the declared routes: no traffic is measured."
        : "Traffic measured by " + (traffic.provider || "the live provider") + ".";
    }
    // A live poll animates as events arrive. A full-window replay frame is
    // queued whole and paced by the replay clock; a plain seek shows no dots.
    if (reason === "play") {
      consume(traffic, Infinity);
      return;
    }
    const endMs = parseTime(at);
    consume(traffic, Number.isFinite(endMs) ? endMs + 1000 : Infinity);
  }

  function showGeoip(geoip) {
    if (geoip === undefined) return;
    if (geoip && geoip.available) {
      attrEl.hidden = false;
      attrNote.textContent = geoip.source ? " · " + geoip.source : "";
    } else {
      attrEl.hidden = true;
    }
  }

  function handleFetchError(err) {
    failures++;
    if (err.status === 404 || err.status === 503) {
      // Out of coverage or recording unavailable: say so. Never substitute
      // the live map for a replay the user asked for.
      stopPlay();
      clearTraffic();
      playWindowEnd = NaN;
      timeNote.textContent = err.status === 404
        ? "No recording covers that moment. The service was not sampling; try another point."
        : "Recording is unavailable right now, so history cannot be replayed.";
      timeNote.classList.add("old");
      return;
    }
    if (failures >= 2) {
      const u = document.getElementById("topo-updated");
      if (u) u.textContent = " · refresh failed (reload to sign in again)";
    }
  }

  // ---- mode ------------------------------------------------------------
  try {
    const saved = localStorage.getItem(MODE_KEY);
    if (saved === "real" || saved === "simulated") mode = saved;
  } catch { /* ignore */ }
  side.querySelectorAll('input[name="topo-mode"]').forEach((r) => {
    r.checked = r.value === mode;
    r.addEventListener("change", () => {
      if (!r.checked) return;
      mode = r.value;
      try { localStorage.setItem(MODE_KEY, mode); } catch { /* ignore */ }
      setBadge(mode === "simulated");
      pollGen++;                                 // drop any in-flight poll
      clearTraffic();
      lastSnapshot = "";
      requestFrame(cursor == null ? NaN : cursor, cursor == null ? "live" : "seek");
    });
  });
  setBadge(mode === "simulated");

  async function loadTimeline() {
    try {
      const body = await getJSON(url("/api/topology/timeline", { hours: 24 }));
      timeline = body;
      const bounds = windowBounds();
      if (bounds && cursor != null) {
        // Keep a replay position that still exists; otherwise fall back to live.
        cursor = cursor < bounds.start ? bounds.start : cursor > bounds.end ? bounds.end : cursor;
      }
      paintTime();
      const note = samples().length
        ? body.persistent
          ? ""
          : "History is in memory only (no database configured): it resets when the service restarts."
        : "No history recorded yet: recording starts with the first poll.";
      if (note && !timeNote.classList.contains("old")) timeNote.textContent = note;
    } catch {
      if (!timeline) {
        timeline = { samples: [] };
        paintTime();
        timeNote.textContent = "History could not be loaded.";
      }
    }
  }

  // ---- boot ------------------------------------------------------------
  apply();
  paintTime();
  selectHash();
  loadTimeline();
  requestFrame(NaN, "live");
  setInterval(() => { if (document.visibilityState === "visible") pollTraffic(); }, TRAFFIC_POLL_MS);
  // The window keeps growing as snapshots are captured; refresh it even when
  // earlier samples exist, without disturbing the cursor.
  setInterval(() => { if (document.visibilityState === "visible") loadTimeline(); }, 30000);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      if (cursor == null) pollTraffic();
      loadTimeline();
      if (playing && !playRaf) { lastPlayAt = 0; playRaf = requestAnimationFrame(playTick); }
      if (!rafId && dots.length) { lastTick = 0; rafId = requestAnimationFrame(tick); }
    } else {
      stopPlay();
    }
  });

  function selectHash() {
    let id = "";
    try { id = decodeURIComponent(location.hash.slice(1)); } catch { /* invalid fragment */ }
    select(id);
  }
  window.addEventListener("hashchange", selectHash);
})();
