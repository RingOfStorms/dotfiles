# hass — Home Assistant Yellow

The Home Assistant Yellow runs Home Assistant OS. It is not managed by Nix. This directory documents it and holds the oh-my-pi (`omp`) setup for an agent that helps configure and manage it.

## Access

| What | Where |
| --- | --- |
| Tailnet IP | `100.64.0.10` |
| Web UI | `http://100.64.0.10:8123` (also `http://hass.net.joshuabell.xyz:8123`) |
| Built-in MCP Server integration | `http://100.64.0.10:8123/api/mcp` (needs a long-lived access token) |
| HA-MCP add-on (HACS) | `http://100.64.0.10:9583/<secret-path>` (the secret path is shown in the add-on settings UI) |

Long-lived access tokens are created at `/profile/security` in the HA UI.

## omp agent

Run `omp` from this directory (`hosts/hass`). It automatically picks up:

- `.omp/skills/home-assistant-best-practices/`: a copy of the skill from
  [homeassistant-ai/skills](https://github.com/homeassistant-ai/skills), `skills/home-assistant-best-practices` (MIT; `evals/` left out). Last synced from upstream commit `68f2690` (2026-10-17).
- `.omp/mcp.json`: the MCP servers:
  - `hass`: the built-in HA MCP server. The `Authorization` header is produced by a `!` shell command that sources `.env.local`. This keeps working even if `omp` is not started from a direnv shell.
  - `ha-mcp`: the HA-MCP add-on at `${HA_MCP_URL}`.

### Secrets

Secrets live in `.env.local`, which git ignores via the global `*.local` rule. The `.envrc` here loads that file through direnv on top of the repo-root flake env. The file must exist before `omp` can connect:

```sh
cat > .env.local <<'EOF'
HASS_TOKEN=<long-lived access token>
HA_MCP_URL=http://100.64.0.10:9583/<secret-path>
EOF
chmod 600 .env.local
direnv allow
```

`hass` reads `.env.local` itself. `ha-mcp` uses `${HA_MCP_URL}` expansion, so it needs `omp` started from a direnv-loaded shell.

### Updating the skill

```sh
set -e
tmp=$(mktemp -d)
git clone --depth 1 https://github.com/homeassistant-ai/skills.git "$tmp"
rm -rf "$tmp/skills/home-assistant-best-practices/evals"
cp "$tmp/LICENSE" "$tmp/skills/home-assistant-best-practices/"
rm -rf .omp/skills/home-assistant-best-practices
cp -r "$tmp/skills/home-assistant-best-practices" .omp/skills/
git -C "$tmp" log -1 --format='%h %cs'   # update the commit noted above
rm -rf "$tmp"
```

## Installed extras

- HACS: the HA-MCP custom component / add-on
- Built-in **Model Context Protocol Server** integration (enabled)
