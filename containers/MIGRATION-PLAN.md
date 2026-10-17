# Self-hosted services: migration plan to floating containers

Living plan for moving the fleet's self-hosted services into the
floating-container system in this directory (`containers` CLI, `cnt`). Written
2026-10 from a read-only audit of `hosts/*`; re-verify a service's module
before migrating it (things drift).

Status legend: **Keep** · **Deprecate** (stop running, archive data) ·
**Decide** (owner to confirm usage) · **Host-bound** (infrastructure, stays a
host module, never floats).

## 1. Where things stand

- Floating today: `arr` (h001, **live since 2026-10-12**: whole media stack,
  NAS-guarded), `opengist`, `atuin`, `vaultwarden` (h001, 2026-10-12),
  `trilium` (+ oauth2-proxy), `searx`, `litellm`, `open-webui`, `puzzles`,
  `life`, `forgejo`, `dawarich`, `immich`, `paperless`, `beszel` (h001, 2026-10-13), `localai` (joe), test twins
  `hello-nixos` / `hello-podman` (lio). Old host modules and `/var/lib` data
  of every migrated service are deleted (backups in `h001:/home/luser/backups`).
- Not running: `minecraft` (inactive since 2026-10-15, backup on h001; its
  public path needs the router forward from ROUTING-PLAN).
- sec and zitadel run as floating containers on h001 since 2026-10-17
  (runbook: `containers/sec/README.md`). Still outside `cnt`: host plumbing. Each host's readme lists its bare-metal services.
- CLI: `deploy`, `stop` (persists across reboot), `start`, `move`, `backup`
  (asks dir + before stopping), `restore`, `status <svc>`, `ls`, local mode.
  Registered container hosts: h001, h003, lio (+ any host a
  `service.nix` declares, e.g. joe). Unreachable hosts don't block work on a
  service running on its declared host.
- Hosts with the host module: h003, lio (lio has `nginx.enable` since `3a615a9`),
  joe, h001 (h001: storage guard `h004` + capabilities `nfs-h004`, `intel-qsv`, `wd10`).
- Remote root work logs in as `root@host` when its keys work (h001, h003,
  joe), else falls back to the fleet user + `sudo` (lio today: no root key,
  so `sudo -n` without a tty still fails there).

## 2. Hosts and roles

