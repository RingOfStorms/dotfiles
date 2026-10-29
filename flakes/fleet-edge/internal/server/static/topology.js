// /topology: a route atlas. The server lays out the map and renders it as
// standalone SVG; this script only pans/zooms, replays recorded frames, and
// draws journeys for the traffic events the backend reports. It never invents
// a route: an event animates only along a declared FQDN chip the server laid
// out, through the public trunk into the edge proxy, or along an overlay
// lead to the host. A name no route owns draws nothing at all.
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
  const VIEW_NAME_KEY = "fleet-topology-view-name";
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
  // The diagram is laid out by the server to be read whole: every column,
  // every station, at once. So the opening view is always the whole map, at
  // both a laptop and a phone: the reader's first look answers "what is my
  // edge?" and zoom is a tool they reach for, never a state the page
  // imposes on them. A saved view is honoured only if the reader made one.
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
  // initialView is the fit and nothing else. The server sized the viewBox to
  // the stage's aspect ratio, so scale 1 already means "every station, every
  // name, on screen": a phone shows the same map as a laptop, smaller.
  function initialView() {
    if (!autoView) return;
    t = { x: 0, y: 0, k: 1 };
    apply();
  }
  window.addEventListener("resize", () => { if (autoView) initialView(); });

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

  // ---- views -----------------------------------------------------------
  // Views never hide anything: every public and overlay path is part of the
  // always-on picture, so a view only decides which recorded wiring leads.
  // There are no layer checkboxes and no hidden-layer storage: the diagram
  // shows its whole reach at every moment, and the class on the root drives
  // the opacity emphasis in the SVG's own stylesheet.
  const VIEWS = ["overview", "physical", "control"];
  function setView(name) {
    const view = VIEWS.includes(name) ? name : "overview";
    for (const v of VIEWS) svg.classList.toggle("view-" + v, v === view);
    document.querySelectorAll("[data-view]").forEach((b) => {
      const on = b.dataset.view === view;
      b.classList.toggle("on", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
    try { localStorage.setItem(VIEW_NAME_KEY, view); } catch { /* ignore */ }
  }
  document.querySelectorAll("[data-view]").forEach((b) =>
    b.addEventListener("click", () => setView(b.dataset.view)));
  let savedView = "overview";
  try {
    const v = localStorage.getItem(VIEW_NAME_KEY);
    if (VIEWS.includes(v)) savedView = v;
  } catch { /* private mode */ }
  setView(savedView);

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

  // ---- route catalogue and web -----------------------------------------
  // The server lays out the DNS clouds and carries the catalogue in
  // <metadata id="topo-routes">. Nothing here invents a name: an event
  // resolves against a declared marker (host + routeKey) or it draws no path.
  let web = { groups: [], markers: [], links: [], records: [], available: false };

  const parseWeb = (root) => {
    let raw = null;
    try {
      const node = root.querySelector("#topo-routes");
      if (node && node.textContent.trim()) raw = JSON.parse(node.textContent);
    } catch { raw = null; }
    const groups = raw && Array.isArray(raw.groups) ? raw.groups : [];
    const markers = [];
    for (const g of groups) {
      if (!g || !Array.isArray(g.routes)) continue;
      for (const m of g.routes) if (m && typeof m === "object") markers.push(m);
    }
    const dns = (raw && raw.dns) || {};
    web = {
      groups,
      markers,
      links: raw && Array.isArray(raw.links) ? raw.links : [],
      records: Array.isArray(dns.records) ? dns.records : [],
      available: !!dns.available,
      zone: dns.zone || "",
      external: Array.isArray(dns.external) ? dns.external : [],
    };
  };

  // markerFor resolves a traffic event to the one declared marker it may
  // animate. The event's audience selects the web it belongs to (public names
  // travel the amber web, tailnet names the purple one), because the same name
  // can be declared on both. The route key is authoritative: when the event
  // names one, only an exact host + route + service match animates, and a
  // mismatch draws nothing rather than a neighbouring chip's path. The service
  // is the fallback for a provider that reports no route at all.
  const markerFor = (ev) => {
    const host = ev.host || "";
    if (!host) return null;
    const group = ev.audience === "tailnet" ? "overlay" : ev.audience === "public" ? "public" : "";
    const inWeb = (m) => !group || m.group === group;
    if (ev.route) {
      return web.markers.find((m) => inWeb(m) && m.declared !== false && m.host === host &&
        m.route === ev.route && (!ev.service || m.service === ev.service)) || null;
    }
    return web.markers.find((m) => inWeb(m) && m.host === host && m.declared !== false && m.service && m.service === ev.service) || null;
  };

  // Marker hitboxes in absolute SVG coordinates, cached per applied frame so
  // a journey can start and end on the chip the pointer is actually over.
  const markerBox = (m) => {
    // A chip can be declared in either web, so both marker classes are matched
    // and the marker's own group picks the one it means. Missing the overlay
    // class was what left tailnet traffic without a start point.
    const fqdn = cssId(m.fqdn || m.id);
    const all = svg.querySelectorAll(`.rweb-marker[data-fqdn="${fqdn}"], .oweb-marker[data-fqdn="${fqdn}"]`);
    const g = [...all].find((n) => !m.group || n.getAttribute("data-group") === m.group) || all[0] || null;
    if (!g) return null;
    const hit = g.querySelector(".rw-hit");
    if (!hit) return null;
    const x = Number(hit.getAttribute("x")) || 0;
    const y = Number(hit.getAttribute("y")) || 0;
    return { x, y, w: Number(hit.getAttribute("width")) || 0, h: Number(hit.getAttribute("height")) || 0 };
  };
  const cssId = (id) => (window.CSS && CSS.escape ? CSS.escape(id) : String(id).replace(/["\\]/g, "\\$&"));
  // A declared chip selects the host that serves it, so the panel is one
  // click away; a DNS-only chip stays inert and keeps the server's tooltip.
  function bindMarkers() {
    svg.querySelectorAll(".rweb-marker, .oweb-marker").forEach((g) => {
      if (g.dataset.bound) return;
      g.dataset.bound = "1";
      if (g.getAttribute("data-declared") !== "true") return;
      const pick = () => {
        const id = byHost.get(g.getAttribute("data-host") || "");
        if (id) select(id);
      };
      g.addEventListener("click", pick);
      g.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(); }
      });
    });
  }

  // ---- in-cloud sparkles -----------------------------------------------
  // Slow, bounded and purely decorative: sparkles orbit inside a chip's own
  // box. Labels never move, so hitboxes stay exactly where they were painted.
  const orbits = [];
  function hash32(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return h >>> 0;
  }
  function ensureOrbits() {
    orbits.length = 0;
    svg.querySelectorAll(".rweb-marker, .oweb-marker").forEach((g) => {
      const hit = g.querySelector(".rw-hit");
      if (!hit) return;
      const w = Number(hit.getAttribute("width")) || 0;
      const h = Number(hit.getAttribute("height")) || 0;
      if (w < 44 || h < 14) return;
      let o = g.querySelector(".rweb-orbit");
      if (!o) {
        o = sEl("g", { class: "rweb-orbit" });
        for (let i = 0; i < 3; i++) o.append(sEl("circle", { class: "spark", r: 1.5, cx: 0, cy: 0 }));
        g.append(o);
      }
      o.dataset.cx = String(Number(hit.getAttribute("x")) + w - 13);
      o.dataset.cy = String(Number(hit.getAttribute("y")) + h / 2);
      orbits.push({ g: o, phase: (hash32(g.getAttribute("data-fqdn") || "x") % 1000) / 1000 });
    });
  }
  function placeOrbits(clock) {
    if (!orbits.length) return;
    const base = (clock / ORBIT_PERIOD) * Math.PI * 2;
    for (const o of orbits) {
      const cx = Number(o.g.dataset.cx) || 0;
      const cy = Number(o.g.dataset.cy) || 0;
      const kids = o.g.children;
      for (let i = 0; i < kids.length; i++) {
        const a = base + o.phase * Math.PI * 2 + (i / kids.length) * Math.PI * 2;
        kids[i].setAttribute("cx", (cx + Math.cos(a) * 7).toFixed(2));
        kids[i].setAttribute("cy", (cy + Math.sin(a) * 7).toFixed(2));
      }
    }
  }

  // The orbit clock is the traffic clock: it only turns while the map shows
  // live data or a playing replay, so pausing freezes the clouds exactly as it
  // freezes the dots, and reduced motion never starts it. Its phase is
  // accumulated rather than read from the wall clock, so resuming continues
  // where the clouds were left instead of jumping.
  let orbitRaf = 0, orbitClock = 0, orbitLast = 0;
  const ORBIT_PERIOD = 26000; // one slow lap per 26 s
  function orbitTick(now) {
    orbitRaf = 0;
    if (reduced || !orbits.length || !dotsRunning()) { orbitLast = 0; return; }
    const dt = orbitLast ? Math.min(100, now - orbitLast) : 16;
    orbitLast = now;
    orbitClock = (orbitClock + dt) % ORBIT_PERIOD;
    placeOrbits(orbitClock);
    orbitRaf = requestAnimationFrame(orbitTick);
  }
  function startOrbits() {
    if (reduced || !orbits.length || orbitRaf || !dotsRunning()) return;
    orbitRaf = requestAnimationFrame(orbitTick);
  }
  function stopOrbits() {
    if (orbitRaf) cancelAnimationFrame(orbitRaf);
    orbitRaf = 0;
    orbitLast = 0;
  }
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
    lan: "LAN attachment (switch/port not recorded)",
  };
  function select(id) {
    selected = meta[id] ? id : "";
    if (selected) history.replaceState(null, "", "#" + encodeURIComponent(selected));
    else if (location.hash) history.replaceState(null, "", location.pathname + location.search);
    highlight();
    renderPanel();
  }

  // highlight only marks the chosen station. The map is never dimmed: every
  // public and overlay path keeps its baseline weight while a station is
  // selected, so the always-on picture stays readable.
  function highlight() {
    const id = selected;
    svg.querySelectorAll(".node").forEach((n) => {
      n.classList.toggle("sel", n.dataset.id === id);
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
    const info = meta[hostId];
    const svc = serviceOf(info, name);
    if (!svc) return "this service is not declared any more.";
    if (!overlay) return "the map is not drawn yet.";
    const route = (info.routes || []).find((r) => r.service === name) || null;
    if (!route) return `${name} declares no route here: there is no path to draw.`;
    const drawn = routeFor({ host: info.host || hostId, service: name, route: route.routeKey });
    if (!drawn) return `${name} has no route on the map: its name is not bound to a drawn chip.`;
    preview = journeyPath("journey preview j-" + drawn.audience, drawn.d, drawn.audience, 1.5);
    overlay.append(preview);
    return "";
  }

  function renderPanel() {
    const info = meta[selected];
    panel.hidden = !info;
    // The popover floats over the map on the side opposite the chosen
    // station, so it never covers the thing that was clicked.
    if (info) {
      const sx = t.x + info.x * t.k;
      const r = stage.getBoundingClientRect();
      panel.classList.toggle("left", sx > r.width / 2);
    } else {
      panel.classList.remove("left");
    }
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

    // Named routes: the FQDN a person types, which chip carries it and where
    // that chip lands. This is the same list the map binds traffic against, so
    // the panel and the moving dots can never disagree.
    const routes = info.routes || [];
    if (routes.length) {
      panel.append(el("h3", {}, `Names (${routes.length})`));
      const ul = el("ul", { class: "topo-routes" });
      for (const r of routes) {
        const li = el("li", {},
          el("strong", {}, r.fqdn || r.label || r.routeKey || "route"),
          r.public ? el("span", { class: "badge badge-public" }, "via edge")
            : r.viaRouter ? el("span", { class: "badge badge-lan" }, "via router")
            : el("span", { class: "badge badge-tailnet" }, "overlay"));
        const bits = [r.service, r.routeKey !== r.service ? r.routeKey : "", r.proto && r.port ? `${r.proto}:${r.port}` : ""].filter(Boolean);
        if (bits.length) li.append(el("div", { class: "muted topo-platform" }, bits.join(" · ")));
        if (r.dns) li.append(el("div", { class: "muted" }, `DNS ${r.dns} · ${web.zone || "public zone"}`));
        ul.append(li);
      }
      panel.append(ul);
    }

    // Disk space is the one simulated number on this page: the ring fill comes
    // from the server's deterministic fraction, and it is labelled here and in
    // every tooltip. Recorded capacity stays the honest figure beside it.
    const mounts = info.mounts || [];
    if (mounts.length) {
      panel.append(el("h3", {}, `Space (simulated fill · ${mounts.length} mount${mounts.length === 1 ? "" : "s"})`));
      const ul = el("ul", { class: "topo-mounts" });
      mounts.forEach((m) => {
        const frac = Math.max(0, Math.min(1, Number(m.simulatedFraction) || 0));
        const li = el("li", {},
          // The swatch is the ring's own stroke, so the list and the map agree.
          el("span", { class: "topo-shade", style: m.color ? `color:${m.color}` : "" }),
          el("strong", {}, m.mount || "mount"),
          el("span", { class: "muted" }, ` · simulated ${Math.round(frac * 100)}%`),
          m.actualTotal ? el("span", { class: "muted" }, ` · reported ${fmtBytes(m.actualUsed)} / ${fmtBytes(m.actualTotal)}`) : null);
        if (m.submounts && m.submounts.length) li.append(el("div", { class: "muted" }, "+ " + m.submounts.join(" · ")));
        ul.append(li);
      });
      ul.append(el("li", { class: "topo-age" }, "fill is a deterministic simulation; capacity and SMART above are recorded"));
      panel.append(ul);
    }

    // Faults and enforcement are separate ledgers: services not running and
    // disk problems are faults; bans are protective and only ever a badge.
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
  // Every trace starts at a chip the server laid out and ends at the host
  // that serves it: there is no invented "internet client" box, because the
  // public trunk and the edge proxy already say where a request comes from.
  const seen = new Set();
  const dots = [];
  let rafId = 0;

  function nodePoint(id) {
    const info = meta[id];
    return info ? { x: info.x, y: info.y } : null;
  }
  function serviceOf(info, name) {
    if (!info || !name) return null;
    return (info.services || []).find((s) => s.name === name) || null;
  }
  // curveThrough joins a short run of points with straight legs and quadratic
  // corners, the same corner language the server uses for every drawn run. The
  // radius shrinks to fit each leg, so a tight pair of bends never overshoots.
  function curveThrough(points, radius) {
    const n = points.length;
    if (!n) return "";
    const num = (v) => String(Math.round(v * 10) / 10);
    let d = `M${num(points[0].x)} ${num(points[0].y)}`;
    for (let i = 1; i < n - 1; i++) {
      const p = points[i];
      const inX = p.x - points[i - 1].x, inY = p.y - points[i - 1].y;
      const outX = points[i + 1].x - p.x, outY = points[i + 1].y - p.y;
      const inLen = Math.hypot(inX, inY), outLen = Math.hypot(outX, outY);
      if (!inLen || !outLen) continue;
      const r = Math.min(radius, inLen / 2, outLen / 2);
      d += ` L${num(p.x - (inX / inLen) * r)} ${num(p.y - (inY / inLen) * r)}` +
        ` Q${num(p.x)} ${num(p.y)} ${num(p.x + (outX / outLen) * r)} ${num(p.y + (outY / outLen) * r)}`;
    }
    const last = points[n - 1];
    return d + ` L${num(last.x)} ${num(last.y)}`;
  }
  // braceSpine is the x of the brace's long straight run — the bus every chip
  // hangs off. It is the x the brace repeats most often, read from the drawn
  // brace's own numbers rather than from a path parser.
  function braceSpine(group) {
    const nums = (String(group.brace || "").match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
    const tally = new Map();
    for (let i = 0; i + 1 < nums.length; i += 2) tally.set(nums[i], (tally.get(nums[i]) || 0) + 1);
    let best = group.collector.x - 16, bestN = 0;
    for (const [x, n] of tally) if (n > bestN) { best = x; bestN = n; }
    return best;
  }
  function linkFor(groupId, host, hostId) {
    return web.links.find((l) => l.group === groupId &&
      ((host && l.host === host) || (hostId && l.toId === hostId))) || null;
  }
  // declareDNS states the delegation the map would otherwise leave implied:
  // the public zone is authoritative at the DNS provider, but nothing routes
  // traffic there, so the line is faint and dotted and carries no dot. It runs
  // from the provider's head up the gutter beside the clouds into the public
  // collector, never across another cloud. Without a DNS node or a public
  // collector there is nothing to declare, and nothing is drawn.
  function declareDNS(root) {
    const pub = web.groups.find((g) => g.id === "public");
    if (!pub || !pub.collector) return;
    const id = Object.keys(meta).find((k) => meta[k] && meta[k].kind === "dns");
    if (!id) return;
    const node = root.querySelector(`.node[data-id="${cssId(id)}"]`);
    const head = node && node.querySelector(".head");
    if (!head) return;
    const at = (node.getAttribute("transform") || "").match(/-?[\d.]+/g) || [];
    const ox = Number(at[0]) || 0, oy = Number(at[1]) || 0;
    const cx = Number(head.getAttribute("cx")) || 0;
    const cy = Number(head.getAttribute("cy")) || 0;
    const r = Number(head.getAttribute("r")) || 0;
    // Climb the empty corridor between the name clouds and the rack, so the
    // declaration never runs across a chip, a label or another cloud's body.
    // The turns are rounded with the same corners the server draws.
    const lane = pub.collector.x + 36;
    const d = curveThrough([
      { x: ox + cx + r, y: oy + cy },
      { x: lane, y: oy + cy },
      { x: lane, y: pub.collector.y },
      { x: pub.collector.x, y: pub.collector.y },
    ], 12);
    const g = sEl("g", { class: "dns-declaration", "aria-hidden": "true" });
    const path = sEl("path", { d, fill: "none" });
    const zone = web.zone ? ` ${web.zone}` : "";
    // SVG carries its own <title> element; an HTML one in this namespace
    // never becomes a tooltip.
    const tip = sEl("title");
    tip.textContent = `DNS declarations:${zone} is authoritative at ${(meta[id] && meta[id].label) || "the DNS provider"} and carries no traffic route`;
    path.append(tip);
    g.append(path);
    const nodes = root.querySelector("g.nodes");
    if (nodes) nodes.before(g); else root.append(g);
  }
  // routeFor walks an event along the ground the server actually drew: out of
  // the chip onto its cloud's brace, down the brace to the collector, out the
  // collector lead, then along the one branch declared for the serving host.
  // Every leg restates the server's own drawn run — lead and branch verbatim,
  // curves and all — behind one short curved feed from the chip, so the dot
  // rides exactly the line on screen.
  // The public lead carries every public name through the edge proxy and the
  // branch takes it on to the host; an overlay name stays on the purple trunk
  // and its own branch and never touches the public gateway. A name whose
  // cloud or branch is missing draws nothing: an invented hop is worse than a
  // missing one.
  function routeFor(ev) {
    if (!ev || !ev.host) return null;
    const hostId = byHost.get(ev.host);
    const hostPt = hostId && nodePoint(hostId);
    if (!hostPt) return null;                       // unplaced host: nothing to draw
    const m = markerFor(ev);
    if (!m) return null;                            // no declared route: no path
    const box = markerBox(m);
    if (!box) return null;
    const group = web.groups.find((g) => g.id === m.group) || null;
    if (!group || !group.collector) return null;
    const branch = linkFor(group.id, ev.host, hostId);
    // A name served by the edge proxy itself has no branch: its lead already
    // ends on that hub, so the trace stops where the drawn lead stops.
    if (!branch && hostId !== hubs.edge) return null;
    // The feed leaves the chip's right edge, meets the brace's long run, and
    // rides it to the collector where the server's lead begins.
    const tip = group.collector;
    const spine = braceSpine(group);
    const y = box.y + box.h / 2;
    const feed = curveThrough([
      { x: box.x + box.w, y },
      { x: spine, y },
      { x: spine, y: tip.y },
      { x: tip.x, y: tip.y },
    ], 12);
    const parts = [feed, group.lead, branch ? branch.d : ""].filter(Boolean);
    return { d: parts.join(" "), audience: group.id === "public" ? "public" : "tailnet" };
  }

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
    const path = journeyPath(`journey j-${route.audience} ${kind}`, route.d, route.audience, 2);
    const dot = sEl("circle", {
      class: `ev-dot aud-${route.audience} ${kind}`,
      cx: 0, cy: 0, r: 3.2,
    });
    const tip = sEl("title");
    tip.textContent = [
      kind === "real" ? "measured" : "simulated",
      ev.service || "", ev.proto, ev.status,
      ev.ms ? ev.ms + "ms" : "", ev.bytes ? fmtBytes(ev.bytes) : "",
    ].filter(Boolean).join(" · ");
    dot.append(tip);
    overlay.append(path, dot);
    // The dot rides the path the browser resolved, not a copy of its corners:
    // measured once on arrival, then queried by distance every frame.
    const item = { dot, path, total: path.getTotalLength(), dur: 0, progress: 0, fading: false, fadeLeft: 0, out: false };
    if (!(item.total >= 1)) { path.remove(); dot.remove(); return; }
    const head = pointAt(item, 0);
    dot.setAttribute("cx", head.x.toFixed(1));
    dot.setAttribute("cy", head.y.toFixed(1));
    item.dur = Math.min(2400, Math.max(700, item.total * 2.5));
    dots.push(item);
    if (reduced) {
      // No travelling dot: park the marker at the destination and fade it.
      const end = pointAt(item, item.total);
      dot.setAttribute("cx", end.x.toFixed(1));
      dot.setAttribute("cy", end.y.toFixed(1));
      item.fading = true;
      item.fadeLeft = 900;
    }
    if (!rafId) rafId = requestAnimationFrame(tick);
  }

  // pointAt asks the browser where the drawn path is at a distance. Curves are
  // measured by the same code that renders them, so no geometry is restated.
  function pointAt(item, dist) {
    return item.path.getPointAtLength(Math.max(0, Math.min(item.total, dist)));
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
    parseWeb(imported);
    declareDNS(imported);
    bindMarkers();
    ensureOrbits();
    ensureOverlay();

    if (selected && !meta[selected]) selected = "";
    highlight();
    renderPanel();
    summarize();
    // Chips are rebuilt with every frame, so restart the decorative clock
    // only when the map is actually showing motion.
    startOrbits();
    if (autoView) initialView();
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
    startOrbits();
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
    stopOrbits();
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
      if (modeNote) modeNote.textContent = simulated ? "Simulated · nothing measured" : "No real traffic connected";
      return;
    }
    setBadge(simulated, "Live traffic");
    if (simNote) {
      simNote.hidden = !traffic.message;
      simNote.textContent = traffic.message || "";
    }
    if (modeNote) {
      modeNote.textContent = simulated
        ? "Simulated · declared routes"
        : "Measured · " + (traffic.provider || "live provider");
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
    if (geoip === undefined || !attrEl) return;
    if (geoip && geoip.available) {
      attrEl.hidden = false;
      if (attrNote) attrNote.textContent = geoip.source ? " · " + geoip.source : "";
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
      startOrbits();
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
