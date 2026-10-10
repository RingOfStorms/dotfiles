# Self-hosted services: migration plan to floating containers

Living plan for moving the fleet's self-hosted services into the
floating-container system in this directory (`containers` CLI, `cnt`). Written
2026-10 from a read-only audit of `hosts/*`; re-verify a service's module
before migrating it (things drift).

Status legend: **Keep** · **Deprecate** (stop running, archive data) ·
**Decide** (owner to confirm usage) · **Host-bound** (infrastructure, stays a
host module, never floats).

## 1. Where things stand

- Floating today: `minecraft` (h003), test twins `hello-nixos` / `hello-podman`.
- CLI: `deploy`, `stop` (persists across reboot), `start`, `move`, `backup`
  (asks dir + before stopping), `restore`, `status <svc>`, `ls`, local mode.
- Hosts with the host module: h003, lio (lio has `nginx.enable` since `3a615a9`).
- Open CLI issue: `status <svc>` against a *remote* host uses `sudo -n` over
  ssh; users whose sudo needs a password (luser) get an error, not a prompt.
  Fix: collect unprivileged details without sudo, sizes via a prompt-capable
  path. Verify as luser, not root.

## 2. Hosts and roles

| Host | Hardware | Role, now → target |
|---|---|---|
| h001 | Dell OptiPlex 7090, i5-11500, 64 GB, **Intel UHD 750 iGPU (QSV)**, /drives/wd10, NFS client of h002 | Main service host → stays home of media/*arr + big-data services |
| h002 | NAS, bcachefs `/data` | NFS server, host-bound |
| h003 | Ryzen 7 5825U, 28 GB, AMD Barcelo iGPU (VAAPI), 1 TB NVMe | Router + minecraft → **general service host** once h004 takes the router role |
| h004 | not built (plan in `hosts/h004/readme.md`) | Future router (dnsmasq, AdGuard, DDNS, NUT, speedtest) |
| o002 | Oracle Ampere A1, **aarch64**, 2 OCPU/12 GB, impermanent root | Public TLS edge + headscale, host-bound |
| joe | Desktop, NVIDIA RTX 3080 10 GB | GPU AI services (podman) |
| lio | Desktop, AMD RX 7900 GRE | nix-serve cache, builder; floating-capable (test target) |
| gp3, juni, oren, i001, testbed, jflip | laptops/kiosk/VM/phone | No floating services |

No host has a *dedicated* media GPU; h001's Intel QSV is the best-supported
Jellyfin path (QSV + tone mapping). h003's AMD iGPU can VAAPI-transcode too,
so it is a viable fallback, not a primary.

## 3. Service decisions

"Ideal host" assumes the end state (h004 = router, h003 = second service host).

### Media / *arr — stays on h001 as one unit

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| jellyfin | Keep | h001 | Intel QSV (`hardware-transcoding.nix`), NFS media. Kept outside the VPN netns on purpose (metadata lookups). |
| seerr (jellyseerr) | Keep | h001 | Request UI for jellyfin. |
| sonarr, radarr, prowlarr, bazarr | Keep | h001 | Need NFS media + shared uids mirrored on h002. |
| sabnzbd, transmission | Keep | h001 | Inside the WireGuard VPN netns (wg conf from sec-agent). |
| shelfmark, audiobookshelf | Decide | h001 | Book pipeline; keep if still reading/listening. |
| kavita | Decide | h001 | Reads the NFS book library. |
| recyclarr | Keep | h001 | Stateless config sync for sonarr/radarr. |
| media-integrity | Keep | h001 | Weekly ffmpeg scan of NFS movies; goes wherever media is mounted. |

Migration stance: **leave as host modules for now.** Containerising buys
little: the VPN netns, NFS automount, uid mirroring with h002 and QSV all
tie it to h001. If ever done: one nixos-kind container, host requirements
`nfs-h002`, `intel-qsv`, VPN netns inside the container.

### Identity, secrets, core — host-bound or move last

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| zitadel (SSO) | Keep | h001 (don't float) | sec-agent and oauth2-proxy authenticate against it. Postgres is bind-mounted from the host; master key outside sec-agent. Move only deliberately, never with sec down. |
| sec (secrets_manager server) | Keep | h001 (don't float) | Every host's sec-agent depends on it; it depends on zitadel. |
| oauth2-proxy | Keep | same host as trilium | Gate for trilium. |
| beszel hub | Keep | h001, or h003 | Every agent hard-codes `HUB_URL=http://100.64.0.13:8090`; switch agents to a DNS name before ever moving it. |
| host postgresql 17 | Retire | — | Shared DB for host modules. Disappears as services move into containers with their own postgres (`pg_dump` per service, never file copies of the shared cluster). |
| restic-backup | Rework | — | Reaches into immich/paperless/dawarich/etebase. Replace with per-service `backupHook` + `cnt backup`, or a central job that asks `cnt` where each service runs. |
| homepage-dashboard (h001, joe) | Decide | anywhere | Hard-coded links; trivial either way. |

### Apps — good floating candidates

| Service | Decision | Ideal host | Kind | Notes |
|---|---|---|---|---|
| vaultwarden | Keep | h003 | nixos | SQLite; keep uid/gid 114; env secret from sec-agent. Critical: back up before and after the move. |
| atuin | Keep | h003 | nixos | Own postgres already. Easy. |
| forgejo | Keep | h001 or h003 | nixos | Own postgres. SSH on **3032**: o002 stream-forwards it, so update o002 on move. Repos can be large. |
| opengist | Decide | h003 | podman | Single bind dir. Trivial; best first real migration if kept. |
| trilium + oauth2-proxy | Keep | h003 (together) | nixos | `noAuthentication=true` behind the proxy; also an overlay-only unauthenticated vhost on 9112. Never split across hosts without restricting trilium's port. |
| open-webui | Decide | h003 | nixos | Needs litellm + searx. |
| litellm | Decide | with open-webui | nixos | Stateless; env secret. |
| searx | Decide | with open-webui | nixos | Keep its generated secret key in persist. |
| n8n | **Deprecate** | — | — | Only used for a retired email flow. Export workflows to the repo or a backup, then remove. |
| etebase + EteSync web | Decide | h003 | nixos | nginx uses a **unix socket** today; switch to TCP. Self-generated Django key → persist. |
| puzzles | Decide | h003 | nixos | Private flake; small. |
| life | Keep | h003 or h001 | nixos | Own postgres 18 + pgBackRest WAL archiving: take a fresh full backup right after any move. |
| matrix (synapse, element, mautrix bridges) | Decide | h001 or h003 | nixos | Big, pinned nixpkgs rev (mautrix-signal segfault). Move as one unit; bridge sessions live in the DB. |
| penpot | Decide | h003 | — | 7 podman containers on a private network; CLI podman-kind is 1 container. Needs multi-container (pod) support first. Deprecate unless actively used. |
| wasabi / ntest demo containers (h001) | **Deprecate** | — | — | Leftover experiments. |

### Large local data — decide the storage model first

| Service | Decision | Ideal host | Notes |
|---|---|---|---|
| immich | Keep | h001 | postgres 16 + media on `/drives/wd10` + ML cache (CPU). |
| paperless | Keep | h001 | postgres 16 + docs/consume on `/drives/wd10`. |
| dawarich | Decide | h001 | postgres + redis + `/drives/wd10`; secret via LoadCredential. |

`move` copies `/srv/containers/<svc>` only. Options: (a) put media under it
and accept long moves, (b) add "external mount + host requirement" to
`service.nix` (e.g. `requires = [ "wd10" ]`) so these run in containers but
only on hosts with that disk. Recommended: (b), keep them on h001.

### GPU services (joe)

| Service | Decision | Ideal host | Kind | Notes |
|---|---|---|---|---|
| Kokoro **TTS** (text-to-speech) | Keep | joe | podman | `kokoro-fastapi-gpu` with `--device=nvidia.com/gpu=all` (CDI). On a non-NVIDIA host the container *fails to start*. A CPU image variant exists if portability ever matters. |
| Forge (Stable Diffusion) | Decide | joe | podman | NVIDIA, VRAM-hungry, many GB of models in `/var/lib/forge`. |
| llama-cpp | Already disabled | — | — | Reference only; pinned CUDA build to avoid a crashing multi-hour rebuild. |

Prefer **podman-kind** for GPU work (CDI device passthrough is clean;
nspawn needs `/dev/nvidia*` + matching driver libs bound in). AMD would
need `/dev/kfd` + `/dev/dri` and a ROCm image matching the GPU.

### Host-bound — never float

| Service | Host | Why |
|---|---|---|
| NFS server | h002 | Owns the disks. |
| dnsmasq (LAN DHCP/DNS), dnsmasq-tailnet, AdGuard Home, DDNS, NUT/UPS, ISP speedtest | h003 → h004 | Router functions: physical VLANs, port 53/DHCP, USB UPS. Planned move to h004 is a host rebuild, not `cnt move`. |
| nginx public edge + ACME, headscale | o002 | The edge and the tailnet control plane. |
| per-host nginx (floating sites) | each host | Written at runtime by `cnt deploy`. |
| nix-serve, libvirtd | lio | Tied to lio's store / hypervisor. |
| stt_ime (speech-to-**text**) | lio, juni | Input-method addon, not a server. |
| beszel agents, sec-agent, tailscaled | every host | Per-host by design. |
| battery-manager | gp3 | Reads its own battery. |

## 4. Capabilities the CLI/module needs before the harder migrations

1. **Host requirements**: `requires = [ "nvidia" "intel-qsv" "wd10" "nfs-h002" ]`
   in `service.nix`; host module advertises capabilities; `deploy`/`move`
   refuse early (before stopping anything) when the target lacks one.
2. **Secrets into containers**: declare needed sec-agent secrets in
   `service.nix`; bind `/var/lib/secrets_manager_hydrated/<name>` read-only
   into the container. Target host must hold the same grants.
3. **Routing that follows a move** (biggest manual step today):
   - o002 vhosts hard-code upstream tailnet IPs → proxy to a name instead.
   - dnsmasq-tailnet's `h001Subdomains`/`lioSubdomains` in `fleet.nix` →
     generate from `service.nix` hosts (or have the CLI update it).
   - beszel `HUB_URL` → DNS name.
4. **Multi-container podman** (pods) — only if penpot is kept.
5. **Remote `status` without passwordless sudo** (see §1).
6. **Architecture**: flakes already build for `x86_64-linux` and
   `aarch64-linux`. ARM eligibility (o002) is per service: check the nixpkgs
   package / container image has an arm64 build. o002's 12 GB / impermanent
   root make it a poor general host regardless.

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

1. Deprecate: n8n, wasabi/ntest; decide opengist/penpot/puzzles/dawarich/
   matrix/forge/kavita/books usage.
2. Easy floats to h003: atuin, opengist, searx + litellm + open-webui.
3. vaultwarden, trilium + oauth2-proxy, etebase (TCP first), life, puzzles.
4. Build §4.3 routing so moves stop needing o002/dnsmasq edits.
5. forgejo, matrix.
6. §4.1 requirements, then immich/paperless/dawarich as containers on h001.
7. GPU services on joe as podman-kind with `requires = [ "nvidia" ]`.
8. Never: *arr stack (stays host modules on h001), zitadel/sec (until there
   is a reason), router/NAS/edge.
