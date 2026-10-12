# arr: the h001 media stack as one container

nixarr (jellyfin, seerr, sonarr, radarr, prowlarr, bazarr, sabnzbd,
transmission in the `wg` VPN netns, shelfmark, audiobookshelf, recyclarr),
kavita and media-integrity in one nixos-kind container on h001.

```
cnt stop arr      # whole stack down (blocks), stays down across reboots and NAS recovery
cnt start arr     # whole stack up
cnt status arr
```

## Layout

- Guest config: `container.nix` imports the **same** `hosts/h001/mods`
  files the host used (nixarr.nix, kavita.nix, media-integrity.nix,
  hardware-transcoding.nix). Edit those; redeploy with `cnt deploy arr`.
- Guest nixpkgs 26.05 (`guestpkgs`); extra-container's host-side eval stays
  on 25.11 (issue #40).
- Host network: every port is unchanged (jellyfin 8096, seerr 5055, kavita
  5000, sonarr 8989, radarr 7878, prowlarr 9696, bazarr 6767, sabnzbd 6336,
  shelfmark 8087, audiobookshelf 9292, transmission 9091/51820 via the netns).
  The host keeps the vhosts: `hosts/h001/mods/arr-nginx.nix`.
- `privateUsers = "no"`: uids are host uids (NFS + h002 check raw uids).
  The uids/gids that own migrated state are pinned in `container.nix`.
- Binds: `/nfs/h002/nixarr/media` (rw), `/var/lib/secrets_manager_hydrated`
  (ro, the wg conf + api keys), `/run/netns`, `/dev/dri`, `/dev/net/tun`.
  Extra caps: NET_ADMIN, NET_RAW, SYS_ADMIN (VPN-Confinement builds the netns,
  bridge and nat rules in the shared host namespace).
- Persist (`/srv/containers/arr/<key>`, backed up by `cnt backup arr`):
  `nixarr` (`/var/lib/nixarr`, ~8 GB), `kavita`, `media-integrity`,
  `sabnzbd-secrets`, `recyclarr`, `nixos`.
- NAS guard: `fleet-guard-h002` on the host (`hosts/h001/floating-containers.nix`).
  h002 unreachable or its sentinel missing -> `container@arr` stops within
  ~40 s. When h002 is back, the guard starts `arr` again unless it was
  `cnt stop`ped (hold marker / boot link).

## Cutover runbook (h001, once)

0. On h002, once: `touch /data/.h002-online` (shows up as
   `/nfs/h002/.h002-online`). Without it the guard keeps `arr` down.
1. Rebuild h001 with the guard but still the host modules
   (`inContainer = false`). Check: `systemctl status fleet-guard-h002` is
   active, "storage ok".
2. Stop the host stack and keep it from restarting:
   ```
   systemctl stop media-integrity-scan.timer recyclarr.timer
   systemctl stop jellyfin seerr sonarr radarr prowlarr bazarr sabnzbd \
     transmission shelfmark audiobookshelf kavita media-integrity-scan wg
   ```
   (`systemctl list-units | grep -E 'arr|jelly|seerr|sabnzbd|transmission|shelf|audiobook|kavita|wg'`
   must show nothing active.)
3. Copy state, keeping numeric owners and modes:
   ```
   for k in nixarr kavita media-integrity sabnzbd-secrets recyclarr; do
     install -d -m755 /srv/containers/arr/$k
     cp -a /var/lib/$k/. /srv/containers/arr/$k/   # -a keeps numeric owners, modes, times
   done
   install -d -m755 /srv/containers/arr/nixos
   ```
   Leave the originals in place until the container is verified (rollback).
4. Set `inContainer = true` in `hosts/h001/_constants.nix`, rebuild h001
   (host modules gone, vhosts from arr-nginx.nix, `wg` netns left by the
   old `wg.service` is removed on stop; check `ip netns` shows no `wg`).
5. `cnt deploy arr`, then check: `machinectl shell arr`, `systemctl
   --failed` inside; `ip netns exec wg curl -s ifconfig.me` on the host
   shows the VPN exit; jellyfin/seerr/books vhosts load; `vainfo` inside.
   If the VPN netns can't be built from inside (caps), fall back to
   `privateNetwork = true` with a 10.0.0.x address and repoint nginx.
6. Guard test: on h001
   ```
   nft add table inet t; nft add chain inet t o '{type filter hook output priority 0;}'
   nft add rule inet t o ip daddr 10.12.14.183 drop
   ```
   `journalctl -fu fleet-guard-h002`: fails within ~40 s, `container@arr`
   stops. `nft delete table inet t`: guard back within ~60 s + probe, arr
   starts. Repeat with the sentinel renamed on h002.
7. Stop test: `cnt stop arr`, blackhole + unblock as above: arr must stay
   down. `cnt start arr` brings it back.
8. After a week of good runs: remove `/var/lib/{nixarr,kavita,media-integrity,sabnzbd-secrets,recyclarr}`
   on the host and the sec-agent `configChanges.nixarr.vpn.wgConf` line
   in `hosts/h001/sec-agent.nix` (the file itself must stay; it's bound in).

Rollback: `cnt stop arr`, set `inContainer = false`, rebuild (the old
`/var/lib` state is untouched).
