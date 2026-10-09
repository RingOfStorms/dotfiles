# Minecraft

Velocity proxy and two Paper servers, run as a `nixos`-kind floating container
(see `../README.md`). Declared host: **h003** (`service.nix`).

```
Players :25565 -> Velocity (proxy, auth, routing)
                    ├── survival :25566  (127.0.0.1, primary, Paper)
                    └── creative :25567  (127.0.0.1, plugin experiments)
squaremap :8080  -> host nginx (computerboyz.joshuabell.xyz/map/survival/, overlay IP)
                 <- o002 terminates TLS and proxies over tailscale
PostgreSQL 17 (127.0.0.1:5432, trust): LuckPerms, shared by all three
```

The container shares the host network. The host opens only 25565, at runtime
(`tcpPorts`). 8080 is reached through the host nginx site in `service.nix`.

## Data

Ephemeral root. These survive, on the host under `/srv/containers/minecraft/`:

| host dir      | in container                 | contents |
|---------------|------------------------------|----------|
| `srv/`        | `/srv/minecraft`             | worlds, plugin data, velocity/survival/creative dirs |
| `secrets/`    | `/var/lib/minecraft-secrets` | velocity forwarding secret (generated on first boot) |
| `postgresql/` | `/var/lib/postgresql`        | `17/` cluster + `dumpall.sql` from the backup hook |
| `nixos/`      | `/var/lib/nixos`             | UID/GID map, keeps file owners stable |

File owners in these dirs are container UIDs (idmapped). Don't chown them.

## Everyday

```sh
containers ls                         # where it runs, state
containers logs minecraft             # follow the container journal
containers attach minecraft           # tmux session `mc`: velocity / survival / creative
                                 # (Ctrl-b d to detach; on h003 also: mc-attach)
containers deploy minecraft           # update to the latest pushed config
containers stop minecraft             # blocking stop (saves worlds, stops postgres)
containers restart minecraft
```

Servers restart daily at 04:00 (timer inside the container).

## Backup / restore

```sh
containers backup minecraft           # pg_dumpall, stop, tar to ./minecraft-h003-<date>.tar.zst, start
containers restore minecraft <file> --host h003 --force
containers deploy minecraft
```

To restore only the database from the dump: `containers shell minecraft`, then
`runuser -u postgres -- psql -f /var/lib/postgresql/dumpall.sql`.

## Move hosts

```sh
containers check-idmap h001
containers move minecraft --to h001
```

Then:

- set `host = "h001";` in `service.nix` and push;
- point `computerboyz` in `hosts/oracle/o002/nginx.nix` at the new host's
  overlay IP and rebuild o002;
- move the WAN port-forward for 25565 to the new host. Today h003 is the
  router and the public IP, so for any other host add
  `nat.forwardPorts` on h003.

See `../README.md` for details.

## One-time migration from the old (stateful) container

The old container kept everything in `/var/lib/nixos-containers/minecraft`
and shared host UIDs (`privateUsers = "no"`). Those UIDs are the guest's own
numbers, so copied with numeric owners they are already right for the idmap.
`var/lib/nixos` comes along so the guest keeps the same UID map.

On **h003**, after the host has the new module (push, `nix flake update
containers` in `hosts/h003`, rebuild):

```sh
# 0. Check idmap works here
containers check-idmap h003           # from any machine; or the script in ../README.md

# 1. Make sure it's stopped (blocking) and take a full backup of the old root
sudo systemctl stop container@minecraft
sudo tar --numeric-owner --xattrs --acls -czf ~/mc-pre-migration-$(date +%F).tar.gz \
  -C /var/lib/nixos-containers minecraft

# 2. Copy the data into the new layout
old=/var/lib/nixos-containers/minecraft
new=/srv/containers/minecraft
sudo mkdir -p $new/{srv,secrets,postgresql,nixos}
sudo rsync -aHAX --numeric-ids $old/srv/minecraft/            $new/srv/
sudo rsync -aHAX --numeric-ids $old/var/lib/minecraft-secrets/ $new/secrets/
sudo rsync -aHAX --numeric-ids $old/var/lib/postgresql/        $new/postgresql/
sudo rsync -aHAX --numeric-ids $old/var/lib/nixos/             $new/nixos/
sudo ls -ln $new/srv $new/postgresql/17 | head   # owners: minecraft uid, postgres 71

# 3. Remove the old container (its data is in the backup and the copy)
sudo extra-container destroy minecraft

# 4. Deploy the new one (from any machine)
containers deploy minecraft
containers logs minecraft             # wait for "Done" from survival/creative
```

Verify: connect a client to the public address on 25565; open
`https://computerboyz.joshuabell.xyz/map/survival/`; `/lp info` in game works
(LuckPerms ↔ postgres).

If it fails: `containers stop minecraft`, read `containers logs minecraft --unit`. The
old state is in `~/mc-pre-migration-*.tar.gz`.
