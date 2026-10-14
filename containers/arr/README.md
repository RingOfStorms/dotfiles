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

- Guest config: `container.nix` + `nixarr.nix`, `kavita.nix`,
  `media-integrity.nix` in this directory (they moved here from
  `hosts/h001/mods`; h001 no longer has nixarr at all). It also imports
  `hosts/h001/mods/hardware-transcoding.nix`, shared with the host.
  Edit, push, then `cnt deploy arr` (it builds this directory from the repo;
  no h001 rebuild needed).
- Guest nixpkgs 26.05 (`guestpkgs`); extra-container's host-side eval stays
  on 25.11 (issue #40).
- Host network: every port is unchanged (jellyfin 8096, seerr 5055, kavita
  5000, sonarr 8989, radarr 7878, prowlarr 9696, bazarr 6767, sabnzbd 6336,
  shelfmark 8087, audiobookshelf 9292, transmission 9091/51820 via the netns).
  The host keeps the vhosts: `hosts/h001/mods/arr-nginx.nix`.
- `privateUsers = "no"`: uids are host uids (NFS + h004 check raw uids).
  The uids/gids that own migrated state are pinned in `container.nix`.
- Binds: `/nfs/h002/nixarr/media` (rw), `/var/lib/secrets_manager_hydrated`
  (ro, the wg conf + api keys), `/run/netns`, `/dev/dri`, `/dev/net/tun`.
  Extra caps: NET_ADMIN, NET_RAW, SYS_ADMIN (VPN-Confinement builds the netns,
  bridge and nat rules in the shared host namespace).
- Persist (`/srv/containers/arr/<key>`, backed up by `cnt backup arr`):
  `nixarr` (`/var/lib/nixarr`, ~8 GB), `kavita`, `media-integrity`,
  `sabnzbd-secrets`, `recyclarr`, `nixos`.
- NAS guard: `fleet-guard-h004` on the host (`hosts/h001/floating-containers.nix`).
  When h004 is unreachable or its sentinel is missing, the guard starts
  stopping `container@arr`, and it starts `arr` again when h004 is back
  unless it was `cnt stop`ped (hold marker / boot link). Measured on
  h001 (2026-10):
  - sentinel missing (NFS still up): stop starts in ~2 s, fully down ~16 s later;
  - h004 blackholed: stop starts in ~14 s, but services hang on the dead
    NFS mount, so systemd SIGKILLs after its stop timeout: fully down ~100 s;
  - recovery: `arr` running again 60-90 s after h004 is back.

  Detection is not shutdown. For NAS maintenance, `cnt stop arr` first (it
  blocks until fully down), do the h004 work, and `cnt start arr` once it is
  back.

## Guard test (h001)

```
nft add table inet t; nft add chain inet t o '{type filter hook output priority 0;}'
nft add rule inet t o ip daddr 10.12.14.184 drop   # arr goes down (up to ~100 s)
nft delete table inet t                            # arr back within ~90 s
```
Also with the sentinel renamed on h004 (`mv /data/.h004-online{,.x}`), and
after `cnt stop arr` (arr must stay down through the cycle).

The cutover from bare-metal h001 was done 2026-10-12 (git history has the
runbook).