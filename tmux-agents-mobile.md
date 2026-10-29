# tmux-agents-mobile

Mobile check-in UI for agent panes, without ever attaching a tmux client.
Go + `html/template` + HTMX (vendored), embedded static assets, Zitadel OIDC on
every route. Host: `lio` only.

## Why this shape

A tmux pane cannot be attached to individually: layout, zoom and the window's
active pane are window state shared by every client. Any attach from a phone
either shrinks the window (`window-size latest` is set on lio today) or gets a
crop of a 200-column layout. tmux 3.7's `-f ignore-size,active-pane` +
`refresh-client -L/-R/-U/-D` fix the *damage* but not the width: a pane has one
width, so the phone always sees the desktop-sized grid.

So this service does not attach. It reads `capture-pane`, re-renders the text at
phone width, and writes back with `send-keys`. Consequences, all desirable:

- cannot resize, zoom, select or in any way disturb the desktop view;
- works on panes in windows nobody is looking at (the usual case on a phone);
- reflows prose/diffs to phone width instead of scaling a 200-col grid.

Measured on lio (tmux 3.7b, same server): `capture-pane -ep` of a 384x96 pane
costs **1.5 ms** and **8.0 KB raw → 0.76 KB gzipped**; `list-panes -a` 1.5 ms.
A 5 Hz watcher for one pane is ~0.75% of a core and ~15 KB/min of cellular.

## Decisions

| Topic | Decision |
|---|---|
| Exposure | nginx vhost on lio's overlay IP, plain HTTP, tailnet sources only (fleet-edge pattern). Dev first: bare-metal binary on 127.0.0.1, then a temporary nft rule for phone testing. |
| Auth | Zitadel OIDC PKCE, copied from `flakes/fleet-edge/internal/auth`. HMAC cookie, 8 h TTL, no role gate. Wraps the entire mux. |
| Views v1 | Inbox, pane view, diff view, new session. |
| Frame layout | Soft-wrap by default (`capture-pane -J`, trailing blanks trimmed); per-pane "fit width" toggle (`-N`, no wrap, font scaled to columns). |
| Seen state | Viewing on the phone marks the pane seen and suppresses that pane's desktop/sound notifications while watched. |
| Input | Native phone keyboard only (Android + full external keyboard). Compose box + raw-key mode; no virtual key bar in v1. |
| Multi-pane | Single pane only. |

## Repo layout

```
flakes/tmux-agents-mobile/
  flake.nix                  buildGoModule + apps + devShell (mirrors fleet-edge)
  go.mod
  main.go                    flags, wiring, graceful shutdown
  internal/tmux/tmux.go      thin exec wrapper over the tmux binary
  internal/tmux/tmux_test.go integration tests on an isolated `tmux -L tamtest` socket
  internal/frame/frame.go    ANSI(SGR) -> HTML spans, per-line hashing, trimming
  internal/frame/frame_test.go
  internal/watch/hub.go      one goroutine per watched pane, subscriber fan-out
  internal/agents/agents.go  `tmux-agents rows --json` (cached 1 s) + fallback
  internal/diff/diff.go      git status / diff / untracked handling
  internal/auth/auth.go      copied from fleet-edge, cookie = tam_session
  internal/web/server.go     routes, middleware (auth, gzip, origin check, headers)
  internal/web/templates/*.html
  internal/web/static/{app.css,app.js,htmx.min.js}
```

`flake.nix` takes `tmux-agents` as an input so the plugin binary is available to
the service (`path = [ tmux-agents ]` in the module, or a wrapper at build time).

## tmux contract

All calls: `exec.CommandContext` with a 3 s timeout, `LC_ALL=C`, and a `\x1f`
(unit separator) field delim — **not** tabs, because `read`/splitting collapses
empty fields and tmux formats emit empty strings for unset options.

**List** (`list-panes -a -F`), fields:
`session_name`, `window_index`, `window_name`, `pane_id`, `pane_active`,
`window_active`, `pane_current_command`, `pane_current_path`, `pane_title`,
`pane_width`, `pane_height`, `history_size`, `cursor_x`, `cursor_y`,
`pane_in_mode`, `pane_dead`, `@agent_state`, `@agent_unseen`, `@pane_name`,
`@session_ai_name`, `@agent_watch_until`.

**Frame**: `capture-pane -pe -t %id` (`-J` in wrap mode, `-N` in fit mode),
plus `-S -<n>` for the history page. Cursor from `cursor_x`/`cursor_y`.

**Input**:
- text → `send-keys -t %id -l -- <text>` (literal, no key-name interpretation);
- multi-line / paste → `load-buffer -` + `paste-buffer -p -t %id` (bracketed
  paste, so the agent's editor treats it as a paste, then a separate
  `send-keys -t %id Enter`);
- raw keys → `send-keys -t %id <KeyName>`: `Enter Escape Tab BTab Up Down Left
  Right DC Home End PPage NPage`, and `C-a`…`C-z`, `M-x` for modifiers.
- Cap payloads at 8 KB; reject larger with 413.

