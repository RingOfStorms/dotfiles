# tmux-agents-mobile

A phone-sized view of the agent panes on one machine's tmux server, plus a
separate full terminal for the service user's login shell.

The **pane views never attach a tmux client**. They read `capture-pane`,
re-render text at phone width and write back with `send-keys`:

- it cannot resize, zoom or select anything, so the desktop view never moves
  (`window-size latest` makes an attached phone client resize every pane);
- it works on panes in windows nobody is looking at, which is most of them;
- prose reflows to phone width instead of scaling a 200-column grid down.

Measured on lio (tmux 3.7b, same server): `capture-pane -ep` of a 384x96 pane
costs ~1.5 ms and ~8 KB raw / **0.8 KB gzipped**. One watched pane at 5 Hz is
under 1% of a core and a few KB/s, and nothing is captured while no browser is
connected.

## What it does

- **Panes** (`/`) — one flat card per clickable leaf, using the same grouping
  `prefix + w` does: card = repo · `session ai-label [branch]` · pane glyph and
  label, with the pane's directory on the right. Agent panes each get a card; a
  session with no agent panes gets a single card pointing at its active pane, so
  shell-only worktrees stay reachable (those cards have no glyph). A magnifier
  button in the bottom corner (or `/` on a keyboard) opens a filter that narrows
  the list as you type, every term matching like the navigator's `--exact`;
  closing it clears the query, so a filter is never left applied invisibly.
  While it is open the first match is highlighted, `Ctrl+h/j/k/l` move the
  highlight through the matches in grid order, and Enter opens it. Glyphs are the tmux
  status line's own: `!` needs input (red), `⠿` working (yellow), `●` done and
  unseen (green), `○` idle and seen (dim).
- **Pane view** (`/p/<id>`) — live frame over SSE with line-level patches (a
  scrolling pane sends the new bottom lines, not the screen). The header carries
  the back arrow, the agent's label and its glyph; diff, history, wrap/fit, mark
  seen, open-on-desktop and kill live in the overflow menu, so the frame and the
  composer get the whole screen. Extra keys (esc, ^C, tab, arrows, ^D, ^R,
  pg↑/↓) sit behind the ⌨ button next to send, along with raw-key mode for a
  real keyboard: Esc, Ctrl-C, Tab, arrows and Ctrl-<letter> go straight to the
  pane. If the pane exits (or is killed) while you are looking at it, the page
  returns to the inbox instead of staying on a dead screen.
- **Conversation view** (omp and opencode panes) — see [Native conversation view](#native-conversation-view).
  It is the default wherever the agent's session log can be found; the menu
  switches to *terminal: wrap text* / *terminal: fit to width* (`?view=wrap|fit`)
  and back (`?view=native`).
- **Diff** (`/p/<id>/diff`) — `git status` plus a per-file diff for the
  pane's worktree, rendered like a mobile code review: unified by default with
  old/new gutters, a sign column and red/green rows, and a *side-by-side*
  toggle in the menu for when the screen is wide enough. Git plumbing lines
  (`diff --git`, `index`, `---`, `+++`) are dropped, mode/rename/binary notices
  kept. `--no-ext-diff --no-textconv` are forced so a `diff.external`
  (difftastic) or textconv filter cannot replace the unified text the parser
  needs. A fully staged file shows its staged side instead of an empty table.
- **New session** (`/new`) — the directory field is backed by an index of the
  app's home directory, queried as you type and ranked by `fzf --filter` (fuzzy,
  path-aware), falling back to a substring match when fzf is absent. Pick a name
  and optionally `omp` / `opencode` (typed at the shell prompt so aliases and
  wrappers apply); it creates a detached session or a window in an existing one.
- **Seen / desktop** — viewing a pane on the phone marks it seen and keeps the
  desktop quiet while you watch (`@agent_watch_until`), and *desktop* hands the
  pane to the largest attached client.
- **Terminal** (`/term`) — a separate interactive login shell on a real PTY,
  with full-screen applications, font-size pinch zoom and a mobile key bar.

## Full terminal

