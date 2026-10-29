// Service worker for the installable app.
//
// It only ever touches /static/*: the pane list, frames, SSE streams and every
// POST go straight to the network, because caching them would show a phone a
// stale view of a live terminal. The fetch handler is what makes Chrome offer
// the install prompt, and it keeps icons/CSS/JS usable on a flaky tailnet.
//
// Nothing is pre-cached. Static responses are cached as they are used, and only
// when they are genuine 200s that were not redirected: with the app behind
// Zitadel, an expired session turns a static request into a redirect to the
// login page, and caching that under /static/app.css would leave a phone with a
// permanently broken stylesheet.
const CACHE = "tam-static-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin) return;
  if (!url.pathname.startsWith("/static/")) return;

  event.respondWith(
    caches.match(event.request).then((hit) => {
      if (hit) return hit;
      return fetch(event.request).then((res) => {
        if (res.ok && !res.redirected) {
          const copy = res.clone();
          caches.open(CACHE).then((cache) => cache.put(event.request, copy)).catch(() => {});
        }
        return res;
      });
    })
  );
});