| Host | Hardware | Role, now → target |
|---|---|---|
| h001 | Dell OptiPlex 7090, i5-11500, 64 GB, **Intel UHD 750 iGPU (QSV)**, /drives/wd10, NFS client of h004 | Main service host → stays home of media/*arr + big-data services |
| h004 | NAS: Core Ultra 5 250K+, 32 GB, iGPU (QSV), NVMe root, bcachefs `/data` | NFS server, host-bound (successor of the retired h002, same pool; `hosts/h004/readme.md`) |
| h005 | MeLE Quieter DL, N150, 8 GB | Router since 2026-10-15 (dnsmasq, AdGuard, DDNS, NUT, speedtest); the only host meant to run bare-metal services. Planned: `fleet-edge`, oauth2-proxy |
| o002 | Oracle Ampere A1, **aarch64**, 2 OCPU/12 GB, impermanent root | Public TLS edge + headscale, host-bound |
| joe | Desktop, NVIDIA RTX 3080 10 GB | GPU AI services (podman) |
| lio | Desktop, AMD RX 7900 GRE | nix-serve cache, builder; floating-capable (test target) |
| gp3, juni, oren, i001, testbed, jflip | laptops/kiosk/VM/phone | No floating services |

No host has a *dedicated* media GPU; h001's Intel QSV is the best-supported
Jellyfin path (QSV + tone mapping). h003's AMD iGPU can VAAPI-transcode too,
so it is a viable fallback, not a primary.

## 3. Service decisions

"Ideal host" assumes the end state (h005 = router, h004 = NAS, h003 = second service host).

### Media / *arr — one nixos container `arr` on h001 — **DONE (2026-10-12)**

Live in `containers/arr`; h001 no longer has nixarr. Verified: all services
up, VPN exit, QSV, host vhosts + 9091 proxy, reboot, guard (blackhole and
sentinel) and `cnt stop` persistence. Old `/var/lib` state deleted. The
notes below are kept as the design record.

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| jellyfin | Keep | h001 | Intel QSV (`hardware-transcoding.nix`), NFS media. Kept outside the VPN netns on purpose (metadata lookups). |
| seerr (jellyseerr) | Keep | h001 | Request UI for jellyfin. |
| sonarr, radarr, prowlarr, bazarr | Keep | h001 | Need NFS media + shared uids mirrored on h004. |
| sabnzbd, transmission | Keep | h001 | Inside the WireGuard VPN netns (wg conf from sec-agent). |
| shelfmark, audiobookshelf | Keep (in `arr`) | h001 | Book pipeline; keep if still reading/listening. |
| kavita | Keep (in `arr`) | h001 | Reads the NFS book library. |
| recyclarr | Keep | h001 | Stateless config sync for sonarr/radarr. |
| media-integrity | Keep | h001 | Weekly ffmpeg scan of NFS movies; goes wherever media is mounted. |

Migration stance: **one nixos-kind container, `containers/arr`** (all rows
above), so `cnt stop arr` / `cnt start arr` take the whole stack down/up and
the NAS guard protects a single unit. Host network, `privateUsers = "no"`
(NFS + host-uid state), `requires = [ "nfs-h004" "intel-qsv" ]`, guest on
nixpkgs 26.05, VPN netns built by the guest in the host namespace. The
nixarr, kavita and media-integrity modules live in `containers/arr`; the
host keeps the vhosts (`mods/arr-nginx.nix`). Cut over 2026-10-12; see
`containers/arr/README.md`.

#### NAS guard: the whole media stack goes down when h004 does (required)

Goal: while h004 is unreachable (outages, the planned NAS upgrade) nothing
in the media stack runs. No downloads, no imports, no writes to a local
folder that only *looks* like the share. When h004 is back and verified,
everything starts again by itself.

**Guard unit on the h001 host**, implemented generically as the host-module
option `ringofstorms.containers.guards.<name>` (`fleet-guard-<name>.service`;
h001 config: `hosts/h001/floating-containers.nix`). The design below is what
it does; with the stack in `arr` it protects one unit, `container@arr`:

- `fleet-guard-h004.service`: `Type=notify`, `Restart=always`,
  `RestartSec=60`. Runs the probe once and calls `systemd-notify --ready`
  only after it passes, then re-probes every 30 s and exits non-zero on the
  first failure.
- **Probe**: (a) the media path is really an NFS mount
  (`stat -f -c %T` reports `nfs`), and (b) a sentinel file that exists only
  on h004's `/data` is present: `/data/.h004-online`, created once with
  `sudo touch` on h004. Because the export is `fsid=0`, it shows up on h001
  as `/nfs/h002/.h004-online`. (b) catches an empty local folder on h001
  *and* h004's root disk being exported because `/data` didn't mount.
- **Probe must be hard-bounded.** On a hard NFS mount, `timeout 10 stat`
  only sends SIGTERM, and a process stuck in an NFS wait can ignore it, so
  the guard itself would hang "healthy" while dependents keep running. Run
  each probe as a separate child with `timeout -k 2 10` (SIGKILL after
  SIGTERM). The guard treats "probe didn't finish in time" as a failure,
  not as a wait. As a backstop, set `WatchdogSec=` with `systemd-notify
  WATCHDOG=1` sent only after a successful probe, so systemd kills the
  guard if the loop ever wedges.
- **Test before relying on it**: blackhole h004 from h001
  (`nft add rule inet filter output ip daddr 10.12.14.184 drop`, h004 now serves the NAS, temporarily)
  and confirm that the guard fails within about 40 s and all dependents
  stop. Then remove the rule and confirm they come back. Also test with
  h004 up but `/data` unmounted (sentinel missing).

**Wiring:**

- Every protected unit gets `bindsTo` + `after` = `fleet-guard-h004.service`.
  When the guard stops, systemd starts stopping them at once (fully down
  takes ~16 s with NFS up, ~100 s with h004 unreachable, because services
  hang on the dead mount until SIGKILL), and they can't start while
  it's down (after a reboot or `nixos-rebuild switch` too).
- Restart on recovery **must respect desired state**. Plain `Upholds=`
  restarts any inactive listed unit whenever the guard is active, so it
  would undo a deliberate `systemctl stop`, a `cnt stop` (which only
  removes the boot link, then stops), and the stop inside `cnt backup` /
  `cnt move`. So instead of `Upholds=`, the guard itself starts dependents
  after each passing probe, but only those that are (a) enabled / have
  their boot link and (b) not held: a hold marker
  (`/run/fleet-containers/hold/<svc>`) that `cnt stop`, `backup` and `move`
  write before stopping and remove after. Manual stops of host-module units
  use `systemctl disable --now` or the same marker. Only long-running
  daemons are started this way: jellyfin, seerr, sonarr, radarr, prowlarr,
  bazarr, sabnzbd, transmission, shelfmark, audiobookshelf.
- **Scheduled jobs are bound but never upheld.** `media-integrity-scan` is
  `Type=oneshot` with a weekly timer; upholding it would re-run a finished
  scan immediately. Bind the `.service` so a running scan stops with the
  guard; the timer can stay. Check `recyclarr`'s unit type the same way: if
  it is a oneshot + timer, treat it like the scan.
- Take unit names from the nixarr module / `systemctl list-units` on h001,
  not from memory (nixarr may name some differently, and the VPN netns
  has its own units).
- Mount mode: keep NFS `hard` (a frozen in-flight process resumes without
  loss when h004 returns); the guard stops everything else.
- autofs (`hosts/h001/autofs.nix`, currently `/nfs file:...` with no
  timeout): add `--timeout=0`, or switch to a systemd mount with
  `x-systemd.automount`, so an idle unmount can't leave consumers on a
  dead path.

**When the stack becomes a nixos container (`arr`):** the guard stays on
the **host**, and protects one unit instead of a list:

```nix
systemd.services."container@arr" = {
  bindsTo = [ "fleet-guard-h004.service" ];
  after = [ "fleet-guard-h004.service" ];
};
# No Upholds: the guard starts container@arr after a passing probe only if
# it is enabled and not held (see above), so cnt stop/backup/move stick.
containers.arr.bindMounts."/media" = { hostPath = "/nfs/h002/nixarr/media"; isReadOnly = false; };
```

- NFS is mounted on the host only, never inside the container. Inside it
  needs extra privileges and gets around the guard.
- The guard's probe touches the share, which makes autofs mount it before
  the container starts, so the bind mount doesn't capture the empty folder
  underneath. Optionally repeat the sentinel check inside the container as
  an `ExecStartPre` for each app.
- Settings and databases (nixarr `stateDir`, `/var/lib/nixarr/state`) stay
  on h001's local disk, bound into the container. Only media lives on h004,
  so stopping the container loses nothing.
- If `media-integrity-scan` stays on the host, it stays bound, not upheld.
- Under the floating-container CLI, the same idea generalises to a
  `requires = [ "nfs-h004" ]` host capability whose guard unit the host
  module provides (see §4.1).

**Before the guard exists** (e.g. NAS upgrade day): stop the stack by
hand, including `media-integrity-scan.timer`, `media-integrity-scan.service`,
`shelfmark.service`, `audiobookshelf.service` and every nixarr unit from
`systemctl list-units`.

### Identity, secrets, core — host-bound or move last

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| zitadel (SSO) | **Float** (decided 2026-10-16) | h001 first, movable | Container written (`containers/zitadel`, :8085, PG17 socket-only, masterkey in persist `keys`); cut over 2026-10-17. sec-agent, sec and oauth2-proxy authenticate against it. Master key stays outside sec (persist dir + break-glass copy, §4.8). |
| sec (secrets_manager server) | **Float** (decided 2026-10-16) | h001 first, movable | Container written (`containers/sec`, 127.0.0.1:8300, registry in `registry.nix`); cut over 2026-10-17. Every host's sec-agent depends on it; it depends on zitadel. Encryption key in persist + break-glass copy. |
| oauth2-proxy | **Live** (in trilium) | same host as trilium | Gate for trilium. |
| beszel hub | **Live** h001 2026-10-13 (789b4a53) | h001 (pinned) | `containers/beszel`, binds 100.64.0.13:8090 (host network). Agents still hard-code that IP: give them a DNS name that follows the hub before ever `cnt move`-ing it. |
| host postgresql 17 | **Removed** 2026-10-14 | — | Was unused (only an empty `scratch` db). `mods/postgresql.nix` deleted; data + final pg_dumpall archived in h001:/home/luser/backups/host-postgresql-final-2026-10-14.tar.gz, `/var/lib/postgresql` deleted. The `postgres` user (uid 71) stays: zitadel.nix declares it for its bind-mounted cluster, and life's pgBackRest secret is group 71. |
| restic-backup | **Reworked** 2026-10-13 (b8588f6c) | — | Runs every `service.nix` `backupHook` whose unit is active on h001 (skips others; a failing hook fails the run), then backs up all of `/srv/containers` (live PG clusters + caches excluded) plus wd10 media and `~luser/backups`. SQLite: host-side `.backup` copies of every SQLite db into `/var/lib/restic-staging/sqlite`; only the copied live files are excluded (generated exclude-file, 789b4a53). Also sec db + key and the zitadel dump + masterkey (ea10e55c). `--group-by host,tags` for backup and prune. Restore-verified: a07bdec4 and f6542ab6 restored, all SQLite copies pass integrity_check. |
| homepage-dashboard (h001, joe) | Replace | — | By the read-only dashboard in `fleet-edge` on h005 (ROUTING-PLAN §5.4), then removed from both hosts. |

### Apps — good floating candidates

| Service | Decision | Ideal host | Kind | Notes |
|---|---|---|---|---|
| vaultwarden | **Live** | h001 | nixos | `containers/vaultwarden` since 2026-10-12 (data + backups copied 1:1, full-tree checksum verified; uid 114 kept; env secret bound read-only, `cnt restart` after rotation). |
| atuin | **Live** | h001 | nixos | `containers/atuin` since 2026-10-12 (PG 17 copied 1:1, full-tree checksum verified; host net, idmapped). |
| forgejo | **Live** h001 2026-10-13 | h001 or h003 | nixos | `containers/forgejo` (PG 17 + data copied 1:1, empty rsync diff; 146 repos / 4 users / 3658 actions match; uid 115). Builtin SSH listens on host :3032 itself (`tcpPorts`); o002 streams public :3032 to it, so update o002 on move. The CLI default repo is forgejo, so while forgejo is down use `CONTAINERS_REPO=git+file://...`. |
| opengist | **Live** | h001 | podman | `containers/opengist` since 2026-10-12 (all 123 gists, full-tree checksum verified). Old `/var/lib/opengist` deleted. |
| trilium + oauth2-proxy | **Live** h001 2026-10-13 | h003 (together) | nixos | `noAuthentication=true` behind the proxy; also an overlay-only unauthenticated vhost on 9112. Never split across hosts without restricting trilium's port. |
| open-webui | **Live** h001 2026-10-13 | h003 | nixos | Needs litellm + searx. |
| litellm | **Live** h001 2026-10-13 | with open-webui | nixos | **Stateful**: persist `data` = `/var/lib/private/litellm` holds the GitHub Copilot OAuth token (`github_copilot/`), `.config`, UI and tiktoken caches. Losing it means re-doing the Copilot device login. Plus env secret. |
| searx | **Live** h001 2026-10-13 | with open-webui | nixos | Keep its generated secret key in persist. |
| n8n | **Removed** | — | — | — | Dropped 2026-10-12, no export. |
| etebase + EteSync web | **Removed** 2026-10-13 | — | — | Replaced by life (calendar + contacts). Final archive: h001:/home/luser/backups/etebase-final-2026-10-13.tar.gz (2 users, 11 collections, 4626 items). |
| puzzles | **Live** h001 2026-10-13 | h003 | nixos | Private flake; small. |
| life | **Live** h001 2026-10-13 | h003 or h001 | nixos | Own postgres 18 + pgBackRest WAL archiving: take a fresh full backup right after any move. |
| matrix (synapse, element, mautrix bridges) | **Removed** 2026-10-13 | — | — | Final archive: h001:/home/luser/backups/matrix-final-2026-10-13.tar.gz (pg_dumpall + configs/keys, no media; 2 users, 806 rooms). |
| penpot | **Removed** | — | — | — | Dropped 2026-10-12, no data kept. |
| wasabi / ntest demo containers (h001) | **Removed** | — | — | — | Dropped 2026-10-12. |

### Large local data — decide the storage model first

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| immich | **Live** h001 2026-10-13 (b8588f6c) | h001 | `containers/immich`: PG16 + vchord, ML cache, `requires = [ "wd10" ]`; media bound from `/drives/wd10/immich/media`. 58410 assets match. |
| paperless | **Live** h001 2026-10-13 (b8588f6c) | h001 | `containers/paperless`: PG16, tika, gotenberg on 3002; media/consume bound from `/drives/wd10/paperless`. 225 docs match. |
| dawarich | **Live** h001 2026-10-13 | h001 | `containers/dawarich` (PG 17 + postgis, redis, data; 657582 points match). Moved off `/drives/wd10` to `/srv/containers` (1.6 GB, so no wd10 requirement). restic backs up `data` + `pgdumps`. |

`move` copies `/srv/containers/<svc>` only. Options: (a) put media under it
and accept long moves, (b) add "external mount + host requirement" to
`service.nix` (e.g. `requires = [ "wd10" ]`) so these run in containers but
only on hosts with that disk. Recommended: (b), keep them on h001.

### GPU services (joe)

| Service | Decision | Ideal host | Kind | Notes |
|---|---|---|---|---|
| Kokoro TTS | **Deprecated** | — | — | Served by localai (gallery `kokoro`); kokoro-tts module and data removed. |
| localai (LocalAI) | **Live** | joe | podman | `containers/localai`, deployed; flux.2-klein-4b + kokoro tested. OpenAI-compatible `/v1/images/generations` for Open WebUI and agents; FLUX.2 klein (tested), flux.1-dev-ggml; Z-Image and flux.1-schnell gallery default (bf16, ~12 GB) are full-size diffusers weights, will not fit. Can also serve Kokoro TTS (gallery `kokoro`). Keep list from Forge in its README. |
| Forge (Stable Diffusion) | **Removed** | — | — | Replaced by localai; module and `/var/lib/forge` deleted. |
| llama-cpp | **Removed** | — | — | Module, pinned nixpkgs input and persistence deleted. `joe:/persist/var/cache/llama-cpp` is empty (0 bytes); the folder can go. |

Prefer **podman-kind** for GPU work (CDI device passthrough is clean;
nspawn needs `/dev/nvidia*` + matching driver libs bound in). AMD would
need `/dev/kfd` + `/dev/dri` and a ROCm image matching the GPU.

### Host-bound — never float

| Service | Host | Why |
|---|---|---|
| NFS server | h004 | Owns the disks. |
| dnsmasq (LAN DHCP/DNS), dnsmasq-tailnet, AdGuard Home, DDNS, NUT/UPS, ISP speedtest | h005 | Router functions: physical VLANs, port 53/DHCP, USB UPS. |
| nginx public edge, headscale | o002 | The edge and the tailnet control plane. |
| per-host nginx (floating sites) | each host | Written at runtime by `cnt deploy`. |
| nix-serve, libvirtd | lio | Tied to lio's store / hypervisor. |
| stt_ime (speech-to-**text**) | lio, juni | Input-method addon, not a server. |
| beszel agents, sec-agent, tailscaled | every host | Per-host by design. |
| battery-manager | gp3 | Reads its own battery. |

## 4. Capabilities the CLI/module needs before the harder migrations

1. **Host requirements** — **done**: `requires = [ ... ]` in `service.nix`;
   the host module advertises `capabilities`; `deploy`/`move` refuse early
   (before stopping anything) when the target lacks one. In use: `arr`
   (`nfs-h004`, `intel-qsv`). `wd10` on h001 (immich, paperless; b8588f6c). `nvidia` on joe, required by localai (48ab0a6a).
2. **Secrets into containers** — **partly done**: services bind
   `/var/lib/secrets_manager_hydrated/<name>` read-only (h001's
   `sec-agent.nix` grants them; `cnt restart <svc>` after rotation). Not yet
   declared in `service.nix`, so `move` can't check the target holds the
   same grants.
3. **Routing that follows a move** (biggest manual step today). Full design:
   [ROUTING-PLAN.md](ROUTING-PLAN.md) (exposure levels, generated DNS/edge,
   auth, runtime overrides, dashboard):
   - o002 vhosts hard-code upstream tailnet IPs → proxy to a name instead.
   - dnsmasq-tailnet's `h001Subdomains`/`lioSubdomains` in `fleet.nix` →
     generate from `service.nix` hosts (or have the CLI update it).
   - beszel `HUB_URL` → DNS name (hub floated but pinned to h001 until then).
   - TLS on the target: floating vhosts read
     `/var/lib/acme/joshuabell.xyz/{fullchain,key}.pem`, which only h001 has
     (h003 has no `/var/lib/acme`), so `nginx -t` would fail there. Provision
     the wildcard cert on any target host, and have `deploy`/`move` refuse
     early when the files are missing.
4. ~~Multi-container podman (pods)~~ not needed (penpot removed).
5. ~~Remote work without passwordless sudo~~ done via root ssh (see §1).
6. **Architecture**: flakes already build for `x86_64-linux` and
   `aarch64-linux`. ARM eligibility (o002) is per service: check the nixpkgs
   package / container image has an arm64 build. o002's 12 GB / impermanent
   root make it a poor general host regardless.
7. **Backup continuity across moves** (required before any off-host `move`).
   `restic-backup.nix` only runs on h001, only covers services running
   there, and snapshots h001's `/srv/containers`. After a move it would keep
   backing up the stale source copy. Needed:
   - a restic job on **every** container host, generated by the host
     module from the services deployed there (hooks + their persist dirs),
     with per-host repos/tags;
   - `move` removes the source copy (or marks it stale and excluded) once
     the target is verified;
   - the first backup on the target runs as part of `move`, and a restore
     check (`restic restore` to a scratch dir, PG/SQLite integrity) runs
     before the source copy goes;
   - backup age per service on the dashboard, alert when stale.
8. **Break-glass for the identity core** (required before floating
   sec/zitadel). The restic repo password and backend credentials come from
   sec (`restic_h001_env`), and sec's key is only in sec's data dir and
   restic. Restic snapshots include both keys, so with the restic env from
   the password manager an intact snapshot restores everything; the copies
   below are a second path if the repo is damaged. Kept outside the fleet
   (password manager):
   - restic env (repo, password, backend credentials): **have it**;
   - sec's encryption key (`/var/lib/secrets_manager/db.key`; after cutover `/srv/containers/sec/data/db.key`): **have it**;
   - zitadel master key (`/var/lib/zitadel/masterkey`; after cutover `/srv/containers/zitadel/keys/masterkey`, 32 raw bytes, store
     base64): **have it**;
   - an emergency ssh key pair (`root_fleet_backup`): **have it**. The
     public key is authorized for root on every host via common
     `hardening.nix`; the private key is only in the password manager.
     Covers hosts without a console (o002) and a fleet whose sec-agent
     can't fetch the usual keys.

   Still to do: a cold restore of sec + zitadel on a spare host, once from a
   restic snapshot and once from the password-manager copies alone.

## 5. Migration recipe (per service)

1. Write `containers/<svc>/{service,flake,container}.nix`; `persist` every
   state dir; own postgres inside if it used the shared one.
2. Data in: `pg_dump` from the old DB → restore in the new container;
   rsync other state into `/srv/containers/<svc>/<key>` with the right uids.
3. `cnt deploy <svc>` on the same host first (side by side on a new port),
   verify, then switch nginx/o002 to it and disable the old host module.
4. Add a `backupHook` (e.g. `pg_dumpall`) and take a `cnt backup`.
5. Only then `cnt move` to the ideal host; update `host` in `service.nix`,
   o002 upstream, dnsmasq-tailnet.

## 6. Suggested order

1. ~~Deprecate n8n, wasabi/ntest, penpot; migrate opengist~~ done 2026-10-12.
   Decided 2026-10-13: matrix removed; dawarich, kavita, books kept.
2. ~~atuin~~ done 2026-10-12. ~~searx + litellm + open-webui~~ done 2026-10-13 (in place on h001).
3. ~~vaultwarden~~ done 2026-10-12. ~~trilium + oauth2-proxy, life, puzzles~~
   done 2026-10-13; etebase removed 2026-10-13.
4. ~~forgejo~~ done 2026-10-13; matrix removed.
4a. ~~Cut the *arr stack over to `arr`~~ **Done 2026-10-12.**
5. ~~§4.1 `wd10`, immich/paperless, restic rework~~ done 2026-10-13 (b8588f6c).
   Beszel hub floated 2026-10-13 (789b4a53, pinned to h001). Host postgres removed 2026-10-14.
6. GPU services on joe: ~~localai as podman-kind~~ live; ~~nvidia capability + localai `requires`~~ done.
7. **Last** (no off-host moves planned): §4.3 routing + target TLS certs
   and §4.7 backup continuity, then `cnt move` services to their ideal
   hosts. Until then every migration
   is in place on its current host.
8. sec + zitadel to floating containers on h001 (after §4.8 break-glass and
   the routing steps they rely on: DNS on h005, certs). Done 2026-10-17;
   the cutover runbook is `containers/sec/README.md`. Moving them off h001 follows §4.7 like any service.
9. Never: router/NAS/edge (h005, h004, o002).
