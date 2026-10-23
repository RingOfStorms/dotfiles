# arr: the h001 media stack as one container

nixarr (jellyfin, seerr, sonarr, radarr, prowlarr, bazarr, sabnzbd,
shelfmark, recyclarr),
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
- Private network (`net.index = 16`, 10.233.16.2). Every UI is a route in
  `service.nix`: jellyfin/media public, books/shelfmark and the *arr UIs
  (sonarr, radarr, prowlarr, bazarr, sabnzbd) tailnet, no
  LAN; jellyfin `:8096` direct is a tailnet tcp route. No VPN, no torrents
  (transmission and VPN-Confinement were removed; usenet only).
  `hosts/h001/mods/arr-nginx.nix` keeps only `/media-health/`.
- `privateUsers = "identity"`: uids are host uids 1:1 (NFS + h004 check raw
  uids), but guest root is not host root.
  The uids/gids that own migrated state are pinned in `container.nix`.
- Binds: `/nfs/h002/nixarr/media` (rw), `/var/lib/secrets_manager_hydrated`
  (ro, the api keys), `/dev/dri`.
  Extra caps: NET_ADMIN only (the guest firewall loads `arr-lo-guard`,
  `hardening.nix`).
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
Also with the sentinel renamed on h004 (`mv /data/nixarr/.h004-online{,.x}`), and
after `cnt stop arr` (arr must stay down through the cycle).

The cutover from bare-metal h001 was done 2026-10-12 (git history has the
runbook).