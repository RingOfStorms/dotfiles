# tmux-agents-mobile

A phone-sized view of the agent panes on one machine's tmux server, for
checking in: see what is waiting on you, read the last screen, answer it, peek
at a diff, start a session.

It **never attaches a tmux client**. It reads `capture-pane`, re-renders the
text at phone width and writes back with `send-keys`. That is the whole design:

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
  button in the bottom corner opens a filter that narrows the list as you type,
  every term matching like the navigator's `--exact`; closing it clears the
  query, so a filter is never left applied invisibly. Glyphs are the tmux
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
mode so it is obvious which one you are looking at. (`--dev-no-auth` and
`--dev-allow-tailnet` still work as aliases.)

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
new-session form), `sessionKeyFile` and `zitadel.{issuer,clientId,projectId,claim,role,redirectUri}`.
The Zitadel client is public information, so it can live in the Nix config; a
session key file avoids logging every phone out on restart.

Set `zitadel.clientId` to gate it behind Zitadel (register
`http(s)://<host>/auth/callback` as the app's redirect URI). With it empty the
service runs **unauthenticated** and is then loopback-only - see
[Authentication is optional](#authentication-is-optional).

`auth.Wrap` covers the entire mux — pages, static assets, SSE and every POST.
The only route served before the session check is `/auth/*`. `/healthz` lives on
its own loopback listener so the authenticated mux needs no exception.

### The lio setup

`hosts/lio/tmux-mobile.nix` is the worked example: the service for the primary
user, an nginx vhost for `tmux.<domain>` using the wildcard certificate h005
pushes to lio (`fleet.wildcardTls`, with `:80` redirecting to it), and firewall
rules that open `:80`/`:443` on `tailscale0` only — no container route, no
public DNS. `hosts/h005/dns-records.nix` answers the name from the tailnet
dnsmasq with lio's overlay IP, so it resolves for tailnet clients and nowhere
else.

SSE needs buffering off, which the vhost sets:

```nginx
proxy_http_version 1.1;
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
    # zitadel.clientId = "…";         # omit for the unauthenticated mode
  };
}
```

then `nix build .#darwinConfigurations.<host>.system` / `darwin-rebuild switch`
as usual. The package wraps `tmux`, `git` and `fzf` into its `PATH`, so the
agent does not depend on the launchd environment having them.

`homeManagerModules.default` is Linux-only (it writes a systemd user unit);
use `darwinModules` on macOS.
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
terminal frame, default `22px`) and `--ui-size` (the chrome, `16px`). The *fit*
toggle scales the frame down to whatever the pane's column count needs, so a
384-column pane still fits on a phone screen, just small — that is the point of
the toggle.

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

