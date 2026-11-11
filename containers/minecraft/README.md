# Minecraft

> **Running on h003 since 2026-11-11**, restored from
> `/home/luser/backups/minecraft-h003-2026-10-15T2001.tar.zst` on h001 (the
> data as stopped on 2026-10-09). Nightly backups go to h004 (`svc-minecraft`).
> No hairpin NAT on h005: from the home LAN, `home.joshuabell.xyz:25565` (the
> WAN IP) does not connect; use `10.12.14.180:25565` (h003) there.

Velocity proxy and two Paper servers, run as a `nixos`-kind floating container
(see `../README.md`).

```
Players :25565 -> h005 WAN DNAT -> host LAN IP :25565 -> host DNAT -> guest
                  10.233.18.2:25565: Velocity (proxy, auth, routing)
                    ├── survival :25566  (guest 127.0.0.1, primary, Paper)
                    └── creative :25567  (guest 127.0.0.1, plugin experiments)
squaremap :8080  <- host nginx (https://computerboyz.joshuabell.xyz/, edge listener)
                 <- o002 terminates TLS and proxies over the tailnet
PostgreSQL 17 (guest 127.0.0.1:5432, trust): LuckPerms, shared by all three
```

Private network (`net.index = 18`): the guest is `10.233.18.2` on every host,
and its firewall admits only 25565 and 8080. The `game` route is a public
`via = router` tcp route: fleet-edge on h005 forwards WAN :25565 to the placed
host's LAN IP, and that host's ports file line `tcp 25565 dnat 10.233.18.2`
DNATs it to the guest (any interface, so LAN and tailnet clients reach it
too). 8080 is reached through the vhost `cnt deploy` generates from the `web`
route, which proxies to `10.233.18.2:8080`. Postgres and the Paper backends
are on the guest's own loopback, unreachable from the host.

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
containers ls                         # bound host, where it runs, state
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
sudo fleet containers move minecraft --to h001
```

The move commits the new host to the placement registry; DNS, the o002
`computerboyz` vhost and the WAN forward for 25565 follow it on fleet-edge's
next reconcile pass. See `../README.md` for details.

