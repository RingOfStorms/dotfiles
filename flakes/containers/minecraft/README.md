# Minecraft Container

Managed via `extra-container`. Runs a Velocity proxy + 2 Paper servers inside
a single NixOS container (systemd-nspawn).

## Architecture

```
Players :25565 -> Velocity (proxy, auth, routing)
                    ├── survival :25566  (primary, unmodified Paper)
                    └── creative :25567  (secondary, for plugin experiments)
```

All three run inside the `minecraft` container. State persists at
`/var/lib/nixos-containers/minecraft/` on the host filesystem.

## Prerequisites

The host must have `extra-container` installed. Import the containers NixOS
module in your host flake:

```nix
inputs.containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers";
# ...
nixosModules = [ inputs.containers.nixosModules.default ];
```

## Deploy / Update

```bash
# From this directory on the host:
nix run . -- create --start

# Or from anywhere:
nix run path:/path/to/flakes/containers/minecraft -- create --start
```

Running `create --start` again after config changes will update the running
container in-place (via `switch-to-configuration` inside the container).

## Destroy

```bash
nix run . -- destroy
```

## Console Access

```bash
# Root shell inside the container
sudo nixos-container root-login minecraft

# Attach to a specific server's tmux console
# (inside the container):
tmux -S /run/minecraft/survival.sock attach
tmux -S /run/minecraft/creative.sock attach
tmux -S /run/minecraft/velocity.sock attach
# Detach: Ctrl+b then d
```

## Backup

All container state lives at `/var/lib/nixos-containers/minecraft/` on the host.

```bash
# Full backup
sudo tar -czf minecraft-backup-$(date +%F).tar.gz \
  /var/lib/nixos-containers/minecraft/srv/minecraft/

# Per-server backup (just survival world)
sudo tar -czf survival-$(date +%F).tar.gz \
  /var/lib/nixos-containers/minecraft/srv/minecraft/survival/
```

## Restore

```bash
# Stop container
nix run . -- destroy

# Restore from backup
sudo tar -xzf minecraft-backup-2026-04-16.tar.gz -C /

# Recreate container
nix run . -- create --start
```

## Data Locations (inside container)

| Path | Description |
|------|-------------|
| `/srv/minecraft/survival/` | Survival world data, server.properties, etc |
| `/srv/minecraft/creative/` | Creative world data, server.properties, etc |
| `/srv/minecraft/velocity/` | Velocity config, forwarding.secret |
| `/srv/minecraft/.mc-*/` | nix-minecraft managed symlinks |

## Ports

| Service | Port | Bind |
|---------|------|------|
| Velocity | 25565 | 0.0.0.0 (player-facing) |
| Survival | 25566 | 127.0.0.1 (backend only) |
| Creative | 25567 | 127.0.0.1 (backend only) |

## Moving to Another Host

1. Backup on current host (see above)
2. Ensure new host has `extra-container` installed (import containers module)
3. Open port 25565 in firewall on new host
4. Restore backup on new host
5. `nix run path:./flakes/containers/minecraft -- create --start` on new host
6. Destroy on old host

## Daily Restart

Servers auto-restart at 4 AM via systemd timer (configured in container.nix).
