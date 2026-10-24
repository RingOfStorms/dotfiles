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

## Backups

Configured in Settings → System → Backups:

- Automatic **daily at 03:45**. Includes all add-ons, the database, and the `media` + `share` folders.
- Retention: **keep the last 7 automatic backups**. Pruning runs after each new automatic backup. Manual and add-on-update backups are not pruned; delete those by hand.
- Encrypted. The key (`XXXX-XXXX-…` format) is in the password manager. Without it, no backup can be restored.
- Stored **only on the Yellow** (`hassio.local`). Copy one off occasionally with the steps below.

### Copy the latest backup off the Yellow (manual)

Uses the **Terminal & SSH** add-on (`core_ssh`) with password login. The password for `root` is in the password manager. `ssh root@hass` works from the tailnet. Backups are `.tar` files in `/backup` on the Yellow.

Don't just grab the newest file. Add-on updates create small add-on-only backups (e.g. "Tailscale 0.30.1") that don't contain HA config. Pick the newest backup whose metadata includes Home Assistant, then copy that one.

```sh
HASS=root@hass
DEST=~/backups/hass && mkdir -p "$DEST"
# reuse one connection so the password is asked once
SSHOPT=(-o ControlMaster=auto -o ControlPath=/tmp/hass-ssh-%C -o ControlPersist=5m)

# list backups (newest first); "ha": true = contains Home Assistant config
ssh "${SSHOPT[@]}" "$HASS" \
  "ha backups list --raw-json | jq -r '.data.backups | sort_by(.date) | reverse[] | \"\(.slug)  \(.date[:16])  ha=\(.content.homeassistant)  \(.size)MB  \(.name)\"'"

# slug of the newest backup that includes Home Assistant
slug=$(ssh "${SSHOPT[@]}" "$HASS" \
  "ha backups list --raw-json | jq -r '[.data.backups[] | select(.content.homeassistant)] | sort_by(.date) | last | .slug'")
echo "slug: $slug"

# find the .tar whose embedded backup.json has that slug (file names are not the slug)
file=$(ssh "${SSHOPT[@]}" "$HASS" \
  "for f in /backup/*.tar; do [ \"\$(tar -xOf \"\$f\" ./backup.json 2>/dev/null | jq -r .slug)\" = $slug ] && echo \"\$f\" && break; done")
echo "file: $file"

scp "${SSHOPT[@]}" "$HASS:$file" "$DEST/${slug}_$(basename "$file")"
ls -lh "$DEST"
```

If `file` comes back empty, check the listing and pick the file by hand with `ssh root@hass ls -l /backup`.

Each backup is about 7 GB. Restore by uploading the `.tar` during onboarding or under Settings → System → Backups, and enter the encryption key.

## Installed extras

- HACS: the HA-MCP custom component / add-on
- Built-in **Model Context Protocol Server** integration (enabled)
- **Fleet Agent** (`local_fleet_agent`, in `./fleet-agent/`): local Home Assistant OS app serving `/status.json` and `/logs.json` on `:9101` (for `fleet-edge` on `h005`). Includes NVMe SMART telemetry (`/dev/nvme0`), `/data` disk usage, CPU/RAM/network/disk I/O, thermal sensors, and Supervisor add-on/core/host status + logs. Rebuild and deploy after changes to `flakes/fleet-agent` with `./fleet-agent/deploy.sh`.