**New session**: `new-session -d -s <name> -c <dir>` plus an *enumerated*
program only (`zsh`, `omp`, `opencode`) — never an arbitrary command string;
this endpoint is otherwise an RCE surface. Name rules delegated to
`tmux-agents create --dir <dir> --name <name> --program <p>` (new subcommand,
reuses the plugin's validation).

**Desktop handoff**: `switch-client -c <client_tty> -t %id`, where the client is
the attached client with the largest `client_width*client_height`. The phone is
never a tmux client, so there is nothing to exclude.

**Kill**: `tmux-agents kill <id>` (existing subcommand, has its own confirm
semantics — the web layer adds a POST-only confirm page).

## Plugin changes (`flakes/tmux-agents`)

Small, additive; the navigator keeps its current behaviour.

1. `rows --json` — same grouping/labels as the navigator, JSON objects instead
   of fzf-rendered lines: `{id, kind: repo|session|pane, session, repo, branch,
   worktree, path, pane, label, agent, state, unseen}`. Single source of truth
   for repo/worktree grouping; avoids reimplementing it in Go.
2. `seen <pane>` — unset `@agent_unseen` for the pane and recompute
   `@agent_win` for its window (the tick's existing logic), so the status badge
   clears without waiting for a selection hook.
3. `create --dir <dir> --name <name> --program <zsh|omp|opencode>` — the
   existing `cmd_create` with an explicit directory instead of "selected pane's
   cwd".
4. **Watch muting** in `cmd_tick`: skip `notify` for a pane whose
   `@agent_watch_until` (epoch seconds) is in the future, and treat that pane as
   seen. The service refreshes the option every ~5 s while a phone has an SSE
   stream open, and clears it when the last subscriber disconnects. This is the
   "I looked at it on my phone, don't ping my desktop" behaviour.

Go side treats the plugin as optional: if the binary is missing, fall back to
plain `list-panes` (no repo/branch grouping).

## Frame protocol

`GET /p/{pane}/events` (SSE, `X-Accel-Buffering: no`):

```
event: init    data: {"cols":384,"rows":96,"cx":12,"cy":40,"in_mode":false,
                     "dead":false,"lines":[{"n":0,"h":"<span…>"},…]}
event: patch   data: {"lines":[{"n":40,"h":"<span…>"},……]}   // changed only
event: full    data: {…same as init…}                        // >40% changed
event: gone    data: {}
```

Server side: one `Watch` per pane, 200 ms ticker, stop 30 s after the last
subscriber leaves (keep the last frame for an instant first paint). Line hash =
`xxhash`/`sha1` of the rendered HTML; a patch is the contiguous changed range,
so a waiting agent typically sends 0 lines, and a streaming agent 1-5.

Rendering (`internal/frame`):
- parse only SGR (`m`) sequences; drop every other CSI/OSC;
- emit `<span style="color:#rrggbb;background:#rrggbb;font-weight:{…}">` —
  truecolor flattened to hex so CSS vars/theme don't matter and gzip likes it;
- handle `1`/`2`/`3`/`4`/`7`/`9`/`22`/`23`/`24`/`27`/`39`/`49`, 16-colour and
  256-colour;
- HTML-escape text; trim trailing blanks in wrap mode; `\r` dropped;
- CSS: `white-space: pre-wrap; overflow-wrap: anywhere` (wrap) vs
  `white-space: pre; overflow-x: auto` + `font-size: calc(100vw / cols * 0.6)`
  (fit);
- block cursor drawn at `cx,cy` when the pane is on the live screen.

## Views

**`GET /` inbox** — sections *Needs input* / *Working* / *Idle*; each row:
repo · branch/worktree · session · agent label · state glyph · one-line preview
(last non-blank captured line, only for `input` rows and the first 10 rows —
cost is 1.5 ms each, only on request). Tap → pane view. Header: counts, refresh
timestamp, log-out.

**`GET /p/{pane}` pane view** — header (repo/branch, session:window, agent
label, state), the SSE frame, composer, and an actions row: *diff*, *history*,
*new session here*, *open on desktop*, *kill*, *fit toggle*, *wrap toggle*.
Two input modes behind a toggle:
- **compose** (default): textarea, Enter sends text+Enter, Shift+Enter newline,
  send via `paste-buffer -p` when the text contains a newline;
- **raw**: a focused hidden input whose `keydown` events are `preventDefault`ed
  and forwarded as key names (`Escape`, `Tab`, `C-c`, arrows, digits). This is
  the mode that makes a full external Android keyboard behave like a terminal.
  Composition/IME input is not supported in raw mode (falls back to compose).

**`GET /p/{pane}/diff`** — repo root from `git -C <pane_cwd> rev-parse
--show-toplevel`. File list from `git status --porcelain=v1 -z`
(`--untracked-files=all`); per-file diff `git diff --no-color -U3 [--cached] --
<file>`, untracked files via `--no-index /dev/null <file>`. Colour by line
prefix (`+`/`-`/`@@`/header) with line numbers from the hunk headers; cap at
2000 lines / 512 KB → "diff too large, open in the terminal". Toggles: staged /
unstaged, unified / more context. Actions: *copy hunk* (clipboard JS), *send to
agent* (opens the composer prefilled with the file list), *refresh*.
`GIT_TERMINAL_PROMPT=0`, `--no-pager`, 5 s timeout.

**`GET /new`** — directory picker: recent pane paths, `git worktree list` of the
current repo, children of configured roots (`TAM_ROOTS`, default
`~/projects:~/other:~/.config`), plus free-text absolute path validated to be a
directory under one of those roots. Name prefilled from the basename, program
picked from the enum, target = new session or new window in an existing
session. POST → `tmux-agents create --dir …` → redirect to the new pane.

## Auth

Copy `flakes/fleet-edge/internal/auth` verbatim (941 lines, stdlib only) with
`SessionCookieName = "tam_session"`. Config from env, matching fleet-edge:

```
TAM_ZITADEL_ISSUER=https://sso.joshuabell.xyz
TAM_ZITADEL_PROJECT_ID=…
TAM_ZITADEL_CLAIM=flatRolesClaim
TAM_ZITADEL_CLIENT_ID=…            # new PKCE app, redirect = /auth/callback
TAM_ZITADEL_REDIRECT_URI=…         # empty = derive from request Host
TAM_ZITADEL_ROLE=                  # empty = any authenticated project member
TAM_SESSION_KEY_FILE=…             # optional; random per boot otherwise
```

- `auth.Wrap` around the whole mux, including `/static/*`, `/p/*/events` and
  every POST — no unwrapped route except a loopback-only `/healthz` on a second
  listener.
- Cookie `HttpOnly; SameSite=Lax; Path=/`, `Secure` only when the request looks
  secure (`isSecureRequest` already handles the HTTP-behind-nginx case).
- POSTs additionally require `Origin` (or `Sec-Fetch-Site: same-origin`) to
  match the request host — cheap CSRF defence without tokens.
- Dev escape hatch: `--dev-no-auth`, refused unless the listen address is
  loopback; `--dev-allow-tailnet` is a second explicit flag that lifts that
  restriction (only for the temporary phone-test window). Startup logs a loud
  banner whenever auth is off.

Extract auth to a shared flake only if a third consumer appears; today a copy
is cheaper than a `replace`-based Nix dance.

## Dev loop (this host, bare metal)

```
cd flakes/tmux-agents-mobile
go get ./... && go test ./...
go run . --listen 127.0.0.1:8099 --dev-no-auth          # browser on lio
go run . --listen 100.64.0.1:8099 --dev-no-auth --dev-allow-tailnet   # phone
```
Phone testing needs a temporary nft rule for `tailscale0 → 8099` from the
phone's overlay IP (added ad hoc, not committed). Then the real auth path with
the new Zitadel app and `http://127.0.0.1:8099/auth/callback` registered as a
second redirect URI.

Later: `homeManagerModules.default` on lio — `systemd.user.services.tmux-agents-mobile`
(same user as the tmux server, so socket access needs no tricks), `Restart=always`,
`UMask=0077`, `NoNewPrivileges`, `PrivateTmp=false` (tmux socket lives in
`/tmp/tmux-<uid>/`), no `ProtectHome` (git needs `~/projects`), loopback bind,
plus the nginx vhost and an `extraInputRules` line scoped to the phone's overlay
IP.

## Phasing

1. **P0 — skeleton**: flake + module layout, tmux wrapper, frame renderer,
   inbox (no previews), pane view with 1 s HTMX polling, gzip. *Done when the
   phone browser shows a live agent pane at readable width.*
2. **P1 — SSE + input**: watch hub, line patches, compose + raw-key modes,
   mark-seen + watch-until muting (plugin changes 1-2, 4).
3. **P2 — diff + new session**: diff view, directory picker and
   `create --dir` (plugin change 3), open-on-desktop, kill.
4. **P3 — ship it**: HM module, nginx vhost, firewall rule, PWA manifest
   (`display: standalone`, icons, `apple-mobile-web-app-capable`) — note the
   service worker/push limits of plain HTTP; revisit TLS only if push is wanted.

## Testing

- Unit: frame (SGR → HTML, trimming, wide chars, hashing), diff parsing,
  path validation, origin check, auth middleware with a stub issuer.
- Integration: spin `tmux -L tamtest -f /dev/null`, create a session, run
  `cat`/`printf` loops, assert capture → render → `send-keys` round trips.
  This is also how the `ignore-size`/no-attach claim stays honest.
- Manual: Android Chrome profile — inbox → pane → compose → raw keys → diff →
  new session, with the desktop visible to confirm nothing moves.

## Known limits

- TUIs that repaint with absolute cursor addressing don't reflow; use the fit
  toggle (approximate for wide glyphs/emoji, since we don't render a cell grid).
- No mouse forwarding: mouse-only dialogs remain desktop-only.
- `capture-pane` gives the rendered screen, so scrollback paging is coarse
  (whole history in chunks via `-S`), not copy-mode fidelity.
- Raw-key mode depends on the keyboard emitting proper `keydown` modifiers;
  otherwise compose mode covers it.
- A tmux client/server version skew after a nixpkgs bump can break the exec
  wrapper; pin the wrapper to the same package as `programs.tmux`.