The **term** navigation link opens the service account's login shell in its
home directory, not a tmux pane. On lio that is the primary user. It runs the
normal shell startup files, supports interactive programs such as Vim, and
does not resize existing desktop panes. Running `tmux attach` yourself inside
this shell is a normal tmux attachment and can resize those panes.

The browser uses [xterm.js 6](https://github.com/xtermjs/xterm.js), with its DOM
renderer and fit, web-links and Unicode 11 addons. The Go backend uses
[creack/pty](https://github.com/creack/pty) and
[coder/websocket](https://github.com/coder/websocket). Assets and their MIT
license are vendored in `internal/web/static` and embedded in the binary;
no CDN, Node runtime or separate ttyd process is needed. xterm.js was chosen
over the newer [ghostty-web](https://github.com/coder/ghostty-web) for its
established browser input handling and DOM text rendering.

The terminal bundles **JetBrainsMono Nerd Font Mono** (JetBrains Mono 2.304,
[Nerd Fonts 3.5.1](https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1)):
regular and bold WOFF2 faces with the full patched glyph set, including Font
Awesome, Devicons, Powerline and Material Design icons. Mono keeps glyphs in
one terminal cell. Both faces load before xterm measures its first grid, and
asset hashes keep the browser/service-worker cache current. No phone font
installation or CDN is required. Emoji still use the device's emoji font.

The WOFF2 assets total about 2.1 MiB and retain every source glyph. To update,
extract `JetBrainsMonoNerdFontMono-{Regular,Bold}.ttf` from the pinned release's
`JetBrainsMono.tar.xz` and run `woff2_compress` (Nix package `woff2`) on each;
do not subset away the icon ranges. The original SIL OFL, Nerd Fonts license
and upstream icon attribution table are in `static/jetbrains-mono-LICENSE.txt`.

- Pinch, trackpad Ctrl+wheel, or the menu's **larger/smaller text** changes the
  font size and PTY grid, rather than magnifying a fixed terminal bitmap.
  The font choice is saved in this browser.
- The horizontal key bar supplies Escape, Tab, arrows, navigation keys and
  one-shot Ctrl/Alt modifiers. Ctrl then C sends Ctrl-C; physical keyboard
  shortcuts and clipboard input use xterm's normal handling.
- The terminal follows the visual viewport so the mobile keyboard can shrink
  the available rows. Real-device Safari keyboard/IME behavior still needs
  device testing; Chromium touch/viewport emulation is not an iOS test.
- A shell survives disconnected browsers for **one hour** by default.
  Reconnecting continues from the last received byte; reloading replays the
  retained output. One session ID is stored per browser origin: another tab
  takes over that shell. **New shell** ends the current shell and starts fresh.
- Output replay retains roughly 512 KiB–1 MiB per shell. After overflow, old
  output is discarded and the screen resets to retained output; this is not
  a full terminal-state snapshot, so a full-screen app may need Ctrl-L to
  redraw. Shells do not survive a service restart. At most eight shells are
  kept; when full, the longest-detached shell is ended to make room.
- Historical replay suppresses terminal-query replies until xterm has parsed
  it, so old Vim queries cannot type escape-response garbage into the current
  shell. A reconnect carries its screen's attachment generation: after another
  tab used the shell, output delivered there is history even at a nonzero
  offset. The replay boundary survives a disconnect midway through redraw.
  Ordinary reconnects still answer missing live queries; output produced after
  the other tab disconnected remains live beyond its delivered boundary.
  Delivery means a successful socket write, not confirmation that the other
  browser displayed it, so takeover conservatively suppresses replies for
  that delivered prefix.

`--shell` / `TAM_SHELL` overrides the executable; otherwise `$SHELL`, the
account's passwd entry, then `/bin/sh` are tried. `--term-detach` /
`TAM_TERM_DETACH` sets the disconnect lifetime (for example `2h`). Nix modules
accept these through `extraEnvironment`:

```nix
services.tmux-agents-mobile.extraEnvironment.TAM_TERM_DETACH = "2h";
```

Login shells discard inherited Nix/Home Manager profile-initialization markers
before startup. This lets the profiles rebuild the full user `PATH` instead
of retaining systemd's restricted service path. In particular, Atuin's zsh
hook can find `atuin` when it runs its generated commands. After updating from
a build with the old environment, start a **new shell**; reconnecting does not
change an existing shell's environment.

**Access is a full shell as the service user**, including `sudo` under that
account's normal policy. The systemd units deliberately do not impose
inherited privilege/device/namespace restrictions. They retain `UMask=0077`,
so new files are private unless shell startup overrides it. The new-session
form's `roots` limit does not restrict this shell. Keep authentication and
tailnet exposure controls in place; all authorized users share the same OS
account.

## What it needs from tmux (and from the plugin)

The app drives stock tmux: `list-panes`, `capture-pane`, `send-keys`,
`load-buffer`/`paste-buffer`, `new-session`, and pane options. **No tmux
configuration changes and no patch to the plugin are required** - it works
against whatever tmux server is running, and it never attaches a client.

The tmux-agents plugin is optional and the app degrades in a defined way:

| | New plugin (`rows --json`) | Older plugin (before this work) | No plugin |
|---|---|---|---|
| Pane list | navigator tree, repo → session → panes | title detection + `git` lookups | title detection + `git` lookups |
| Shell-only sessions | session card | session card | session card |
| Agent glyphs | `@agent_state` from the tick | `@agent_state` from the tick | guessed from the title |
| Unseen marks | `@agent_unseen` | `@agent_unseen` | none |
| Watching suppresses desktop alerts | yes (`@agent_watch_until`) | no - the old tick ignores it | no |

The fallback is exercised by a test (`TestFallbackKeepsShellOnlySessions`), so
pointing this at a machine with the older plugin gives you the full pane list
and state, just without the worktree ordering the newer plugin adds.

## Plugin coupling (flakes/tmux-agents)

Two small additions, both backwards compatible:

1. `tmux-agents rows --json` — the same repo → session → agent tree the
   navigator renders, as JSON. The Go service groups and sorts; it does not
   re-implement worktree detection.
2. The tick honours `@agent_watch_until` (epoch seconds): while a phone has the
   pane open, the pane counts as seen, so no desktop notification or sound
   fires for it. The service sets the marker every 5 s while an SSE stream is
   open and clears it when the watcher idles out.

Without the plugin the service still runs: agent panes are found by terminal
title, with no repo grouping.

## Running it bare metal (dev)

```sh
cd flakes/tmux-agents-mobile
nix develop          # go, gopls, tmux, git, fzf
go test ./...
go run . --listen 127.0.0.1:8099 --no-auth
```

Point it at another tmux server with `--tmux-socket name` (`tmux -L name`). To
use the plugin from this checkout (the installed one only grows `rows --json`
once the flake is updated), point `--agents` at a wrapper — the script has no
exec bit:

```sh
printf '#!/bin/sh\nexec bash %s "$@"\n' "$PWD/../tmux-agents/tmux-agents.sh" > /tmp/tmux-agents-dev
chmod +x /tmp/tmux-agents-dev
go run . --no-auth --agents /tmp/tmux-agents-dev
```

Without `--agents` (or when the plugin is older than `rows --json`) the inbox
still works: sessions and agent panes are detected from pane titles, with repo
and branch filled in by git.

### Terminal takeover browser regression

`tests/terminal-takeover.mjs` uses real Chrome, xterm, WebSockets, a PTY and Vim.
It opens A, takes over in B, runs and quits Vim, then resumes A from its nonzero
offset. It checks that Vim received live replies, takeover-back sends no input,
and the next shell command executes correctly. It creates an isolated browser
context and ends its shell afterward. Node/Puppeteer are optional test tools,
not runtime or Nix-build dependencies.

Run against a disposable, unauthenticated loopback server (Vim on its PATH):

```sh
go run . --no-auth --listen 127.0.0.1:8199 --health-listen ''
# In separate terminals:
google-chrome-stable --headless=new --remote-debugging-port=9333 \
  --user-data-dir=/tmp/tam-test-chrome --no-first-run about:blank
npm install --prefix /tmp/tam-browser-test --ignore-scripts puppeteer-core
TAM_PUPPETEER_PREFIX=/tmp/tam-browser-test node tests/terminal-takeover.mjs
```

`TAM_URL` and `CHROME_CDP_URL` override the server and Chrome endpoints. Stop
both disposable processes after testing. The Go suite separately covers plain
reconnects, interrupted takeover replay, and still-unanswered detached output.


## Authentication is optional

Every route goes through Zitadel **when it is configured**, and the app refuses
to start without it unless you ask for the unauthenticated mode explicitly:

```sh
tmux-agents-mobile                     # needs TAM_ZITADEL_ISSUER + TAM_ZITADEL_CLIENT_ID
tmux-agents-mobile --no-auth           # loopback only: 127.0.0.1, ::1, localhost
tmux-agents-mobile --no-auth --listen 0.0.0.0:8099 --allow-nonloopback
```

`--no-auth` on a non-loopback address is refused unless `--allow-nonloopback`
is given too, so "exposed and unauthenticated" is always a deliberate,
two-flag mistake. The header of the UI shows a red **no auth** badge in that
mode so it is obvious which one you are looking at. `TAM_NO_AUTH=1` is the
same as `--no-auth` (the modules set it when `zitadel.clientId` is empty).
(`--dev-no-auth` and `--dev-allow-tailnet` still work as aliases.)

**Sign out** clears this app's session and shows a "signed out" page; it does not
bounce into the OIDC flow, because the identity provider's session usually
survives and would re-authenticate instantly (which reads as "nothing
happened"). Ending the Zitadel session as well needs a post-logout redirect URI
registered on the app - the end-session endpoint is not called.

## Tailnet node (optional, off by default)

`--tsnet-hostname` also serves the UI from **its own node** on a
Tailscale/Headscale tailnet, using `tailscale.com/tsnet` (userspace WireGuard
in the process: no tailscaled, TUN device or root, still `CGO_ENABLED=0`). The
phone reaches it from any network through the tailnet's DERP relay, which
only ever sees WireGuard ciphertext.

```sh
tmux-agents-mobile --no-auth \
  --tsnet-hostname tmux-mac \
  --tsnet-control-url https://headscale.example.com \
  --tsnet-authkey-file ~/.secrets/tam-authkey      # first login only
# then open http://tmux-mac/ (or http://tmux-mac.<magicdns domain>/) on the phone
```

- **Reaching the node is the authentication.** Requests on the tailnet
  listener skip Zitadel even when it is configured for `--listen`; the
  control server's ACLs decide which devices can connect. Its pages show the
  **no auth** badge and no sign-out.
- **Register it with a tagged pre-auth key** (`headscale preauthkeys create -u
  <user-id> --tags tag:lowtrust`). With an ACL that allows `user → tag:*` and
  has no rule from the tag, every device can open the node but the node cannot
  open a connection to anything (connection tracking still lets its replies
  through). That is the `tag:lowtrust` rule in `hosts/oracle/o002/headscale.nix`.
  It also lets *every* untagged device in, terminal included; narrow `dst` to
  a dedicated tag and port 80 if that is too wide.
- **DNS rebinding is refused.** A page on another site can resolve its own
  name to the node's IP and drive a tailnet browser at it; the listener only
  answers a `Host` that names the node (short name, MagicDNS name, tailnet
  IPs) and returns 421 otherwise.
- **Plain HTTP** on `--tsnet-listen` (default `:80`): WireGuard already
  encrypts the path, Headscale cannot issue certificates, and the PWA install
  is the only thing that needs a secure context.
- The node's keys live in `--tsnet-dir` (default
  `<user config dir>/tmux-agents-mobile/tsnet`); keep it, or the next start
  registers a new node with new IPs. Without an auth key the log prints a
  login URL.
- `--listen ''` turns the regular listener off, so the tailnet node is the only
  way in. With the regular listener on and no Zitadel, `--no-auth` and its
  loopback rule still apply to it.

The modules expose this as `tailnet.{enable,hostname,controlUrl,authKeyFile,stateDir,listen}`.

## Deployment

Three modules, the same options:

- `nixosModules.default` — the one to use on a NixOS host. It installs a
  **systemd user unit** (`ConditionUser` pins it to one account, because it must
  be the same user as the tmux server to reach `/tmp/tmux-<uid>/`). It does not
  touch nginx, the firewall or DNS: the host owns those, since the exposure is
  a property of the machine.
- `darwinModules.default` — the same service as a launchd user agent on macOS.
- `homeManagerModules.default` — a systemd user unit for a standalone
  home-manager profile (Linux).

Options worth knowing: `user` (required), `listen` (default
`127.0.0.1:8099`), `roots` (default `["~"]`, the trust boundary for the
new-session form), `sessionKeyFile`, `zitadel.{issuer,clientId,projectId,claim,role,redirectUri}`
and `tailnet.*` (see [Tailnet node](#tailnet-node-optional-off-by-default)).
The Zitadel client is public information, so it can live in the Nix config; a
session key file avoids logging every phone out on restart.

Set `zitadel.clientId` to gate it behind Zitadel (register
`http(s)://<host>/auth/callback` as the app's redirect URI). With it empty the
service runs **unauthenticated** and is then loopback-only - see
[Authentication is optional](#authentication-is-optional).

`auth.Wrap` covers the entire mux — pages, static assets, SSE, WebSocket
handshakes and every POST. The terminal additionally rejects cross-origin
browser handshakes. The only route served before the session check is
`/auth/*`. `/healthz` lives on its own loopback listener so the authenticated
mux needs no exception.

### The lio setup

`hosts/lio/tmux-mobile.nix` is the worked example: the service for the primary
user, an nginx vhost for `tmux.<domain>` using the wildcard certificate h005
pushes to lio (`fleet.wildcardTls`, with `:80` redirecting to it), and firewall
rules that open `:80`/`:443` on `tailscale0` only — no container route, no
public DNS. `hosts/h005/dns-records.nix` answers the name from the tailnet
dnsmasq with lio's overlay IP, so it resolves for tailnet clients and nowhere
else.

The host pins this package through its git flake input. After publishing a
change, update `tmux-agents-mobile` in `hosts/lio/flake.lock` and rebuild the
host to activate the new binary, unit settings and proxy configuration.

SSE needs buffering off and `/term/ws` needs WebSocket upgrades. The NixOS
vhost sets `proxyWebsockets = true` plus the streaming options below. For a
hand-written nginx configuration, define a connection map in `http` scope:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
```

and use these directives in the proxy location:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_buffering off;
proxy_read_timeout 1h;
```

The service sends `X-Accel-Buffering: no` on the event stream as well, so a
proxy that honours it needs no extra configuration.

### macOS (nix-darwin)

`darwinModules.default` installs the same service as a **launchd user agent**
(no systemd, no accumulation of a root daemon). On the Mac, a typical
`configuration.nix` snippet:

```nix
{
  imports = [ inputs.tmux-agents-mobile.darwinModules.default ];

  services.tmux-agents-mobile = {
    enable = true;
    user = "josh";
    listen = "127.0.0.1:8099";        # no auth, so loopback only
    extraEnvironment.TAM_SHELL = "/bin/zsh";
    # zitadel.clientId = "…";         # omit for the unauthenticated mode
  };
}
```

then `nix build .#darwinConfigurations.<host>.system` / `darwin-rebuild switch`
as usual. The package wraps `tmux`, `git` and `fzf` (and `procps` on Linux) into
its `PATH`, so the agent does not depend on the launchd environment having them.
Set `TAM_SHELL` explicitly on macOS: launchd may omit `$SHELL`, and normal
macOS users are not listed in `/etc/passwd`.

`homeManagerModules.default` is Linux-only (it writes a systemd user unit);
use `darwinModules` on macOS.
## Installable app (PWA)

The UI is a plain web app that Chrome/Safari can install to the home screen:
`/manifest.webmanifest` (served as `application/manifest+json`), 192/512 PNG and
SVG icons, `display: standalone`, plus `apple-touch-icon` and the
`apple-mobile-web-app-*` meta tags for iOS.

The service worker (`/sw.js`, served from the root so its scope covers the whole
app) only ever caches `/static/*`, and only responses that are genuine 200s and
were not redirected — with Zitadel in front, an expired session turns a static
request into a redirect to the login page, and caching that as `app.css` would
leave the phone with a broken stylesheet. The pane list, frames, SSE and every
POST always go to the network.

Installability needs a secure context, i.e. the https vhost (or localhost during
development).

## Live list

The pane list polls `GET /?fragment=cards` every 3 seconds and swaps the cards in
place, so panes appearing/exiting and state changes show up without a reload. It
pauses while the tab is hidden or a finger is down (swapping the DOM under a tap
would swallow it), skips the swap when the markup is byte-identical (the common
case), preserves scroll position, and re-applies an active filter to the new
cards. A response only counts when it carries `X-Fragment: cards`, so an expired
session or a missing tmux server cannot paste a login page into the list.

## Native conversation view

For omp and opencode panes the page renders the agent's own session instead of the
terminal: user messages as bubbles, assistant prose as Markdown (goldmark;
raw HTML in model output is shown as text, unsafe link schemes dropped),
thinking collapsed, and each tool call as a one-line row (status glyph, tool,
intent) that expands to the command/path, the output and, for edits, the diff.
Notices (`custom_message` with `display: true`: advisor, IRC, async results)
and compactions are collapsible rows; hidden entries are skipped.

Also pulled from the log:

- **Session title**: the `title` header line (rewritten in place by omp) and
  `title_change` entries replace the pane label in the header.
- **Todo card**: the latest `todo` tool result (or `user_todo_edit`) is pinned
  above the composer, collapsed to `done/total` and the current task; hidden
  once every task is closed.
- **Setting dividers**: `model_change` (main model only), `thinking_level_change`
  and `mode_change` after the first message become dashed dividers; repeats are
  dropped and adjacent changes merge.
- **Background agents**: `task`, `vibe_spawn` and `vibe_send` rows list the jobs
  they started (names from the result text), settled by `async-result`
  deliveries and `vibe_wait`/`hub` snapshots.

The **recap** ("※ recap: …", omp's idle summary) is not in the log: omp writes
it to `$PI_CODING_AGENT_DIR/history.db`, table `session_recaps`, keyed by the
session header's `id`. It is read read-only with the pure-Go
`modernc.org/sqlite` driver (still `CGO_ENABLED=0`), re-queried only when the
db or its `-wal` changes, and shown after the last item until the conversation
moves past it.

Finding the session (`internal/transcript/locate.go`, no plugin needed):

1. `pane_pid` → `ps -e` process tree, breadth-first, to the shallowest `omp`
   (sandbox wrappers like `nono` run it as a child, on its own pty).
2. A session JSONL the process holds open, else omp's breadcrumb
   `$PI_CODING_AGENT_DIR/terminal-sessions/<tty>` (line 2 is the session file),
   else a `--resume=<file>` argument.

Sessions are trees (re-sending a message branches); the view follows the newest
entry back to the root, which is what omp resumes into. One reader per pane
tails the file every 400ms and pushes rendered items over SSE
(`/p/<id>/chat/events`: `init`, `items`, `meta`, `recap`, `state`, `fallback`,
`gone`); a tool
result re-renders its call in place. The page loads the last 60 items and
*show earlier* fetches more (`/p/<id>/chat/earlier?before=N`). If no session
can be read (agent exited, not an agent), the page falls back to the terminal.
The composer and ⌨ keys still use tmux input, as in the terminal views.

Pending omp **`ask` prompts** open as native answer forms rather than collapsed
tool output: radio buttons for single choices, checkboxes for multiple choices,
and **Other…** with a multiline text box on every question. Multi-choice answers
can combine options and custom text, or select nothing. Recommendations are
badges, not preselected answers. **Submit all answers** sends the whole form;
transcript refreshes preserve selections, custom text, and focus. Completed or
cancelled asks return to read-only tool output.

Submission uses `POST /p/<id>/ask`, validates every answer against the live omp
call, and drives the existing rich terminal dialog without attaching or resizing
a tmux client. It checks the screen between keys, reconciles existing checkbox
selections, and confirms the tool result in the session log before reporting
success. Other mobile key input is refused while submission is in progress.
Do not type into the desktop dialog during submission: terminal input has no
atomic, cross-client transaction. Hidden dialogs, open editors, attached notes,
or unrecognised layouts require finishing/showing the dialog in the terminal;
errors leave the mobile draft intact. Existing custom answers that differ from
the mobile draft must be changed or cleared in the terminal first. The terminal
wrap/fit views and ⌨ keys remain available as the fallback.

### opencode

opencode panes get the same view from opencode's database
(`$XDG_DATA_HOME/opencode/opencode.db`, or `OPENCODE_DB`), opened read-only and
shared by every opencode pane. Each `session_message` row is one item: `user`,
`assistant` (reasoning, text and tool parts; the row is rewritten in place
while it streams, so changed rows are re-read by `time_updated`), described
`synthetic` notices (subagent results, restarts; plan-mode reminders are
skipped) and `compaction`. `model-switched`, `agent-switched` and
`location-switched` become dividers; the title comes from `session_v2.title`
(opencode's `New session - …` placeholder is ignored), the todo card from the
latest `todowrite` call, edit diffs from the tool's patch metadata, and
`subagent` calls list their child session, settled by the `<subagent>` result.
A staged undo (`session_v2.revert`) hides the reverted messages. There is no
recap.

The session is found like tmux-agents' `resume.sh`: the shallowest
`opencode` process under the pane, then the pane title `OC | <title>`
(truncated at 40 characters) matched against sessions under the process's
cwd, else its `-s/--session` argument. A pane on the home screen (title
`OpenCode`) with no session argument falls back to the terminal.

## Limits

- Full-screen TUIs are captured as text, so they reflow as prose. The *fit*
  toggle switches to fixed-width rows (`capture-pane -N`) when column alignment
  matters more than legibility.
- No mouse forwarding: mouse-only dialogs stay desktop-only.
- Scrollback is served in chunks (`capture-pane -S -N`), not copy-mode fidelity.
- Raw-key mode depends on the keyboard emitting proper `keydown` modifiers; the
  compose box covers everything else.

## Tuning the type size

Everything scales from `--term-size` in `internal/web/static/app.css` (the
terminal frame, default `18px`: a reading size for wrapped text) and `--ui-size`
(the chrome, `16px`). The *fit* toggle scales the frame down to whatever the
pane's column count needs, so a 384-column pane still fits on a phone screen,
just small — that is the point of the toggle. Leading is 1.2 for wrapped text and
1.0 in fit mode (whole screen, no gaps between rows); ligatures are off and the
font stack names the Android monospaces explicitly, since `ui-monospace` and the
Mac faces do not exist there.

The module is pinned to `go_1_27` through `buildGo127Module` (nixpkgs' default
`go` lags a release), and `go.mod` declares `go 1.27.0`, so `nix develop` and
`nix build` always agree on the toolchain.

## Directory picker

`/new/dirs?q=…` ranks directories from an in-memory index of the app's home
directory (built at startup, refreshed every minute, hidden dirs skipped except
`.config`/`.local`, heavy subtrees pruned). Ranking is `fzf --filter` with
`--scheme=path`; if fzf is not on `PATH` the server falls back to a substring
match, so the field still works. The form itself still validates the chosen
directory: `--roots` (default: the home directory) is the trust boundary the
web UI may create sessions under.


The frame streams line patches, and only rows that changed are rewritten. A
scroll shift or a change in the row count rebuilds the frame and restores the
scroll position, so dragging to read scrollback (or sideways in *fit* mode)
isn't interrupted by an agent that keeps printing.
