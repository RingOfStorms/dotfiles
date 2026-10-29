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
nix develop          # go, gopls, tmux, git
go test ./...
go run . --listen 127.0.0.1:8099 --dev-no-auth
```

`--dev-no-auth` is refused unless the listen address is loopback. Testing from
the phone before the real deployment needs a second, explicit flag:

```sh
go run . --listen 100.64.0.1:8099 --dev-no-auth --dev-allow-tailnet
```

and a temporary firewall rule for that address. The startup log prints a loud
`AUTHENTICATION DISABLED` warning whenever this is on.

Point it at another server with `--tmux-socket name` (`tmux -L name`). To use the
plugin from this checkout (the installed one only grows `rows --json` once the
flake is updated), point `--agents` at a wrapper — the script has no exec bit:

```sh
printf '#!/bin/sh\nexec bash %s "$@"\n' "$PWD/../tmux-agents/tmux-agents.sh" > /tmp/tmux-agents-dev
chmod +x /tmp/tmux-agents-dev
go run . --dev-no-auth --agents /tmp/tmux-agents-dev
```

Without `--agents` (or when the plugin is missing) the inbox still works, using
terminal-title detection instead of the repo tree.

## Deployment

`homeManagerModules.default` installs a **user** service (it must be the same
user as the tmux server for socket access). The Zitadel client is configured
through the environment, not the Nix store:

```
TAM_ZITADEL_ISSUER=https://sso.joshuabell.xyz
TAM_ZITADEL_PROJECT_ID=…
TAM_ZITADEL_CLIENT_ID=…            # PKCE app, redirect = …/auth/callback
TAM_ZITADEL_CLAIM=flatRolesClaim
TAM_ZITADEL_ROLE=                  # empty: any authenticated project member
TAM_SESSION_KEY_FILE=/run/…
```

`auth.Wrap` covers the entire mux — pages, static assets, SSE and every POST.
The only route served before the session check is `/auth/*`. `/healthz` lives on
its own loopback listener so the authenticated mux needs no exception.

nginx terminates the tailnet vhost (plain HTTP over the overlay, matching
fleet-edge) and proxies to `127.0.0.1:8099`. SSE needs buffering off:

```nginx
location / {
  proxy_pass http://127.0.0.1:8099;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_buffering off;          # SSE
  proxy_read_timeout 1h;
}
```

The service sets `X-Accel-Buffering: no` on the event stream as well, so a
proxy that honours it needs no extra configuration.

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
